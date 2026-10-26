// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation
import IOKit
import XCTest
@testable import LongcableCore

final class IsochronousTests: XCTestCase {
  func testDescriptorRoundTripBigEndianIncludingSignedStatus() {
    let packets = [IsoPacket(offset: 2, length: 4, actualLength: 3, status: -18),
      IsoPacket(offset: 9, length: 1)]
    let encoded = IsoPacket.encode(packets)
    XCTAssertEqual(encoded.prefix(8), Data([0, 0, 0, 2, 0, 0, 0, 4]))
    XCTAssertEqual(IsoPacket.decode(encoded, count: 2, bufferLength: 10), packets)
  }
  func testDescriptorBoundsRejectTruncationOverflowOverlapAndExcessActualLength() {
    let bad = [[IsoPacket(offset: 0, length: 11)], [IsoPacket(offset: UInt32.max, length: 2)],
      [IsoPacket(offset: 9, length: UInt32.max)], [IsoPacket(offset: 1, length: 2, actualLength: 3)],
      [IsoPacket(offset: 0, length: 4), IsoPacket(offset: 3, length: 2)]]
    for packets in bad { XCTAssertNil(IsoPacket.decode(IsoPacket.encode(packets), count: packets.count, bufferLength: 10)) }
    XCTAssertNil(IsoPacket.decode(Data(count: 15), count: 1, bufferLength: 10))
    XCTAssertNil(IsoPacket.decode(Data(), count: Int.max, bufferLength: 10))
    XCTAssertNil(IsoPacket.decode(Data(), count: 0, bufferLength: 10))
  }
  func testPacketCapAndOneMiBBoundary() {
    let packets = (0..<1024).map { IsoPacket(offset: UInt32($0 * 1024), length: 1024) }
    XCTAssertEqual(IsoPacket.decode(IsoPacket.encode(packets), count: 1024, bufferLength: 1_048_576), packets)
    XCTAssertNil(IsoPacket.decode(IsoPacket.encode(packets), count: 1024, bufferLength: 1_048_577))
  }
  func testASAPAndForeignOrExpiredFrameFallBackWithLead() {
    XCTAssertEqual(isoFirstFrame(current: 100, requested: 110, asap: true, highSpeed: false), 102)
    XCTAssertEqual(isoFirstFrame(current: 100, requested: 110, asap: false, highSpeed: false), 110)
    XCTAssertEqual(isoFirstFrame(current: 100, requested: 10, asap: false, highSpeed: false), 102)
    XCTAssertEqual(isoFirstFrame(current: 100, requested: 100000, asap: false, highSpeed: false), 102)
    XCTAssertEqual(isoFirstFrame(current: 100, requested: 880, asap: false, highSpeed: true), 110)
    XCTAssertEqual(isoFirstFrame(current: 100, requested: 881, asap: false, highSpeed: true), 102)
  }
  func testNativeFrameConstructionAndPartialCompletionMapping() {
    let packets = [IsoPacket(offset: 0, length: 4), IsoPacket(offset: 8, length: 4)]
    let list = IsoFrameList(data: NSMutableData(length: 12)!, packets: packets)
    XCTAssertEqual(list.pointer[0].requestCount, 4); XCTAssertEqual(list.pointer[1].offset, 8)
    XCTAssertEqual(list.pointer[0].status, kIOReturnInvalid)
    list.pointer[0].status = kIOReturnUnderrun; list.pointer[0].completeCount = 2
    list.pointer[1].status = kIOReturnSuccess; list.pointer[1].completeCount = 99
    XCTAssertEqual(list.results(overall: kIOReturnSuccess).map(\.actualLength), [2, 4])
    XCTAssertEqual(list.results(overall: kIOReturnSuccess).map(\.status), [0, 0])
    list.pointer[1].status = kIOReturnInvalid; list.pointer[1].completeCount = 0
    XCTAssertEqual(list.results(overall: kIOReturnAborted)[1].status, -104)
    XCTAssertEqual(list.results(overall: kIOReturnSuccess)[1].status, -18)
    XCTAssertEqual(isoPacketStatus(kIOReturnError), -71)
    XCTAssertEqual(isoPacketStatus(kIOReturnOverrun), -75)
  }
  func testAlternateDescriptorLookupIncludesNonzeroAndRejectsMalformedData() {
    var config = Data([9, 2, 0, 0, 1, 1, 0, 0x80, 50])
    config.append(contentsOf: [9, 4, 2, 0, 0, 1, 2, 3, 0])
    config.append(contentsOf: [9, 4, 2, 1, 1, 1, 2, 3, 0, 7, 5, 0x83, 1, 64, 0, 1])
    XCTAssertEqual(interfaceOffset(config, number: 2, alternate: 1), 18)
    XCTAssertNil(interfaceOffset(config, number: 2, alternate: 2))
    config[18] = 255
    XCTAssertNil(interfaceOffset(config, number: 2, alternate: 1))
  }
  private final class FakePipe: IsoRequestPipe {
    var frames = [UInt64]()
    var lists = [IsoFrameList]()
    var completions = [(IOReturn) -> Void]()
    var fails = false
    func enqueue(data: NSMutableData, list: IsoFrameList, firstFrame: UInt64,
      completion: @escaping (IOReturn) -> Void) throws {
      if fails { throw NSError(domain: "fake", code: Int(kIOReturnError)) }
      frames.append(firstFrame); lists.append(list); completions.append(completion)
    }
  }
  func testFakePipeExecutesProductionSchedulingAndResultMapping() throws {
    let pipe = FakePipe()
    let queue = IsoPipeQueue(pipe: pipe, highSpeed: false, interval: 1,
      maximumPayload: 64, currentFrame: { 100 })
    let packets = [IsoPacket(offset: 0, length: 4), IsoPacket(offset: 8, length: 4)]
    var result: [IsoPacket] = [], frame: UInt32 = 0
    for _ in 0..<2 {
      try queue.enqueue(data: NSMutableData(length: 12)!, packets: packets,
        startFrame: 0, requestedInterval: 1, asap: true) { _, start, completed in
        frame = start; result = completed
      }
    }
    XCTAssertEqual(pipe.frames, [102, 104])
    XCTAssertEqual(pipe.lists[0].pointer[1].offset, 8)
    pipe.lists[0].pointer[0].status = kIOReturnSuccess
    pipe.lists[0].pointer[0].completeCount = 3
    pipe.completions[0](kIOReturnSuccess)
    XCTAssertEqual(frame, 102); XCTAssertEqual(result.map(\.actualLength), [3, 0])
    XCTAssertEqual(result.map(\.status), [0, -18])
    queue.reset()
    try queue.enqueue(data: NSMutableData(length: 12)!, packets: packets,
      startFrame: 110, requestedInterval: 0, asap: false) { _, _, _ in }
    XCTAssertEqual(pipe.frames.last, 110)
  }
  func testHighSpeedMicroframeIntervalDurationAndFailedEnqueueDoNotOverlap() throws {
    let pipe = FakePipe()
    let queue = IsoPipeQueue(pipe: pipe, highSpeed: true, interval: 2,
      maximumPayload: 3072, currentFrame: { 100 })
    let packets = (0..<8).map { IsoPacket(offset: UInt32($0 * 4), length: 4) }
    var frames = [UInt32]()
    for _ in 0..<2 {
      try queue.enqueue(data: NSMutableData(length: 32)!, packets: packets,
        startFrame: 0, requestedInterval: 2, asap: true) { _, frame, _ in frames.append(frame) }
    }
    XCTAssertEqual(pipe.frames, [102, 104])
    pipe.completions[0](kIOReturnSuccess); pipe.completions[1](kIOReturnSuccess)
    XCTAssertEqual(frames, [816, 832])
    pipe.fails = true
    XCTAssertThrowsError(try queue.enqueue(data: NSMutableData(length: 32)!, packets: packets,
      startFrame: 0, requestedInterval: 2, asap: true) { _, _, _ in })
    pipe.fails = false
    try queue.enqueue(data: NSMutableData(length: 32)!, packets: packets,
      startFrame: 0, requestedInterval: 2, asap: true) { _, _, _ in }
    XCTAssertEqual(pipe.frames.last, 106)
    queue.reset()
    try queue.enqueue(data: NSMutableData(length: 32)!, packets: packets,
      startFrame: 0, requestedInterval: 2, asap: true) { _, _, _ in }
    XCTAssertEqual(pipe.frames.last, 102)
  }
  func testNativeSchedulingRejectsPayloadIntervalAndDurationViolations() throws {
    let pipe = FakePipe()
    let queue = IsoPipeQueue(pipe: pipe, highSpeed: false, interval: 1,
      maximumPayload: 64, currentFrame: { 100 })
    for (packets, interval) in [([IsoPacket(offset: 0, length: 65)], UInt32(1)),
      ([IsoPacket(offset: 0, length: 1)], UInt32(2)),
      ([IsoPacket(offset: 99, length: 2)], UInt32(1))] {
      XCTAssertThrowsError(try queue.enqueue(data: NSMutableData(length: 100)!, packets: packets,
        startFrame: 0, requestedInterval: interval, asap: true) { _, _, _ in })
    }
    let slow = IsoPipeQueue(pipe: pipe, highSpeed: false, interval: 32768,
      maximumPayload: 64, currentFrame: { 100 })
    XCTAssertThrowsError(try slow.enqueue(data: NSMutableData(length: 1)!,
      packets: [IsoPacket(offset: 0, length: 0), IsoPacket(offset: 0, length: 1)], startFrame: 0, requestedInterval: 32768,
      asap: true) { _, _, _ in })
    XCTAssertTrue(pipe.frames.isEmpty)
  }

  func testHighSpeedSubmillisecondListsAreExplicitlyUnsupported() {
    let pipe = FakePipe()
    let queue = IsoPipeQueue(pipe: pipe, highSpeed: true, interval: 1,
      maximumPayload: 64, currentFrame: { 100 })
    XCTAssertThrowsError(try queue.enqueue(data: NSMutableData(length: 4)!,
      packets: [IsoPacket(offset: 0, length: 4)], startFrame: 0, requestedInterval: 1,
      asap: true) { _, _, _ in }) { error in
      XCTAssertEqual(usbStatus(IOReturn(truncatingIfNeeded: (error as NSError).code)), -95)
    }
    XCTAssertTrue(pipe.frames.isEmpty)
  }
  func testSparseListSchedulingChecksLastTransactionInsteadOfTrailingIdleInterval() throws {
    let pipe = FakePipe()
    let queue = IsoPipeQueue(pipe: pipe, highSpeed: false, interval: 1024,
      maximumPayload: 64, currentFrame: { 100 })
    try queue.enqueue(data: NSMutableData(length: 4)!,
      packets: [IsoPacket(offset: 0, length: 4)], startFrame: 0, requestedInterval: 1024,
      asap: true) { _, _, _ in }
    XCTAssertEqual(pipe.frames, [102])
  }

  private func configuration() -> Data {
    Data([9, 2, 0, 0, 2, 1, 0, 0x80, 50,
      9, 4, 0, 0, 1, 3, 0, 0, 0, 7, 5, 0x81, 3, 8, 0, 1,
      9, 4, 1, 0, 0, 1, 2, 0, 0,
      9, 4, 1, 1, 2, 1, 2, 0, 0,
      7, 5, 0x82, 1, 64, 0, 2, 7, 5, 2, 1, 64, 0, 2])
  }
  func testProductionAlternateMapOpensSelectedPipesAndPreservesOtherInterface() throws {
    let map = InterfacePipeMap<FakePipe>()
    var events = [String]()
    let config = configuration()
    func select(_ alternate: UInt8) throws {
      try map.replace(number: 1, alternate: alternate, configuration: config, highSpeed: false,
        select: { events.append("select:\(alternate)") },
        open: { endpoint in events.append("open:\(endpoint.address)"); return FakePipe() })
    }
    try map.replace(number: 0, alternate: 0, configuration: config, highSpeed: false,
      select: {}, open: { _ in FakePipe() })
    let unrelated = try XCTUnwrap(map.pipes[0x81])
    try select(0)
    XCTAssertEqual(map.endpoints(1), []); XCTAssertEqual(map.alternates[1], 0)
    try select(1)
    XCTAssertEqual(events, ["select:0", "select:1", "open:130", "open:2"])
    XCTAssertEqual(map.endpoints(1), [0x82, 2]); XCTAssertEqual(map.alternates[1], 1)
    XCTAssertEqual(map.descriptors[0x82]?.type, 1)
    XCTAssertEqual(map.descriptors[0x82]?.maximumPayload, 64)
    XCTAssertEqual(map.descriptors[0x82]?.isoInterval, 2)
    weak var old = map.pipes[0x82]
    try select(0)
    XCTAssertNil(old); XCTAssertNil(map.pipes[0x82]); XCTAssertNil(map.descriptors[2])
    XCTAssertTrue(map.pipes[0x81] === unrelated); XCTAssertEqual(map.alternates[0], 0)
    XCTAssertThrowsError(try select(2))
    XCTAssertEqual(events.last, "select:0", "Invalid alternate must not reach native selection")
  }
  func testAlternateOpenFailureCannotLeaveStaleOrPartiallyPublishedPipes() throws {
    let map = InterfacePipeMap<FakePipe>(), config = configuration()
    try map.replace(number: 0, alternate: 0, configuration: config, highSpeed: false,
      select: {}, open: { _ in FakePipe() })
    try map.replace(number: 1, alternate: 1, configuration: config, highSpeed: false,
      select: {}, open: { _ in FakePipe() })
    XCTAssertThrowsError(try map.replace(number: 1, alternate: 1, configuration: config, highSpeed: false,
      select: {}, open: { endpoint in
        if endpoint.address == 2 { throw USBError.message("open failed") }; return FakePipe()
      }))
    XCTAssertEqual(Set(map.pipes.keys), [0x81]); XCTAssertEqual(Set(map.descriptors.keys), [0x81])
    XCTAssertNil(map.alternates[1]); XCTAssertNil(map.endpoints(1))
  }
  func testDescriptorMetadataSupportsHighBandwidthMicroframeEndpointsAndStrictValidation() throws {
    var config = configuration()
    config[47] = 0; config[48] = 0x14 // 1024 bytes, three transactions per microframe
    let endpoints = try XCTUnwrap(interfaceEndpoints(config, number: 1, alternate: 1, highSpeed: true))
    XCTAssertEqual(endpoints[0].maximumPayload, 3072); XCTAssertEqual(endpoints[0].isoInterval, 2)
    XCTAssertNil(interfaceEndpoints(config, number: 1, alternate: 1, highSpeed: false))
    config[48] = 0x1c // reserved multiplier
    XCTAssertNil(interfaceEndpoints(config, number: 1, alternate: 1, highSpeed: true))
    config = configuration(); config[49] = 0 // bInterval
    XCTAssertNil(interfaceEndpoints(config, number: 1, alternate: 1, highSpeed: false))
    config = configuration(); config[52] = 0x82 // duplicate endpoint address
    XCTAssertNil(interfaceEndpoints(config, number: 1, alternate: 1, highSpeed: false))
    config = configuration(); config[38] = 3 // bNumEndpoints mismatch
    XCTAssertNil(interfaceEndpoints(config, number: 1, alternate: 1, highSpeed: false))
  }
  func testNativeListLifetimeIsOwnedByCompletionEvenAfterQueueAndOtherOwnersAreReleased() throws {
    let pipe = FakePipe()
    var queue: IsoPipeQueue? = IsoPipeQueue(pipe: pipe, highSpeed: false, interval: 1,
      maximumPayload: 64, currentFrame: { 100 })
    var completed = false
    try queue!.enqueue(data: NSMutableData(length: 4)!, packets: [IsoPacket(offset: 0, length: 4)],
      startFrame: 0, requestedInterval: 1, asap: true) { result, _, packets in
      XCTAssertEqual(result, kIOReturnAborted); XCTAssertEqual(packets[0].status, -104)
      completed = true
    }
    weak var allocation = pipe.lists.first
    pipe.lists.removeAll(); queue = nil
    XCTAssertNotNil(allocation)
    pipe.completions[0](kIOReturnAborted)
    XCTAssertTrue(completed)
    pipe.completions.removeAll()
    XCTAssertNil(allocation)
  }

}
