// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import Foundation

func unixAddress(_ path: String) throws -> sockaddr_un {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let capacity = MemoryLayout.size(ofValue: address.sun_path)
  guard path.utf8.count < capacity else { throw USBError.message("Socket path too long") }
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  withUnsafeMutableBytes(of: &address.sun_path) { bytes in
    bytes.copyBytes(from: Data((path + "\0").utf8))
  }
  return address
}
func currentConsoleUID() -> uid_t? {
  var info = stat()
  return stat("/dev/console", &info) == 0 ? info.st_uid : nil
}
func authenticatedPeerUID(_ fd: Int32) -> uid_t? {
  var uid: uid_t = UInt32.max
  var gid: gid_t = UInt32.max
  return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
}
final class ControlServer {
  let fd: Int32
  let handler: (ControlRequest, uid_t) -> ControlReply
  let slots = DispatchSemaphore(value: 4)
  let lifecycle = NSLock()
  var running = true
  init(handler: @escaping (ControlRequest, uid_t) -> ControlReply) throws {
    self.handler = handler
    // Root owns the containing directory, preventing socket replacement by other users.
    try FileManager.default.createDirectory(
      atPath: Paths.directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])
    var info = stat()
    guard lstat(Paths.directory, &info) == 0, info.st_uid == 0, (info.st_mode & S_IFMT) == S_IFDIR,
      (info.st_mode & 0o022) == 0
    else { throw USBError.message("Unsafe control directory") }
    unlink(Paths.socket)
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw USBError.message("Could not create control socket") }
    var address = try unixAddress(Paths.socket)
    let ok = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard ok == 0, chmod(Paths.socket, 0o666) == 0, listen(fd, 8) == 0 else {
      Darwin.close(fd)
      throw USBError.message("Could not start local controls")
    }
  }
  func start() {
    DispatchQueue.global(qos: .utility).async { [self] in
      while lifecycle.withLock({ running }) {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 1000) > 0 else { continue }
        let client = accept(fd, nil, nil)
        if client < 0 { continue }
        let c = Connection(client)
        guard slots.wait(timeout: .now()) == .success else {
          c.closeSocket()
          continue
        }
        guard c.configureLocal() else {
          c.closeSocket()
          slots.signal()
          continue
        }
        DispatchQueue.global(qos: .utility).async { [self, c] in
          defer {
            c.closeSocket()
            slots.signal()
          }
          Self.serve(c, handler: handler)
        }
      }
      Darwin.close(fd)
      unlink(Paths.socket)
    }
  }
  // Shared by accepted sockets and isolated socketpair tests. Authentication precedes dispatch.
  static func serve(_ connection: Connection,
                    peerUID: (Int32) -> uid_t? = authenticatedPeerUID,
                    handler: (ControlRequest, uid_t) -> ControlReply) {
    guard let uid = peerUID(connection.fd), let length = connection.read(4)?.u32(0),
      length > 0, length <= 4096, let data = connection.read(Int(length)),
      let request = try? JSONDecoder().decode(ControlRequest.self, from: data)
    else { return }
    let reply = handler(request, uid)
    if let payload = try? JSONEncoder().encode(reply) {
      var header = Data(count: 4)
      header.put32(0, UInt32(payload.count))
      if connection.write(header) { _ = connection.write(payload) }
    }
  }
  func stop() { lifecycle.withLock { running = false } }
}
public enum LocalControl {
  public static func send(_ request: ControlRequest) throws -> ControlReply {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw USBError.message("Cannot create local connection") }
    let c = Connection(fd)
    defer { c.closeSocket() }
    // Verify the daemon socket belongs to root before connecting.
    var info = stat()
    guard lstat(Paths.socket, &info) == 0, info.st_uid == 0, (info.st_mode & S_IFMT) == S_IFSOCK
    else { throw USBError.message("The USB sharing service is not installed or running") }
    var address = try unixAddress(Paths.socket)
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0, c.configureLocal() else {
      throw USBError.message("Could not reach the USB sharing service")
    }
    var uid: uid_t = UInt32.max
    var gid: gid_t = UInt32.max
    guard getpeereid(fd, &uid, &gid) == 0, uid == 0 else {
      throw USBError.message("Untrusted sharing service")
    }
    let data = try JSONEncoder().encode(request)
    var h = Data(count: 4)
    h.put32(0, UInt32(data.count))
    guard c.write(h), c.write(data), let length = c.read(4)?.u32(0), length <= 65536,
      let payload = c.read(Int(length))
    else { throw USBError.message("Sharing service did not respond") }
    return try JSONDecoder().decode(ControlReply.self, from: payload)
  }
}
