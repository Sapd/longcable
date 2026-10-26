// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import IOKit
import XCTest

@testable import LongcableCore

final class CoreTests: XCTestCase {
  func pair() throws -> (Connection, Connection) {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
      throw USBError.message("socketpair")
    }
    let a = Connection(fds[0])
    let b = Connection(fds[1])
    XCTAssertTrue(a.configureLocal())
    XCTAssertTrue(b.configureLocal())
    return (a, b)
  }
  func target(_ slot: Int = 0) -> Target {
    Target(
      TargetConfig(
        vendor: 0x231d, product: slot == 0 ? 0x201 : 0x200, location: 0x1234,
        label: slot == 0 ? "LEFT" : "RIGHT"), slot: slot)
  }
  func testConfigAcceptsIdenticalModelsOnDifferentPorts() throws {
    XCTAssertNoThrow(
      try DaemonConfig(arguments: [
        "127.0.0.1", "127.0.0.1", "231d", "0201", "1234", "LEFT", "231d", "0201", "5678", "OTHER",
      ]))
    XCTAssertThrowsError(
      try DaemonConfig(arguments: ["127.0.0.1", "127.0.0.1", "fffff", "0201", "1234", "LEFT"]))
    XCTAssertThrowsError(
      try DaemonConfig(arguments: ["127.0.0.1", "127.0.0.1", "231d", "0201", "1234", "LEFT;bad"]))
    let config = try DaemonConfig(arguments: [
      "127.0.0.1", "127.0.0.1", "231d", "0201", "1234", "LEFT", "231d", "0200", "5678", "RIGHT",
    ])
    XCTAssertEqual(config.targets.count, 2)
    XCTAssertTrue(config.targets[0].matches(vendor: 0x231d, product: 0x201, location: 999))
    XCTAssertFalse(config.targets[0].matches(vendor: 0x231d, product: 0x200, location: 0x1234))
    let legacy = try DaemonConfig(arguments: ["127.0.0.1", "127.0.0.1", "231d", "0201", "1234"])
    XCTAssertFalse(legacy.targets[0].matches(vendor: 0x231d, product: 0x201, location: 999))
  }
  func testSerialAndWireEncoding() {
    XCTAssertEqual(serialDescriptor("LEFT"), Data([10, 3, 76, 0, 69, 0, 70, 0, 84, 0]))
    var data = Data(count: 8)
    data.put32(0, 0x1234_5678)
    data.put16(4, 0x111)
    XCTAssertEqual(data.u32(0), 0x1234_5678)
    XCTAssertEqual(Array(data[4..<6]), [1, 17])
    XCTAssertEqual(usbStatus(pipeStalled), -32)
    XCTAssertEqual(usbStatus(IOReturn(bitPattern: 0xe000_5000)), -32)
  }
  func testPartialFrameTimeoutAndLegitimateIdle() throws {
    let (a, b) = try pair()
    XCTAssertTrue(b.write(Data([1])))
    let start = monotonicMS()
    XCTAssertNil(a.read(8, timeoutMS: 80))
    XCTAssertLessThan(monotonicMS() - start, 1000)
    let (c, d) = try pair()
    let done = expectation(description: "idle frame")
    DispatchQueue.global().async {
      usleep(150_000)
      XCTAssertTrue(d.write(Data(repeating: 7, count: 8)))
      done.fulfill()
    }
    XCTAssertEqual(c.read(8, idle: true, timeoutMS: 50), Data(repeating: 7, count: 8))
    wait(for: [done], timeout: 2)
    d.closeSocket()
    XCTAssertNil(c.read(8, idle: true))
  }
  func testSlowReaderCannotExtendWriteDeadline() throws {
    let (a, b) = try pair()
    var size: Int32 = 4096
    XCTAssertEqual(setsockopt(a.fd, SOL_SOCKET, SO_SNDBUF, &size, 4), 0)
    let finished = expectation(description: "slow reader stopped")
    DispatchQueue.global().async {
      for _ in 0..<10 {
        usleep(20_000)
        var bytes = [UInt8](repeating: 0, count: 1024)
        _ = recv(b.fd, &bytes, bytes.count, MSG_DONTWAIT)
      }
      finished.fulfill()
    }
    let start = monotonicMS()
    XCTAssertFalse(a.write(Data(count: 1_048_576), timeoutMS: 80))
    XCTAssertLessThan(monotonicMS() - start, 500)
    wait(for: [finished], timeout: 2)
  }
  func testStaleCallbackDoesNotConsumeReplacementOrCrossDevices() throws {
    let (a, b) = try pair()
    let t = target()
    let session = Session(t, a)
    let old = Transfer(seq: 7, direction: 1, endpoint: 1, length: 4)
    let replacement = Transfer(seq: 7, direction: 1, endpoint: 1, length: 4)
    session.pending[7] = replacement
    session.complete(old, result: kIOReturnSuccess, bytes: 4)
    XCTAssertTrue(session.pending[7] === replacement)
    let (c, d) = try pair()
    let second = Session(target(1), c)
    let other = Transfer(seq: 7, direction: 1, endpoint: 1, length: 4)
    second.pending[7] = other
    session.complete(replacement, result: kIOReturnSuccess, bytes: 99)
    XCTAssertTrue(second.pending[7] === other)
    let h = try XCTUnwrap(b.read(48))
    XCTAssertEqual(h.u32(24), 4)
    XCTAssertEqual(b.read(4), Data(count: 4))
    second.complete(other, result: kIOReturnSuccess, bytes: 4)
    XCTAssertEqual(d.read(48)?.u32(8), 0x10002)
    XCTAssertNotNil(d.read(4))
    session.closed = true
    session.pending[7] = old
    session.complete(old, result: kIOReturnSuccess, bytes: 4)
    XCTAssertTrue(session.pending[7] === old)
  }
  func testCancellationCompletionRaceHasOneOutcome() throws {
    for _ in 0..<200 {
      let (a, b) = try pair()
      let s = Session(target(), a)
      let job = Transfer(seq: 10, direction: 0, endpoint: 1, length: 0)
      s.pending[10] = job
      var h = Data(count: 48)
      h.put32(0, 2)
      h.put32(4, 11)
      h.put32(8, 0x10001)
      h.put32(20, 10)
      let unlinkHeader = h
      DispatchQueue.concurrentPerform(iterations: 2) { i in
        if i == 0 {
          s.complete(job, result: kIOReturnSuccess, bytes: 0)
        } else {
          s.unlink(unlinkHeader)
        }
      }
      XCTAssertNil(s.pending[10])
      let first = try XCTUnwrap(b.read(48))
      if first.u32(0) == 3 {
        let second = try XCTUnwrap(b.read(48))
        XCTAssertEqual(second.u32(0), 4)
        XCTAssertEqual(second.u32(20), 0)
      } else {
        XCTAssertEqual(first.u32(0), 4)
        XCTAssertEqual(Int32(bitPattern: first.u32(20)), -104)
      }
    }
  }
  func testSubmitLimitsAndWrongDevice() throws {
    let (a, _) = try pair()
    let s = Session(target(), a)
    var h = Data(count: 48)
    h.put32(0, 1)
    h.put32(8, 0x10002)
    XCTAssertFalse(try s.submit(h))
    h.put32(8, 0x10001)
    h.put32(24, 1_048_577)
    XCTAssertFalse(try s.submit(h))
    h.put32(24, 0)
    h.put32(32, 1)
    XCTAssertFalse(try s.submit(h))
    h.put32(32, 0)
    h.put32(12, 1)
    h.put32(16, 1)
    for i in 0..<64 {
      s.pending[UInt32(i)] = Transfer(seq: UInt32(i), direction: 1, endpoint: 1, length: 0)
    }
    h.put32(4, 65)
    XCTAssertFalse(try s.submit(h))
    s.pending.removeAll()
    s.pending[1] = Transfer(seq: 1, direction: 1, endpoint: 1, length: 8_388_608)
    h.put32(24, 1)
    XCTAssertFalse(try s.submit(h))
  }
  func testTargetedUnshareDoesNotInterruptOtherConnection() throws {
    let (a, b) = try pair()
    let (c, d) = try pair()
    let left = target()
    let right = target(1)
    XCTAssertTrue(left.begin(a))
    XCTAssertTrue(right.begin(c))
    left.setEnabled(false)
    XCTAssertNil(b.read(1))
    XCTAssertTrue(c.write(Data([9])))
    XCTAssertEqual(d.read(1), Data([9]))
    XCTAssertFalse(left.begin(a))
    XCTAssertTrue(right.isEnabled)
  }
  func testControlAuthorizationAndUnknownActions() throws {
    let config = try DaemonConfig(arguments: [
      "127.0.0.1", "127.0.0.1", "231d", "0201", "1234", "LEFT",
    ])
    let server = USBServer(config: config)
    XCTAssertFalse(
      server.handleControl(ControlRequest(action: "unshare", busID: "1-1"), uid: UInt32.max).ok)
    XCTAssertFalse(server.handleControl(ControlRequest(action: "run", busID: "1-1"), uid: 0).ok)
    XCTAssertFalse(
      server.handleControl(ControlRequest(action: "reconnect", busID: "1-99"), uid: 0).ok)
    XCTAssertTrue(server.handleControl(ControlRequest(action: "status"), uid: UInt32.max).ok)
  }
}
