// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
// Native macOS implementation and support: Denis Arnst (Sapd) — https://github.com/Sapd
import Darwin
import Foundation
import IOKit
import IOUSBHost
import XCTest
@testable import LongcableCore

private final class FakeUSBTransport: USBTransferTransport {
  struct Submission {
    let address: UInt8
    let data: NSMutableData?
    let timeout: TimeInterval
    let completion: (IOReturn, Int) -> Void
  }
  var submissions = [Submission]()
  var aborts = [UInt8]()
  var configurations = [UInt8]()
  var selectedInterfaces = [UInt8]()
  var events = [String]()
  var completeAbortInline = false
  var resetError: Error?
  var types: [UInt8: UInt8] = [1: 2, 2: 2, 0x81: 2, 0x82: 3]
  var packetSize = 4
  func endpointType(_ address: UInt8) -> UInt8? { types[address] }
  func maximumPacketSize(_ address: UInt8) -> Int? { packetSize }
  func enqueueControl(_ request: IOUSBDeviceRequest, data: NSMutableData,
    completion: @escaping (IOReturn, Int) -> Void) throws {
    submissions.append(Submission(address: 0, data: data, timeout: 5, completion: completion))
    events.append("enqueue:0")
  }
  func enqueueIO(_ address: UInt8, data: NSMutableData?, timeout: TimeInterval,
    completion: @escaping (IOReturn, Int) -> Void) throws {
    submissions.append(Submission(address: address, data: data, timeout: timeout, completion: completion))
    events.append("enqueue:\(address)")
  }
  func abort(_ address: UInt8) throws {
    aborts.append(address)
    events.append("abort-begin:\(address)")
    if completeAbortInline { submissions.last(where: { $0.address == address })?.completion(kIOReturnAborted, 0) }
    events.append("abort-end:\(address)")
  }
  func clearHalt(_ address: UInt8) throws { try abort(address) }
  func reconfigure(_ configuration: UInt8) throws {
    if let resetError { throw resetError }
    configurations.append(configuration)
  }
  func selectInterface(_ number: UInt8) throws -> Bool {
    guard number <= 1 else { return false }
    if let resetError { throw resetError }
    selectedInterfaces.append(number)
    return true
  }
  func endpointsForInterface(_ number: UInt8) -> Set<UInt8>? {
    if number == 0 { return [2, 0x82] }
    if number == 1 { return [1, 0x81] }
    return nil
  }
}

final class USBTransferTests: XCTestCase {
  private func fixture() throws -> (Session, Connection, FakeUSBTransport) {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw USBError.message("socketpair") }
    let server = Connection(fds[0]), peer = Connection(fds[1])
    XCTAssertTrue(server.configureLocal())
    XCTAssertTrue(peer.configureLocal())
    let target = Target(TargetConfig(vendor: 1, product: 2, location: 3, label: "TEST"), slot: 0)
    target.identity = Identity(record: Data(count: 312), classes: Data(), configuration: 1,
      overlaySerial: false, name: "Test", serial: "Test")
    let transport = FakeUSBTransport()
    return (Session(target, server, transport: transport), peer, transport)
  }
  private func header(_ seq: UInt32, endpoint: UInt32 = 1, direction: UInt32 = 1,
    length: UInt32 = 4, flags: UInt32 = 0) -> Data {
    var h = Data(count: 48)
    h.put32(0, 1); h.put32(4, seq); h.put32(8, 0x10001)
    h.put32(12, direction); h.put32(16, endpoint); h.put32(20, flags); h.put32(24, length)
    if endpoint == 0 {
      h[40] = direction == 1 ? 0xc0 : 0x40
      h[41] = 1
      h[46] = UInt8(truncatingIfNeeded: length)
      h[47] = UInt8(truncatingIfNeeded: length >> 8)
    }
    return h
  }
  private func unlink(_ seq: UInt32, session: Session, peer: Connection) throws {
    var h = Data(count: 48)
    h.put32(0, 2); h.put32(4, seq + 1000); h.put32(8, 0x10001); h.put32(20, seq)
    session.unlink(h)
    let reply = try XCTUnwrap(peer.read(48))
    XCTAssertEqual(reply.u32(0), 4)
    XCTAssertEqual(Int32(bitPattern: reply.u32(20)), -104)
  }
  private func finish(_ index: Int, _ transport: FakeUSBTransport, _ session: Session,
    result: IOReturn = kIOReturnSuccess, bytes: Int = 4) {
    transport.submissions[index].completion(result, bytes)
    session.synchronize()
  }
  func testNativePipeCancellationLeavesQueuedRequestsAndOtherEndpointsIntact() throws {
    let (session, peer, transport) = try fixture()
    XCTAssertTrue(try session.submit(header(1)))
    XCTAssertTrue(try session.submit(header(2)))
    XCTAssertTrue(try session.submit(header(3, endpoint: 2)))
    XCTAssertEqual(transport.submissions.map(\.address), [0x81, 0x82])
    try unlink(1, session: session, peer: peer)
    XCTAssertEqual(transport.aborts, [0x81])
    XCTAssertEqual(session.outstandingCount, 3)
    XCTAssertEqual(transport.submissions.count, 2, "Queued request must wait for cancelled native completion")
    finish(0, transport, session, result: kIOReturnAborted, bytes: 0)
    XCTAssertEqual(transport.submissions.map(\.address), [0x81, 0x82, 0x81])
    XCTAssertEqual(session.outstandingCount, 2)
    finish(2, transport, session)
    XCTAssertEqual(peer.read(48)?.u32(4), 2)
    XCTAssertNotNil(peer.read(4))
    finish(1, transport, session)
    XCTAssertEqual(peer.read(48)?.u32(4), 3)
    XCTAssertNotNil(peer.read(4))
  }
  func testQueuedUnlinkDoesNotAbortNativeIO() throws {
    let (session, peer, transport) = try fixture()
    for seq: UInt32 in 1...3 { XCTAssertTrue(try session.submit(header(seq))) }
    try unlink(2, session: session, peer: peer)
    XCTAssertTrue(transport.aborts.isEmpty)
    XCTAssertEqual(session.outstandingCount, 2)
    finish(0, transport, session)
    XCTAssertEqual(peer.read(48)?.u32(4), 1); XCTAssertNotNil(peer.read(4))
    XCTAssertEqual(transport.submissions.count, 2)
    finish(1, transport, session)
    XCTAssertEqual(peer.read(48)?.u32(4), 3); XCTAssertNotNil(peer.read(4))
  }
  func testControlDirectionsShareOneNativeQueueAndAbortReturnsBeforeNextEnqueue() throws {
    let (session, peer, transport) = try fixture()
    transport.completeAbortInline = true
    XCTAssertTrue(try session.submit(header(1, endpoint: 0)))
    XCTAssertTrue(try session.submit(header(2, endpoint: 0, direction: 0, length: 0)))
    XCTAssertEqual(transport.submissions.count, 1)
    try unlink(1, session: session, peer: peer)
    session.synchronize()
    XCTAssertEqual(transport.events, ["enqueue:0", "abort-begin:0", "abort-end:0", "enqueue:0"])
    XCTAssertEqual(transport.aborts, [0])
    finish(1, transport, session, bytes: 0)
    XCTAssertEqual(peer.read(48)?.u32(4), 2)
    XCTAssertEqual(session.outstandingCount, 0)
  }
  func testCancelledNativeControlRetainsCountAndByteBudgetsUntilItsCallback() throws {
    let (session, peer, transport) = try fixture()
    for seq: UInt32 in 1...8 {
      XCTAssertTrue(try session.submit(header(seq, endpoint: 0, length: 1_048_576)))
    }
    try unlink(1, session: session, peer: peer)
    XCTAssertEqual(session.outstandingBytes, 8_388_608)
    XCTAssertEqual(session.outstandingCount, 8)
    XCTAssertFalse(try session.submit(header(9, endpoint: 0, length: 1)))
    finish(0, transport, session, result: kIOReturnAborted, bytes: 0)
    XCTAssertEqual(session.outstandingBytes, 7_340_032)
    XCTAssertTrue(try session.submit(header(9, endpoint: 0, length: 1)))
    let (other, otherPeer, otherTransport) = try fixture()
    for seq: UInt32 in 1...64 { XCTAssertTrue(try other.submit(header(seq, endpoint: 0, length: 0))) }
    try unlink(1, session: other, peer: otherPeer)
    XCTAssertEqual(other.outstandingCount, 64)
    XCTAssertFalse(try other.submit(header(65, endpoint: 0, length: 0)))
    finish(0, otherTransport, other, result: kIOReturnAborted, bytes: 0)
    XCTAssertTrue(try other.submit(header(65, endpoint: 0, length: 0)))
  }
  func testCancellationAndSequenceReuseDoNotLoseReplacement() throws {
    let (session, peer, transport) = try fixture()
    XCTAssertTrue(try session.submit(header(7)))
    try unlink(7, session: session, peer: peer)
    XCTAssertTrue(try session.submit(header(7)))
    XCTAssertEqual(session.outstandingCount, 2)
    finish(0, transport, session, result: kIOReturnAborted, bytes: 0)
    XCTAssertEqual(session.outstandingCount, 1)
    finish(1, transport, session)
    XCTAssertEqual(peer.read(48)?.u32(4), 7); XCTAssertNotNil(peer.read(4))
  }
  func testBulkAndInterruptHaveNoNativeCompletionTimeoutAndShortNotOKReturnsRemoteIOError() throws {
    let (session, peer, transport) = try fixture()
    XCTAssertTrue(try session.submit(header(1, flags: 1)))
    XCTAssertTrue(try session.submit(header(2, endpoint: 2)))
    XCTAssertEqual(transport.submissions.map(\.timeout), [0, 0])
    finish(0, transport, session, bytes: 2)
    let failed = try XCTUnwrap(peer.read(48))
    XCTAssertEqual(Int32(bitPattern: failed.u32(20)), -121)
    XCTAssertEqual(failed.u32(24), 2); XCTAssertNotNil(peer.read(2))
    finish(1, transport, session, bytes: 2)
    XCTAssertEqual(peer.read(48)?.u32(20), 0); XCTAssertNotNil(peer.read(2))
  }
  func testBulkZeroPacketIsSentBeforeReplyOrNextQueuedRequest() throws {
    let (session, peer, transport) = try fixture()
    XCTAssertTrue(peer.write(Data(repeating: 9, count: 8)))
    XCTAssertTrue(try session.submit(header(1, direction: 0, length: 8, flags: 0x40)))
    XCTAssertTrue(peer.write(Data(repeating: 7, count: 4)))
    XCTAssertTrue(try session.submit(header(2, direction: 0, length: 4)))
    finish(0, transport, session, bytes: 8)
    XCTAssertEqual(transport.submissions.count, 2)
    XCTAssertNil(transport.submissions[1].data, "nil is the native API's explicit zero-length packet")
    XCTAssertEqual(session.outstandingCount, 2)
    finish(1, transport, session, bytes: 0)
    let reply = try XCTUnwrap(peer.read(48))
    XCTAssertEqual(reply.u32(4), 1); XCTAssertEqual(reply.u32(24), 8)
    XCTAssertEqual(transport.submissions.count, 3)
    XCTAssertEqual(transport.submissions[2].data?.length, 4)
    finish(2, transport, session)
    XCTAssertEqual(peer.read(48)?.u32(4), 2)
  }
  func testNativeUnderrunUsesUSBIPShortTransferPolicy() throws {
    let (session, peer, transport) = try fixture()
    XCTAssertTrue(try session.submit(header(1, flags: 1)))
    XCTAssertTrue(try session.submit(header(2)))
    finish(0, transport, session, result: kIOReturnUnderrun, bytes: 2)
    XCTAssertEqual(Int32(bitPattern: try XCTUnwrap(peer.read(48)).u32(20)), -121)
    XCTAssertNotNil(peer.read(2))
    finish(1, transport, session, result: kIOReturnUnderrun, bytes: 2)
    XCTAssertEqual(peer.read(48)?.u32(20), 0)
    XCTAssertNotNil(peer.read(2))
  }
  func testShortNativeDescriptorStillOverlaysStableSerialIndex() throws {
    let (session, peer, transport) = try fixture()
    session.target.identity?.overlaySerial = true
    var request = header(1, endpoint: 0, length: 64)
    request[40] = 0x80; request[41] = 6; request[43] = 1
    XCTAssertTrue(try session.submit(request))
    finish(0, transport, session, result: kIOReturnUnderrun, bytes: 18)
    XCTAssertEqual(peer.read(48)?.u32(20), 0)
    XCTAssertEqual(try XCTUnwrap(peer.read(18))[16], 254)
  }
  func testUnsupportedFlagsReturnExplicitErrorWithoutBreakingFollowingRequest() throws {
    let (session, peer, transport) = try fixture()
    XCTAssertTrue(try session.submit(header(1, flags: 0x8000_0000)))
    XCTAssertEqual(Int32(bitPattern: try XCTUnwrap(peer.read(48)).u32(20)), -95)
    XCTAssertTrue(try session.submit(header(2, flags: 0x40)), "IN ZERO_PACKET is unsupported")
    XCTAssertEqual(Int32(bitPattern: try XCTUnwrap(peer.read(48)).u32(20)), -95)
    XCTAssertTrue(transport.submissions.isEmpty)
    XCTAssertTrue(try session.submit(header(3)))
    finish(0, transport, session)
    XCTAssertEqual(peer.read(48)?.u32(4), 3); XCTAssertNotNil(peer.read(4))
  }
  func testZeroLengthBulkOUTUsesOneExplicitNativeZeroPacket() throws {
    let (session, peer, transport) = try fixture()
    XCTAssertTrue(try session.submit(header(1, direction: 0, length: 0, flags: 0x40)))
    XCTAssertNil(transport.submissions[0].data)
    finish(0, transport, session, bytes: 0)
    XCTAssertEqual(transport.submissions.count, 1)
    XCTAssertEqual(peer.read(48)?.u32(20), 0)
  }
  func testAlternateZeroActuallySelectsRequestedInterfaceAndRefusesMissingOrNonzeroAlternates() throws {
    let (session, peer, transport) = try fixture()
    XCTAssertTrue(try session.submit(header(1, endpoint: 2)))
    var request = header(2, endpoint: 0, direction: 0, length: 0)
    request[40] = 1; request[41] = 11; request[44] = 1
    XCTAssertTrue(try session.submit(request))
    XCTAssertEqual(transport.selectedInterfaces, [1])
    XCTAssertTrue(transport.aborts.isEmpty, "Session must not abort endpoints of unrelated interfaces")
    XCTAssertEqual(peer.read(48)?.u32(20), 0)
    request.put32(4, 3); request[44] = 2
    XCTAssertTrue(try session.submit(request))
    XCTAssertEqual(Int32(bitPattern: try XCTUnwrap(peer.read(48)).u32(20)), -32)
    request.put32(4, 4); request[44] = 1; request[42] = 1
    XCTAssertTrue(try session.submit(request))
    XCTAssertEqual(Int32(bitPattern: try XCTUnwrap(peer.read(48)).u32(20)), -32)
    XCTAssertEqual(transport.selectedInterfaces, [1])
    finish(0, transport, session)
    XCTAssertEqual(peer.read(48)?.u32(4), 1); XCTAssertNotNil(peer.read(4))
  }
  func testNativeResetFailureCannotBeAcknowledgedAsSuccessOrStartQueuedNativeWork() throws {
    let (session, peer, transport) = try fixture()
    transport.resetError = USBError.message("Reset failed")
    var request = header(1, endpoint: 0, direction: 0, length: 0)
    request[40] = 0; request[41] = 9; request[42] = 1
    XCTAssertTrue(try session.submit(request))
    XCTAssertNotEqual(try XCTUnwrap(peer.read(48)).u32(20), 0)
    XCTAssertFalse(try session.submit(header(2)))
    XCTAssertTrue(transport.submissions.isEmpty)
  }
  func testResetDiscardsQueuedOUTAndPreResetSuccessfulCallbacksCannotSendZLPOnNewPipes() throws {
    for operation in ["configuration", "interface", "clear-halt"] {
      let (session, peer, transport) = try fixture()
      for seq: UInt32 in 1...3 {
        XCTAssertTrue(peer.write(Data(repeating: UInt8(seq), count: 4)))
        XCTAssertTrue(try session.submit(header(seq, direction: 0, flags: 0x40)))
      }
      XCTAssertTrue(peer.write(Data(repeating: 4, count: 4)))
      XCTAssertTrue(try session.submit(header(4, endpoint: 2, direction: 0, flags: 0x40)))
      XCTAssertEqual(transport.submissions.count, 2)
      var reset = header(10, endpoint: 0, direction: 0, length: 0)
      switch operation {
      case "configuration": reset[40] = 0; reset[41] = 9; reset[42] = 1
      case "interface": reset[40] = 1; reset[41] = 11; reset[44] = 1
      default: reset[40] = 2; reset[41] = 1; reset[44] = 1
      }
      XCTAssertTrue(try session.submit(reset))
      for seq: UInt32 in 2...3 {
        let aborted = try XCTUnwrap(peer.read(48))
        XCTAssertEqual(aborted.u32(4), seq)
        XCTAssertEqual(Int32(bitPattern: aborted.u32(20)), -104)
      }
      XCTAssertEqual(peer.read(48)?.u32(4), 10)
      XCTAssertEqual(session.outstandingCount, 2, "Native callbacks must still own their budget")
      // Model successful native callbacks already posted before the reset, which
      // reach Session only after pipes have been rebuilt/cleared.
      finish(0, transport, session)
      let old = try XCTUnwrap(peer.read(48))
      XCTAssertEqual(old.u32(4), 1)
      XCTAssertEqual(Int32(bitPattern: old.u32(20)), -104)
      XCTAssertEqual(transport.submissions.count, 2, "No old ZLP or queued OUT may reach a reset pipe")
      finish(1, transport, session)
      if operation == "configuration" {
        XCTAssertEqual(Int32(bitPattern: try XCTUnwrap(peer.read(48)).u32(20)), -104)
        XCTAssertEqual(transport.submissions.count, 2)
      } else {
        XCTAssertEqual(transport.submissions.count, 3, "Unrelated interface retains normal ZLP semantics")
        XCTAssertEqual(transport.submissions[2].address, 2)
        XCTAssertNil(transport.submissions[2].data)
        finish(2, transport, session, bytes: 0)
        let other = try XCTUnwrap(peer.read(48))
        XCTAssertEqual(other.u32(4), 4); XCTAssertEqual(other.u32(20), 0)
      }
      XCTAssertEqual(session.outstandingCount, 0)
      XCTAssertTrue(peer.write(Data(repeating: 5, count: 4)))
      XCTAssertTrue(try session.submit(header(5, direction: 0)))
      finish(transport.submissions.count - 1, transport, session)
      let fresh = try XCTUnwrap(peer.read(48))
      XCTAssertEqual(fresh.u32(4), 5); XCTAssertEqual(fresh.u32(20), 0)
    }
  }
  func testSameConfigurationActuallyRebuildsHardwareAndLateTeardownCallbackIsSilent() throws {
    let (session, peer, transport) = try fixture()
    var request = header(1, endpoint: 0, direction: 0, length: 0)
    request[40] = 0; request[41] = 9; request[42] = 1
    XCTAssertTrue(try session.submit(request))
    XCTAssertEqual(transport.configurations, [1])
    XCTAssertEqual(peer.read(48)?.u32(20), 0)
    XCTAssertTrue(try session.submit(header(2)))
    session.shutdownTransfers()
    finish(0, transport, session)
    XCTAssertTrue(session.pending.isEmpty)
    XCTAssertFalse(try session.submit(header(3)))
    XCTAssertNil(peer.read(1, timeoutMS: 20))
  }
}
