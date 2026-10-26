// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import Foundation
import IOKit
import IOKit.usb

extension Data {
  func u32(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { ($0 << 8) | UInt32(self[offset + $1]) } }
  func u16LE(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
  mutating func put32(_ offset: Int, _ value: UInt32) {
    for i in 0..<4 { self[offset + i] = UInt8(truncatingIfNeeded: value >> ((3 - i) * 8)) }
  }
  mutating func put16(_ offset: Int, _ value: UInt16) {
    self[offset] = UInt8(value >> 8)
    self[offset + 1] = UInt8(truncatingIfNeeded: value)
  }
  mutating func putString(_ offset: Int, _ capacity: Int, _ string: String) {
    replaceSubrange(
      offset..<offset + Swift.min(capacity - 1, string.utf8.count),
      with: string.utf8.prefix(capacity - 1))
  }
}
func monotonicMS() -> Int64 { Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000) }
final class Connection {
  let fd: Int32
  private let lifecycle = NSLock()
  private var closed = false
  init(_ fd: Int32) { self.fd = fd }
  // Serialize shutdown/close so an old callback cannot shut down a reused descriptor.
  func interrupt() { lifecycle.withLock { if !closed { shutdown(fd, SHUT_RDWR) } } }
  func closeSocket() {
    lifecycle.withLock {
      if !closed {
        closed = true
        Darwin.close(fd)
      }
    }
  }
  deinit { closeSocket() }
  func read(_ length: Int, idle: Bool = false, timeoutMS: Int64 = 5000) -> Data? {
    guard length >= 0 && length <= 1_048_576 else { return nil }
    var result = Data(count: length)
    var offset = 0
    var deadline: Int64? = idle ? nil : monotonicMS() + timeoutMS
    while offset < length {
      let remaining = deadline.map { $0 - monotonicMS() } ?? 1000
      if remaining <= 0 { return nil }
      var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&pollFD, 1, Int32(min(remaining, 1000)))
      if ready < 0 {
        if errno == EINTR { continue }
        return nil
      }
      if ready == 0 { continue }
      let count = result.withUnsafeMutableBytes {
        recv(fd, $0.baseAddress!.advanced(by: offset), length - offset, 0)
      }
      if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
      if count <= 0 { return nil }
      offset += count
      if deadline == nil { deadline = monotonicMS() + timeoutMS }
    }
    return result
  }
  func write(_ data: Data, timeoutMS: Int64 = 5000) -> Bool {
    var offset = 0
    let deadline = monotonicMS() + timeoutMS
    while offset < data.count {
      let remaining = deadline - monotonicMS()
      guard remaining > 0 else { return false }
      var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
      let ready = poll(&pollFD, 1, Int32(min(remaining, 1000)))
      if ready < 0 {
        if errno == EINTR { continue }
        return false
      }
      if ready == 0 { continue }
      // Per-call SO_SNDTIMEO alone lets a slow reader extend a frame forever.
      // Nonblocking sends keep every partial write within the same deadline.
      let count = data.withUnsafeBytes {
        send(fd, $0.baseAddress!.advanced(by: offset), data.count - offset, MSG_DONTWAIT)
      }
      if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
      if count <= 0 { return false }
      offset += count
    }
    return true
  }
  func operation(_ opcode: UInt16, _ status: UInt32) -> Bool {
    var h = Data(count: 8)
    h.put16(0, 0x0111)
    h.put16(2, opcode)
    h.put32(4, status)
    return write(h)
  }
  func configureTCP() -> Bool {
    var options: [(Int32, Int32, Int32)] = [
      (SOL_SOCKET, SO_KEEPALIVE, 1), (IPPROTO_TCP, TCP_NODELAY, 1),
      (IPPROTO_TCP, TCP_KEEPALIVE, 10), (IPPROTO_TCP, TCP_KEEPINTVL, 3),
      (IPPROTO_TCP, TCP_KEEPCNT, 3), (IPPROTO_TCP, TCP_RXT_CONNDROPTIME, 20),
      (IPPROTO_TCP, PERSIST_TIMEOUT, 20), (SOL_SOCKET, SO_NOSIGPIPE, 1),
    ]
    for i in options.indices {
      if setsockopt(
        fd, options[i].0, options[i].1, &options[i].2, socklen_t(MemoryLayout<Int32>.size)) != 0
      {
        return false
      }
    }
    return configureLocal()
  }
  func configureLocal() -> Bool {
    var t = timeval(tv_sec: 5, tv_usec: 0)
    var yes: Int32 = 1
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
    return setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &t, socklen_t(MemoryLayout<timeval>.size)) == 0
      && setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, 4) == 0
  }
}
func usbStatus(_ result: IOReturn) -> Int32 {
  switch result {
  case kIOReturnSuccess: return 0
  case kIOReturnAborted: return -104
  case kIOReturnTimeout: return -110
  case kIOReturnNoDevice, kIOReturnNotAttached: return -19
  case IOReturn(bitPattern: 0xe000_404f), IOReturn(bitPattern: 0xe000_5000): return -32
  default: return -5
  }
}
