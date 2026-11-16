// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import Foundation

// Local stream between Longcable.app (records the Mac input) and the root
// service (serves Longcable Mic). Each message: UInt32 BE length of the rest,
// UInt8 type, payload. Audio is mono Int16 little-endian at 48 kHz.
public enum AudioMessage: Equatable, Sendable {
  case hello(version: UInt16)  // app → service, must come first
  case start  // service → app: Windows is listening, record
  case stop  // service → app: stop recording
  case audio([Int16])  // app → service, 1…4800 samples
}

let audioChannelVersion: UInt16 = 1
private let audioMessageLimit = 65_536

func encodeAudioMessage(_ message: AudioMessage) -> Data {
  var body: Data
  switch message {
  case .hello(let version): body = Data([1, UInt8(version >> 8), UInt8(version & 0xff)])
  case .start: body = Data([2])
  case .stop: body = Data([3])
  case .audio(let samples):
    body = Data(capacity: 1 + samples.count * 2)
    body.append(4)
    for sample in samples {
      let value = UInt16(bitPattern: sample)
      body.append(UInt8(value & 0xff)); body.append(UInt8(value >> 8))
    }
  }
  var header = Data(count: 4)
  header.put32(0, UInt32(body.count))
  return header + body
}

func readAudioMessage(_ c: Connection, idle: Bool = false) -> AudioMessage? {
  guard let header = c.read(4, idle: idle) else { return nil }
  let length = Int(header.u32(0))
  guard length >= 1, length <= audioMessageLimit, let body = c.read(length) else { return nil }
  let payload = body.dropFirst()
  switch body[body.startIndex] {
  case 1 where payload.count == 2:
    return .hello(version: UInt16(payload[payload.startIndex]) << 8 | UInt16(payload[payload.startIndex + 1]))
  case 2 where payload.isEmpty: return .start
  case 3 where payload.isEmpty: return .stop
  case 4 where !payload.isEmpty && payload.count % 2 == 0 && payload.count <= 9600:
    let bytes = Array(payload)
    return .audio((0..<(bytes.count / 2)).map {
      Int16(bitPattern: UInt16(bytes[$0 * 2]) | UInt16(bytes[$0 * 2 + 1]) << 8)
    })
  default: return nil
  }
}

// Owns the one connected recording client. A newer authenticated client replaces
// the older one, so a stale app instance can never feed audio alongside it.
final class AudioChannelHub {
  private let allowed: (uid_t) -> Bool
  private let onSamples: ([Int16]) -> Void
  private let onConnected: (Bool) -> Void
  private let lock = NSLock()
  private var current: Connection?
  private var streaming = false
  // Connections authenticated but still owing a hello. Bounded so a local
  // process cannot tie up the root service's threads or descriptors.
  private var pendingHandshakes = 0
  static let maxPendingHandshakes = 4

  init(allowed: @escaping (uid_t) -> Bool, onSamples: @escaping ([Int16]) -> Void,
       onConnected: @escaping (Bool) -> Void) {
    self.allowed = allowed
    self.onSamples = onSamples
    self.onConnected = onConnected
  }

  func adopt(_ c: Connection, uid: uid_t?) {
    // Refuse before any thread is used: wrong user, or too many waiting already.
    guard let uid, allowed(uid), lock.withLock({ () -> Bool in
      guard pendingHandshakes < Self.maxPendingHandshakes else { return false }
      pendingHandshakes += 1
      return true
    }) else { c.closeSocket(); return }
    DispatchQueue.global(qos: .userInitiated).async { [self] in
      defer { c.closeSocket() }
      let hello = readAudioMessage(c)
      lock.withLock { pendingHandshakes -= 1 }
      guard hello == .hello(version: audioChannelVersion) else { return }
      let replaced = lock.withLock { () -> Connection? in
        defer { current = c }
        if streaming { _ = c.write(encodeAudioMessage(.start), timeoutMS: 200) }
        return current
      }
      replaced?.interrupt()
      onConnected(true)
      while case .audio(let samples)? = readAudioMessage(c, idle: true) { onSamples(samples) }
      let wasCurrent = lock.withLock { () -> Bool in
        guard current === c else { return false }
        current = nil
        return true
      }
      if wasCurrent { onConnected(false) }
    }
  }

  func setStreaming(_ value: Bool) {
    lock.withLock {
      streaming = value
      // Called from the USB session's queue: never let a stuck app delay Windows.
      if let current, !current.write(encodeAudioMessage(value ? .start : .stop), timeoutMS: 200) {
        current.interrupt()
      }
    }
  }

  func stop() { lock.withLock { current?.interrupt() } }
}

// Listens on the root-owned local socket and hands authenticated clients to a hub.
final class AudioChannelServer {
  private let fd: Int32
  private let path: String
  private let hub: AudioChannelHub
  private let lifecycle = NSLock()
  private var running = true

  init(hub: AudioChannelHub, path: String = Paths.audioSocket) throws {
    self.hub = hub
    self.path = path
    // Same directory and permissions model as the control socket.
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o755])
    unlink(path)
    fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw USBError.message("Could not create audio socket") }
    var address = try unixAddress(path)
    let ok = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard ok == 0, chmod(path, 0o666) == 0, listen(fd, 4) == 0 else {
      Darwin.close(fd)
      throw USBError.message("Could not start the audio socket")
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
        guard c.configureLocal() else { c.closeSocket(); continue }
        hub.adopt(c, uid: authenticatedPeerUID(client))
      }
      Darwin.close(fd)
      unlink(path)
    }
  }
  func stop() {
    lifecycle.withLock { running = false }
    hub.stop()
  }
}

// Used by Longcable.app to feed the service.
public final class AudioChannelClient: @unchecked Sendable {
  private let path: String
  private let lock = NSLock()
  private var connection: Connection?
  private var broken = false  // a write failed mid-frame; close() still owns the socket

  public init(path: String = Paths.audioSocket) { self.path = path }
  init(connection: Connection) {
    path = ""
    self.connection = connection
  }

  public func connect() throws {
    var info = stat()
    guard lstat(path, &info) == 0, info.st_uid == 0, (info.st_mode & S_IFMT) == S_IFSOCK else {
      throw USBError.message("The Longcable service has no microphone socket")
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw USBError.message("Cannot create local connection") }
    let c = Connection(fd)
    var address: sockaddr_un
    do { address = try unixAddress(path) } catch { c.closeSocket(); throw error }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    var uid: uid_t = UInt32.max, gid: gid_t = UInt32.max
    guard result == 0, c.configureLocal(), getpeereid(fd, &uid, &gid) == 0, uid == 0,
      c.write(encodeAudioMessage(.hello(version: audioChannelVersion)))
    else {
      c.closeSocket()
      throw USBError.message("Could not reach the Longcable service's microphone socket")
    }
    let previous = lock.withLock { () -> Connection? in
      defer { connection = c; broken = false }
      return connection
    }
    previous?.interrupt()
    previous?.closeSocket()
  }

  // Blocks until the service says start/stop; nil when the connection ends.
  public func receive() -> AudioMessage? {
    guard let c = lock.withLock({ connection }) else { return nil }
    return readAudioMessage(c, idle: true)
  }

  @discardableResult public func send(samples: UnsafeBufferPointer<Int16>) -> Bool {
    guard let c = lock.withLock({ broken ? nil : connection }) else { return false }
    var offset = 0
    while offset < samples.count {
      let chunk = Array(samples[offset..<min(samples.count, offset + 4800)])
      guard c.write(encodeAudioMessage(.audio(chunk)), timeoutMS: 200) else {
        // Part of a frame may be on the wire: never write after it. Dropping the
        // connection ends receive(), so the app reconnects with a clean stream.
        lock.withLock { if connection === c { broken = true } }
        c.interrupt()
        return false
      }
      offset += chunk.count
    }
    return true
  }

  public func close() {
    let c = lock.withLock { () -> Connection? in
      defer { connection = nil }
      return connection
    }
    c?.interrupt()
    c?.closeSocket()
  }
}
