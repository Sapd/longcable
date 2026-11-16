// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import Foundation
import IOKit
import IOUSBHost
import XCTest
@testable import LongcableCore

final class StubSessionTarget: SessionTarget {
  let busID = VirtualMic.busID, wireID = VirtualMic.wireID
  var identity: Identity? = VirtualMic.identity(serial: "test")
  let overlayLabel = ""
  var device: SessionDevice?
  var transfers = 0, endedCount = 0
  func openDevice(_ identity: Identity, disconnected: @escaping () -> Void) throws -> SessionDevice {
    guard let device else { throw USBError.message("no device") }
    return device
  }
  func attached(_ location: UInt32) {}
  func ended() { endedCount += 1 }
  func failed(_ error: Error) {}
  func transfer(_ count: Int, status: Int32, pending: Int, native: IOReturn) { transfers += 1 }
  func queued(_ count: Int) {}
}

final class VirtualMicTransportTests: XCTestCase {
  var t: Int64 = 0
  var streaming = [Bool]()
  private func make(_ buffer: MicBuffer = MicBuffer()) -> VirtualMicTransport {
    VirtualMicTransport(buffer: buffer, serial: "abc", clock: { [unowned self] in self.t },
      startTimer: false, onStreaming: { [unowned self] in self.streaming.append($0) })
  }
  private func control(_ transport: VirtualMicTransport, _ type: UInt8, _ request: UInt8,
    value: UInt16, index: UInt16 = 0, length: UInt16, out: [UInt8] = []) -> (IOReturn, Data) {
    var r = IOUSBDeviceRequest()
    r.bmRequestType = type; r.bRequest = request; r.wValue = value; r.wIndex = index; r.wLength = length
    let data = NSMutableData(length: Int(length))!
    if !out.isEmpty { data.replaceBytes(in: NSRange(location: 0, length: out.count), withBytes: out) }
    var result: (IOReturn, Int)?
    XCTAssertNoThrow(try transport.enqueueControl(r, data: data) { result = ($0, $1) })
    XCTAssertNotNil(result, "control completes synchronously")
    return (result?.0 ?? kIOReturnError, Data(bytes: data.bytes, count: result?.1 ?? 0))
  }
  private func primed() -> MicBuffer {
    let buffer = MicBuffer()
    fill(buffer)
    return buffer
  }
  // Selecting the streaming alternate empties the buffer, so tests that check
  // sample values fill it after streaming starts.
  private func fill(_ buffer: MicBuffer) {
    buffer.write([Int16](repeating: 1000, count: MicBuffer.target + 48 * 40))
  }
  private func iso(_ transport: VirtualMicTransport, packets n: Int,
    done: @escaping (IOReturn, UInt32, [IsoPacket], NSMutableData) -> Void) {
    let data = NSMutableData(length: n * 98)!
    let packets = (0..<n).map { IsoPacket(offset: UInt32($0 * 98), length: 98) }
    XCTAssertNoThrow(try transport.enqueueIso(0x81, data: data, packets: packets, startFrame: 0,
      interval: 1, asap: true) { done($0, $1, $2, data) })
  }
  private func stream(_ transport: VirtualMicTransport) {
    XCTAssertTrue(try transport.selectInterface(1, alternate: 1))
  }

  func testGetDeviceAndConfigurationDescriptors() {
    let transport = make()
    let (r1, device) = control(transport, 0x80, 6, value: 0x0100, length: 64)
    XCTAssertEqual(r1, kIOReturnSuccess); XCTAssertEqual(device, VirtualMic.deviceDescriptor)
    let (r2, short) = control(transport, 0x80, 6, value: 0x0200, length: 9)
    XCTAssertEqual(r2, kIOReturnSuccess); XCTAssertEqual(short, VirtualMic.configurationDescriptor.prefix(9))
    let (_, config) = control(transport, 0x80, 6, value: 0x0200, length: 512)
    XCTAssertEqual(config, VirtualMic.configurationDescriptor)
    let (_, product) = control(transport, 0x80, 6, value: 0x0302, index: 0x0409, length: 255)
    XCTAssertEqual(product, serialDescriptor("Longcable Mic"))
    let (r3, _) = control(transport, 0x80, 6, value: 0x0309, length: 255)
    XCTAssertEqual(r3, pipeStalled)
  }

  func testGetStatusReturnsZeros() {
    let (r, data) = control(make(), 0x80, 0, value: 0, length: 2)
    XCTAssertEqual(r, kIOReturnSuccess); XCTAssertEqual(data, Data([0, 0]))
  }

  func testUnknownRequestStalls() {
    XCTAssertEqual(control(make(), 0x80, 6, value: 0x0600, length: 10).0, pipeStalled)  // device qualifier
    XCTAssertEqual(control(make(), 0xA1, 0x81, value: 0x0100, index: 0x0200, length: 2).0, pipeStalled)
    XCTAssertEqual(control(make(), 0x40, 0x01, value: 0, length: 0).0, pipeStalled)
  }

  func testSampleRateSetGet() {
    let transport = make()
    XCTAssertEqual(control(transport, 0x22, 0x01, value: 0x0100, index: 0x81, length: 3,
      out: [0x80, 0xBB, 0x00]).0, kIOReturnSuccess)
    XCTAssertEqual(control(transport, 0x22, 0x01, value: 0x0100, index: 0x81, length: 3,
      out: [0x44, 0xAC, 0x00]).0, pipeStalled)
    for request: UInt8 in [0x81, 0x82, 0x83] {
      let (r, data) = control(transport, 0xA2, request, value: 0x0100, index: 0x81, length: 3)
      XCTAssertEqual(r, kIOReturnSuccess); XCTAssertEqual(data, Data([0x80, 0xBB, 0x00]))
    }
  }

  func testSampleRateQueriesForOtherTargetsStall() {
    let transport = make()
    XCTAssertEqual(control(transport, 0xA2, 0x81, value: 0x0100, index: 0x82, length: 3).0, pipeStalled)
    XCTAssertEqual(control(transport, 0xA2, 0x81, value: 0x0200, index: 0x81, length: 3).0, pipeStalled)
  }

  // Windows may queue one URB covering 128 ms. Audio must be taken frame by frame
  // as the frames pass, not all at completion, or the 100 ms buffer overflows.
  func testLargeURBTakesAudioFrameByFrame() {
    let buffer = MicBuffer()
    let transport = make(buffer)
    stream(transport)
    var result: ([IsoPacket], Data)?
    iso(transport, packets: 128) { _, _, packets, data in result = (packets, Data(referencing: data)) }
    for ms in 1...129 {
      buffer.write([Int16](repeating: 1000, count: 48))
      t = Int64(ms); transport.tick()
    }
    let (packets, data) = try! XCTUnwrap(result)
    let silent = packets.filter { p in
      data[Int(p.offset)..<Int(p.offset + p.actualLength)].allSatisfy { $0 == 0 }
    }.count
    XCTAssertLessThanOrEqual(silent, 21, "only the 20 ms priming may be silent")
    XCTAssertTrue(packets.suffix(100).allSatisfy { p in
      data[Int(p.offset)..<Int(p.offset + p.actualLength)].contains { $0 != 0 }
    }, "no gaps once primed")
  }

  func testSelectingStreamingEmptiesStaleAudio() {
    let transport = make(primed())
    stream(transport)
    var data: Data?
    iso(transport, packets: 1) { _, _, _, d in data = Data(referencing: d) }
    t = 5; transport.tick()
    XCTAssertEqual(data?.u16LE(0), 0)
  }

  func testSelectAlternateStartsAndStopsStreaming() throws {
    let transport = make()
    XCTAssertTrue(transport.supportsAlternate(1, alternate: 1))
    XCTAssertFalse(transport.supportsAlternate(1, alternate: 2))
    XCTAssertTrue(transport.supportsAlternate(0, alternate: 0))
    XCTAssertEqual(transport.endpointsForInterface(1), [0x81])
    XCTAssertNil(transport.endpointType(0x81))
    XCTAssertTrue(try transport.selectInterface(1, alternate: 1))
    XCTAssertEqual(transport.endpointType(0x81), 1)
    XCTAssertEqual(transport.maximumPacketSize(0x81), 98)
    XCTAssertEqual(transport.currentAlternate(1), 1)
    XCTAssertTrue(try transport.selectInterface(1, alternate: 0))
    XCTAssertNil(transport.endpointType(0x81))
    XCTAssertEqual(streaming, [true, false])
  }

  func testIsoURBCompletesOnlyWhenDue() {
    let transport = make(primed())
    stream(transport)
    var result: (IOReturn, UInt32, [IsoPacket])?
    iso(transport, packets: 8) { r, f, p, _ in result = (r, f, p) }
    t = 8; transport.tick()
    XCTAssertNil(result)
    t = 9; transport.tick()
    XCTAssertEqual(result?.0, kIOReturnSuccess)
    XCTAssertEqual(result?.1, 1)
    XCTAssertEqual(result?.2.map(\.actualLength), [UInt32](repeating: 96, count: 8))
    XCTAssertEqual(result?.2.map(\.status), [Int32](repeating: 0, count: 8))
  }

  func testLateTimerCompletesDueURBsAndKeepsTimeline() {
    let transport = make(primed())
    stream(transport)
    var frames = [UInt32]()
    for _ in 0..<3 { iso(transport, packets: 4) { _, frame, _, _ in frames.append(frame) } }
    t = 20; transport.tick()
    XCTAssertEqual(frames, [1, 5, 9])
    iso(transport, packets: 4) { _, frame, _, _ in frames.append(frame) }
    t = 40; transport.tick()
    XCTAssertEqual(frames.last, 13)
  }

  func testUnderrunSendsFullSizedSilence() {
    let transport = make()
    stream(transport)
    var result: ([IsoPacket], Data)?
    iso(transport, packets: 4) { _, _, packets, data in result = (packets, Data(referencing: data)) }
    t = 10; transport.tick()
    XCTAssertEqual(result?.0.map(\.actualLength), [96, 96, 96, 96])
    XCTAssertEqual(result?.0.map(\.status), [0, 0, 0, 0])
    XCTAssertTrue(result?.1.prefix(96).allSatisfy { $0 == 0 } ?? false)
  }

  func testPacketsCarryBufferedSamples() {
    let buffer = MicBuffer()
    let transport = make(buffer)
    stream(transport)
    fill(buffer)
    var data: Data?
    iso(transport, packets: 1) { _, _, _, d in data = Data(referencing: d) }
    t = 5; transport.tick()
    XCTAssertEqual(data?.u16LE(0), 1000)
  }

  func testResyncAfterLongStall() {
    let transport = make()
    stream(transport)
    var frames = [UInt32]()
    iso(transport, packets: 2) { _, frame, _, _ in frames.append(frame) }
    t = 500; transport.tick()
    iso(transport, packets: 2) { _, frame, _, _ in frames.append(frame) }
    t = 600; transport.tick()
    XCTAssertEqual(frames, [1, 501])
  }

  func testAlternateZeroAndAbortCancelQueuedURBs() throws {
    let transport = make()
    stream(transport)
    var results = [IOReturn]()
    iso(transport, packets: 4) { r, _, _, _ in results.append(r) }
    try transport.abort(0x81)
    XCTAssertEqual(results, [kIOReturnAborted])
    iso(transport, packets: 4) { r, _, _, _ in results.append(r) }
    XCTAssertTrue(try transport.selectInterface(1, alternate: 0))
    XCTAssertEqual(results, [kIOReturnAborted, kIOReturnAborted])
    transport.release()
    XCTAssertEqual(streaming, [true, false])
  }

  func testReleaseWhileStreamingStopsCapture() {
    let transport = make()
    stream(transport)
    transport.release()
    XCTAssertEqual(streaming, [true, false])
  }

  func testSessionOverVirtualTransport() throws {
    var fds: [Int32] = [0, 0]
    XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
    let server = Connection(fds[0]), peer = Connection(fds[1])
    XCTAssertTrue(server.configureLocal()); XCTAssertTrue(peer.configureLocal())
    let buffer = MicBuffer()
    let transport = make(buffer)
    let target = StubSessionTarget()
    let session = Session(target, server, transport: transport)
    // SET_INTERFACE 1 alt 1.
    var h = Data(count: 48)
    h.put32(0, 1); h.put32(4, 1); h.put32(8, VirtualMic.wireID); h.put32(12, 0); h.put32(16, 0)
    h.replaceSubrange(40..<48, with: [0x01, 11, 1, 0, 1, 0, 0, 0])
    XCTAssertTrue(try session.submit(h))
    session.synchronize()
    let reply1 = try XCTUnwrap(peer.read(48))
    XCTAssertEqual(reply1.u32(0), 3); XCTAssertEqual(reply1.u32(20), 0)
    fill(buffer)
    // ISO IN, 4 packets × 98 bytes.
    var iso = Data(count: 48)
    iso.put32(0, 1); iso.put32(4, 2); iso.put32(8, VirtualMic.wireID); iso.put32(12, 1); iso.put32(16, 1)
    iso.put32(20, 2); iso.put32(24, 4 * 98); iso.put32(32, 4); iso.put32(36, 1)
    var descriptors = Data(count: 64)
    for i in 0..<4 { descriptors.put32(i * 16, UInt32(i * 98)); descriptors.put32(i * 16 + 4, 98) }
    let writer = Thread { _ = peer.write(iso); _ = peer.write(descriptors) }
    writer.start()
    XCTAssertTrue(try session.submit(try XCTUnwrap(server.read(48))))
    session.synchronize()
    t = 10; transport.tick()
    session.synchronize()
    let reply = try XCTUnwrap(peer.read(48))
    XCTAssertEqual(reply.u32(0), 3); XCTAssertEqual(reply.u32(4), 2)
    XCTAssertEqual(reply.u32(20), 0)
    // The buffer is far above target, so every packet carries 49 samples.
    XCTAssertEqual(reply.u32(24), 4 * 98)
    XCTAssertEqual(reply.u32(32), 4); XCTAssertEqual(reply.u32(36), 0)
    let payload = try XCTUnwrap(peer.read(4 * 98))
    XCTAssertEqual(payload.u16LE(0), 1000)
    let returned = try XCTUnwrap(peer.read(64))
    XCTAssertEqual(returned.u32(8), 98)
    session.shutdownTransfers()
  }
}
