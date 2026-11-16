// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import Foundation
import XCTest
@testable import LongcableCore

final class VirtualMicChannelTests: XCTestCase {
  private let lock = NSLock()
  private var samples = [Int16]()
  private var connected = [Bool]()

  private func pair() throws -> (Connection, Connection) {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw USBError.message("socketpair") }
    let a = Connection(fds[0]), b = Connection(fds[1])
    XCTAssertTrue(a.configureLocal()); XCTAssertTrue(b.configureLocal())
    return (a, b)
  }
  private func hub() -> AudioChannelHub {
    AudioChannelHub(allowed: { $0 == 501 || $0 == 0 },
      onSamples: { [unowned self] s in lock.withLock { samples += s } },
      onConnected: { [unowned self] c in lock.withLock { connected.append(c) } })
  }
  private func eventually(_ condition: @escaping () -> Bool, _ message: String = "") {
    let deadline = Date().addingTimeInterval(3)
    while !condition() && Date() < deadline { usleep(5_000) }
    XCTAssertTrue(condition(), message)
  }
  private func connect(_ h: AudioChannelHub, uid: uid_t = 501, hello: Bool = true) throws -> Connection {
    let (server, client) = try pair()
    h.adopt(server, uid: uid)
    if hello { XCTAssertTrue(client.write(encodeAudioMessage(.hello(version: 1)))) }
    return client
  }

  func testFramingRoundTrip() throws {
    for message: AudioMessage in [.hello(version: 1), .start, .stop, .audio([1, -2, 32767, -32768])] {
      let (a, b) = try pair()
      XCTAssertTrue(a.write(encodeAudioMessage(message)))
      XCTAssertEqual(readAudioMessage(b), message)
    }
    XCTAssertEqual(Array(encodeAudioMessage(.audio([0x0102]))), [0, 0, 0, 3, 4, 0x02, 0x01])
  }

  func testOversizeOrUnknownTypeRejected() throws {
    let (a, b) = try pair()
    XCTAssertTrue(a.write(Data([0, 1, 0, 1, 4])))  // 65537 > limit
    XCTAssertNil(readAudioMessage(b))
    let (c, d) = try pair()
    XCTAssertTrue(c.write(Data([0, 0, 0, 1, 9])))
    XCTAssertNil(readAudioMessage(d))
    let (e, f) = try pair()
    XCTAssertTrue(e.write(Data([0, 0, 0, 2, 4, 0])))  // odd audio payload
    XCTAssertNil(readAudioMessage(f))
    let (g, h) = try pair()
    XCTAssertTrue(g.write(Data([0, 0, 0, 1, 4])))  // empty audio
    XCTAssertNil(readAudioMessage(h))
  }

  func testHelloRequiredFirst() throws {
    let h = hub()
    let client = try connect(h, hello: false)
    XCTAssertTrue(client.write(encodeAudioMessage(.audio([5, 5]))))
    XCTAssertNil(client.read(1), "server closes the connection")
    XCTAssertTrue(lock.withLock { samples.isEmpty })
    XCTAssertTrue(lock.withLock { connected.isEmpty })
  }

  func testWrongUserRejected() throws {
    let h = hub()
    let client = try connect(h, uid: 777, hello: false)
    // The service may already have closed the socket, so this write can fail.
    _ = client.write(encodeAudioMessage(.hello(version: 1)))
    XCTAssertNil(client.read(1))
    XCTAssertTrue(lock.withLock { connected.isEmpty })
  }

  // A local process opening many silent connections must not tie up the root
  // service: beyond four waiting handshakes, new connections are closed at once.
  func testPendingHandshakesAreCapped() throws {
    let h = hub()
    var waiting = [Connection]()
    for _ in 0..<4 { waiting.append(try connect(h, hello: false)) }
    usleep(50_000)
    let extra = try connect(h, hello: false)
    let closing = Date()
    XCTAssertNil(extra.read(1, timeoutMS: 3000))
    XCTAssertLessThan(Date().timeIntervalSince(closing), 1.0, "fifth pending handshake is closed at once")
    let started = Date()
    XCTAssertNil(waiting[0].read(1, timeoutMS: 300))
    XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.25, "the first four are still waiting")
    for c in waiting { c.closeSocket() }
  }

  func testServerAudioSocketAcceptsOnlyRootOrSignedInUser() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let store = StorePaths(targets: temporary.appendingPathComponent("targets.json").path,
      state: temporary.appendingPathComponent("sharing.json").path,
      launchDaemon: temporary.appendingPathComponent("service.plist").path)
    let s = USBServer(config: try DaemonConfig(arguments: ["127.0.0.1", "127.0.0.1"]), store: store,
      consoleUID: { 501 }, inventory: { [] }, log: { _ in })
    for (uid, accepted) in [(uid_t(777), false), (UInt32.max, false), (uid_t(0), true), (uid_t(501), true)] {
      let (serverSide, client) = try pair()
      s.audioHub.adopt(serverSide, uid: uid)
      _ = client.write(encodeAudioMessage(.hello(version: 1)))
      if accepted {
        eventually({ s.status().virtualMic?.sourceConnected == true }, "uid \(uid) accepted")
      } else {
        XCTAssertNil(client.read(1), "uid \(uid) refused")
        XCTAssertEqual(s.status().virtualMic?.sourceConnected, false)
      }
      client.closeSocket()
      eventually({ s.status().virtualMic?.sourceConnected == false })
    }
  }

  func testClientSplitsLargeBuffersIntoValidMessages() throws {
    let (a, b) = try pair()
    let client = AudioChannelClient(connection: a)
    var sizes = [Int]()
    let reader = expectation(description: "read three messages")
    DispatchQueue.global().async {
      for _ in 0..<3 { if case .audio(let s)? = readAudioMessage(b) { sizes.append(s.count) } }
      reader.fulfill()
    }
    let samples = [Int16](repeating: 3, count: 10_000)
    XCTAssertTrue(samples.withUnsafeBufferPointer { client.send(samples: $0) })
    wait(for: [reader], timeout: 5)
    XCTAssertEqual(sizes, [4800, 4800, 400])
  }

  // A timed-out write may have left half a frame on the socket; the client must
  // drop the connection so the service never parses garbage and the app reconnects.
  func testClientDropsConnectionAfterFailedSend() throws {
    let (a, b) = try pair()
    let client = AudioChannelClient(connection: a)
    let samples = [Int16](repeating: 1, count: 4800)
    var ok = true
    for _ in 0..<200 where ok { ok = samples.withUnsafeBufferPointer { client.send(samples: $0) } }
    XCTAssertFalse(ok, "the service stopped reading, so a write timed out")
    let started = Date()
    XCTAssertFalse(samples.withUnsafeBufferPointer { client.send(samples: $0) })
    XCTAssertLessThan(Date().timeIntervalSince(started), 0.1, "no further writes on the broken stream")
    var drained = 0
    while b.read(1, timeoutMS: 1000) != nil { drained += 1 }
    XCTAssertGreaterThan(drained, 0)  // reached EOF: the client shut the socket
  }

  func testClientRefusesSocketNotOwnedByRoot() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("lc-\(UUID().uuidString.prefix(8)).sock").path
    defer { unlink(path) }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { Darwin.close(fd) }
    var address = try unixAddress(path)
    _ = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    Darwin.listen(fd, 1)
    XCTAssertThrowsError(try AudioChannelClient(path: path).connect())
  }

  func testSamplesDelivered() throws {
    let h = hub()
    let client = try connect(h)
    XCTAssertTrue(client.write(encodeAudioMessage(.audio([7, 8, 9]))))
    eventually({ self.lock.withLock { self.samples } == [7, 8, 9] })
    XCTAssertEqual(lock.withLock { connected }, [true])
  }

  func testNewClientReplacesOld() throws {
    let h = hub()
    let first = try connect(h)
    eventually({ self.lock.withLock { self.connected } == [true] })
    let second = try connect(h)
    XCTAssertNil(first.read(1, timeoutMS: 2000), "first client is closed")
    XCTAssertTrue(second.write(encodeAudioMessage(.audio([42]))))
    _ = first.write(encodeAudioMessage(.audio([13])))
    eventually({ self.lock.withLock { self.samples } == [42] })
    usleep(50_000)
    XCTAssertEqual(lock.withLock { samples }, [42])
  }

  func testStartSentOnHelloWhileStreamingAndStopLater() throws {
    let h = hub()
    h.setStreaming(true)
    let client = try connect(h)
    XCTAssertEqual(readAudioMessage(client), .start)
    h.setStreaming(false)
    XCTAssertEqual(readAudioMessage(client), .stop)
    h.setStreaming(true)
    XCTAssertEqual(readAudioMessage(client), .start)
  }

  func testDisconnectReportsSourceGone() throws {
    let h = hub()
    let client = try connect(h)
    eventually({ self.lock.withLock { self.connected } == [true] })
    client.closeSocket()
    eventually({ self.lock.withLock { self.connected } == [true, false] })
  }

  func testClientDisconnectKeepsStreamingSilence() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let store = StorePaths(targets: temporary.appendingPathComponent("targets.json").path,
      state: temporary.appendingPathComponent("sharing.json").path,
      launchDaemon: temporary.appendingPathComponent("service.plist").path)
    var transport: VirtualMicTransport?
    var now: Int64 = 0
    let s = USBServer(config: try DaemonConfig(arguments: ["127.0.0.1", "127.0.0.1"]), store: store,
      consoleUID: { 501 }, inventory: { [] }, log: { _ in },
      makeMicDevice: { buffer, serial, onStreaming in
        let t = VirtualMicTransport(buffer: buffer, serial: serial, clock: { now }, startTimer: false,
          onStreaming: onStreaming)
        transport = t
        return t
      })
    try s.loadPersistentState()
    XCTAssertTrue(s.handleControl(ControlRequest(action: "virtual-mic", enabled: true), uid: 501).ok)
    // Windows imports 2-1 and starts streaming.
    let (serverSide, windows) = try pair()
    var importRequest = Data([1, 0x11, 0x80, 0x03, 0, 0, 0, 0])
    var bus = Data(count: 32); bus.putString(0, 32, "2-1")
    importRequest.append(bus)
    XCTAssertTrue(windows.write(importRequest))
    DispatchQueue.global().async { s.handleClient(serverSide); serverSide.closeSocket() }
    XCTAssertEqual(try XCTUnwrap(windows.read(8)).u32(4), 0)
    _ = try XCTUnwrap(windows.read(312))
    var h = Data(count: 48)
    h.put32(0, 1); h.put32(4, 1); h.put32(8, VirtualMic.wireID)
    h.replaceSubrange(40..<48, with: [0x01, 11, 1, 0, 1, 0, 0, 0])
    XCTAssertTrue(windows.write(h))
    XCTAssertEqual(try XCTUnwrap(windows.read(48)).u32(20), 0)
    // The app connects, is told to start, sends audio, then goes away.
    let (appServer, app) = try pair()
    s.audioHub.adopt(appServer, uid: 501)
    XCTAssertTrue(app.write(encodeAudioMessage(.hello(version: 1))))
    XCTAssertEqual(readAudioMessage(app), .start)
    eventually({ s.status().virtualMic?.sourceConnected == true })
    app.closeSocket()
    eventually({ s.status().virtualMic?.sourceConnected == false })
    // Windows keeps getting full, successful (silent) packets.
    var iso = Data(count: 48)
    iso.put32(0, 1); iso.put32(4, 2); iso.put32(8, VirtualMic.wireID); iso.put32(12, 1); iso.put32(16, 1)
    iso.put32(24, 2 * 98); iso.put32(32, 2)
    var descriptors = Data(count: 32)
    for i in 0..<2 { descriptors.put32(i * 16, UInt32(i * 98)); descriptors.put32(i * 16 + 4, 98) }
    XCTAssertTrue(windows.write(iso + descriptors))
    eventually({ transport.map { _ in true } ?? false })
    usleep(100_000)
    now = 10; transport?.tick()
    let reply = try XCTUnwrap(windows.read(48))
    XCTAssertEqual(reply.u32(20), 0)
    XCTAssertEqual(reply.u32(24), 2 * 96)
    XCTAssertEqual(reply.u32(36), 0)
    XCTAssertEqual(s.status().virtualMic?.state, "Windows is listening")
    windows.closeSocket()
  }
}
