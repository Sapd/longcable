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
  func testDescriptorBoundsRejectTruncationOverflowAndExcessTotalLength() {
    let bad = [[IsoPacket(offset: 0, length: 11)], [IsoPacket(offset: UInt32.max, length: 2)],
      [IsoPacket(offset: 9, length: UInt32.max)],
      [IsoPacket(offset: 0, length: 6), IsoPacket(offset: 3, length: 5)]]
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
  func testASAPLeadAndUnderrun() {
    XCTAssertEqual(isoFirstFrame(current: 100, next: 0), 104)
    XCTAssertEqual(isoFirstFrame(current: 100, next: 110), 110)
    XCTAssertEqual(isoFirstFrame(current: 100, next: 102), 102)
    XCTAssertEqual(isoFirstFrame(current: 120, next: 110), 124)
  }
  func testUnorderedOverlappingDescriptorsIgnoreOddClientResultFields() throws {
    let packets = [IsoPacket(offset: 6, length: 4, actualLength: UInt32.max, status: -999),
      IsoPacket(offset: 4, length: 4, actualLength: 100, status: Int32.max)]
    XCTAssertEqual(IsoPacket.decode(IsoPacket.encode(packets), count: 2, bufferLength: 10), packets)
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
    var thrownStatuses = [IOReturn]()
    var attemptedFrames = [UInt64]()
    func enqueue(data: NSMutableData, list: IsoFrameList, firstFrame: UInt64,
      completion: @escaping (IOReturn) -> Void) throws {
      attemptedFrames.append(firstFrame)
      if !thrownStatuses.isEmpty {
        throw NSError(domain: "fake", code: Int(thrownStatuses.removeFirst()))
      }
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
    XCTAssertEqual(pipe.frames, [104, 106])
    XCTAssertEqual(pipe.lists[0].pointer[1].offset, 8)
    pipe.lists[0].pointer[0].status = kIOReturnSuccess
    pipe.lists[0].pointer[0].completeCount = 3
    pipe.completions[0](kIOReturnSuccess)
    XCTAssertEqual(frame, 104); XCTAssertEqual(result.map(\.actualLength), [3, 0])
    XCTAssertEqual(result.map(\.status), [0, -18])
    queue.reset()
    try queue.enqueue(data: NSMutableData(length: 12)!, packets: packets,
      startFrame: 110, requestedInterval: 0, asap: false) { _, _, _ in }
    XCTAssertEqual(pipe.frames.last, 104)
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
    XCTAssertEqual(pipe.frames, [104, 106])
    pipe.completions[0](kIOReturnSuccess); pipe.completions[1](kIOReturnSuccess)
    XCTAssertEqual(frames, [832, 848])
    pipe.fails = true
    XCTAssertThrowsError(try queue.enqueue(data: NSMutableData(length: 32)!, packets: packets,
      startFrame: 0, requestedInterval: 2, asap: true) { _, _, _ in })
    pipe.fails = false
    try queue.enqueue(data: NSMutableData(length: 32)!, packets: packets,
      startFrame: 0, requestedInterval: 2, asap: true) { _, _, _ in }
    XCTAssertEqual(pipe.frames.last, 108)
    queue.reset()
    try queue.enqueue(data: NSMutableData(length: 32)!, packets: packets,
      startFrame: 0, requestedInterval: 2, asap: true) { _, _, _ in }
    XCTAssertEqual(pipe.frames.last, 104)
  }
  func testNativeSchedulingRejectsPayloadBoundsAndDurationViolations() throws {
    let pipe = FakePipe()
    let queue = IsoPipeQueue(pipe: pipe, highSpeed: false, interval: 1,
      maximumPayload: 64, currentFrame: { 100 })
    for (packets, interval) in [([IsoPacket(offset: 0, length: 65)], UInt32(1)),
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

  func testMismatchedIntervalsAndForeignFramesChainByDescriptorAndReportUsedFrame() throws {
    let pipe = FakePipe()
    var logs = [String](), frames = [UInt32]()
    var current: UInt64 = 100
    let queue = IsoPipeQueue(pipe: pipe, highSpeed: false, interval: 4,
      maximumPayload: 64, log: { logs.append($0) }, currentFrame: { current })
    for requested: UInt32 in [110, UInt32.max, 0] {
      try queue.enqueue(data: NSMutableData(length: 8)!,
        packets: [IsoPacket(offset: 0, length: 4), IsoPacket(offset: 4, length: 4)],
        startFrame: requested, requestedInterval: 3, asap: false) { _, frame, _ in frames.append(frame) }
    }
    XCTAssertEqual(pipe.frames, [104, 112, 120])
    for callback in pipe.completions { callback(kIOReturnSuccess) }
    XCTAssertEqual(frames, [104, 112, 120])
    XCTAssertEqual(logs.count, 1)
    current = 200
    try queue.enqueue(data: NSMutableData(length: 4)!, packets: [IsoPacket(offset: 0, length: 4)],
      startFrame: 999, requestedInterval: 0, asap: false) { _, _, _ in }
    XCTAssertEqual(pipe.frames.last, 204)
  }
  func testTooOldRetriesExactlyOnceWithDoubleLeadThenFailsAndRateLimitsNativeLog() throws {
    let pipe = FakePipe()
    var current: UInt64 = 100
    var logs = [String](), results = [IOReturn](), frames = [UInt32]()
    let queue = IsoPipeQueue(pipe: pipe, highSpeed: false, interval: 1,
      maximumPayload: 64, log: { logs.append($0) }, currentFrame: { current })
    try queue.enqueue(data: NSMutableData(length: 4)!, packets: [IsoPacket(offset: 0, length: 4)],
      startFrame: 0, requestedInterval: 1, asap: true) { result, frame, packets in
      results.append(result); frames.append(frame)
      XCTAssertEqual(packets[0].status, -18)
    }
    current = 110
    pipe.completions[0](kIOReturnIsoTooOld)
    XCTAssertEqual(pipe.frames, [104, 118]); XCTAssertTrue(results.isEmpty)
    XCTAssertFalse(pipe.lists[0] === pipe.lists[1])
    pipe.completions[1](kIOReturnIsoTooOld)
    XCTAssertEqual(pipe.frames.count, 2); XCTAssertEqual(results, [kIOReturnIsoTooOld])
    XCTAssertEqual(frames, [118]); XCTAssertEqual(logs.count, 1)
    XCTAssertTrue(logs[0].contains(String(format: "0x%08x", UInt32(bitPattern: kIOReturnIsoTooOld))))
    XCTAssertEqual(isoPacketStatus(kIOReturnIsoTooNew), -18)
  }
  func testSynchronousTooOldEnqueueRetriesOnceAndReturnsUsedFrame() throws {
    let pipe = FakePipe()
    pipe.thrownStatuses = [kIOReturnIsoTooOld]
    let queue = IsoPipeQueue(pipe: pipe, highSpeed: true, interval: 8,
      maximumPayload: 64, currentFrame: { 100 })
    var frames = [UInt32]()
    try queue.enqueue(data: NSMutableData(length: 4)!, packets: [IsoPacket(offset: 0, length: 4)],
      startFrame: UInt32.max, requestedInterval: 4, asap: false) { result, frame, _ in
      XCTAssertEqual(result, kIOReturnSuccess); frames.append(frame)
    }
    XCTAssertEqual(pipe.attemptedFrames, [104, 108])
    pipe.completions[0](kIOReturnSuccess)
    XCTAssertEqual(frames, [864])
  }
  func testSynchronousTooOldRetryFailureThrowsAfterExactlyTwoAttempts() throws {
    let pipe = FakePipe()
    pipe.thrownStatuses = [kIOReturnIsoTooOld, kIOReturnIsoTooOld]
    let queue = IsoPipeQueue(pipe: pipe, highSpeed: false, interval: 1,
      maximumPayload: 64, currentFrame: { 100 })
    XCTAssertThrowsError(try queue.enqueue(data: NSMutableData(length: 4)!,
      packets: [IsoPacket(offset: 0, length: 4)], startFrame: 0, requestedInterval: 1,
      asap: true) { _, _, _ in XCTFail("A synchronous failure must throw") })
    XCTAssertEqual(pipe.attemptedFrames, [104, 108]); XCTAssertTrue(pipe.completions.isEmpty)
  }
  func testAsynchronousTooOldWithThrowingRetryCompletesOnceWithRetryFailure() throws {
    let pipe = FakePipe()
    let queue = IsoPipeQueue(pipe: pipe, highSpeed: false, interval: 1,
      maximumPayload: 64, currentFrame: { 100 })
    var results = [IOReturn](), frames = [UInt32]()
    try queue.enqueue(data: NSMutableData(length: 4)!, packets: [IsoPacket(offset: 0, length: 4)],
      startFrame: 0, requestedInterval: 1, asap: true) { result, frame, packets in
      results.append(result); frames.append(frame)
      XCTAssertEqual(packets[0].actualLength, 0); XCTAssertEqual(packets[0].status, -71)
    }
    pipe.thrownStatuses = [kIOReturnError]
    pipe.completions[0](kIOReturnIsoTooOld)
    XCTAssertEqual(pipe.attemptedFrames, [104, 108]); XCTAssertEqual(results, [kIOReturnError])
    XCTAssertEqual(frames, [108]); XCTAssertEqual(pipe.completions.count, 1)
  }
  func testTooOldRetryPreservesReservationsForOtherQueuedRequests() throws {
    let pipe = FakePipe()
    let queue = IsoPipeQueue(pipe: pipe, highSpeed: false, interval: 16,
      maximumPayload: 64, currentFrame: { 100 })
    for _ in 0..<2 {
      try queue.enqueue(data: NSMutableData(length: 4)!, packets: [IsoPacket(offset: 0, length: 4)],
        startFrame: 0, requestedInterval: 16, asap: true) { _, _, _ in }
    }
    pipe.completions[0](kIOReturnIsoTooOld)
    XCTAssertEqual(pipe.frames, [104, 120, 136])
  }
  func testTooNewAndResetTooOldDoNotRetry() throws {
    for status in [kIOReturnIsoTooNew, kIOReturnIsoTooOld] {
      let pipe = FakePipe()
      let queue = IsoPipeQueue(pipe: pipe, highSpeed: false, interval: 1,
        maximumPayload: 64, currentFrame: { 100 })
      var results = [IOReturn]()
      try queue.enqueue(data: NSMutableData(length: 4)!, packets: [IsoPacket(offset: 0, length: 4)],
        startFrame: 0, requestedInterval: 1, asap: true) { result, _, _ in results.append(result) }
      if status == kIOReturnIsoTooOld { queue.reset() }
      pipe.completions[0](status)
      XCTAssertEqual(pipe.frames.count, 1); XCTAssertEqual(results, [status])
    }
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
    XCTAssertEqual(pipe.frames, [104])
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
  func testAlternatePreflightRejectsOtherInterfaceEndpointWithoutTouchingMap() throws {
    let map = InterfacePipeMap<FakePipe>()
    var config = configuration()
    try map.replace(number: 0, alternate: 0, configuration: config, highSpeed: false,
      select: {}, open: { _ in FakePipe() })
    try map.replace(number: 1, alternate: 0, configuration: config, highSpeed: false,
      select: {}, open: { _ in FakePipe() })
    let old = map.pipes[0x81]
    config[45] = 0x81
    XCTAssertFalse(map.supportsAlternate(number: 1, alternate: 1, configuration: config, highSpeed: false))
    XCTAssertTrue(map.pipes[0x81] === old); XCTAssertEqual(map.alternates[1], 0)
  }
  func testFailedNativeSelectCanReselectOldAlternateAndReopenItsPipes() throws {
    let map = InterfacePipeMap<FakePipe>(), config = configuration()
    try map.replace(number: 1, alternate: 1, configuration: config, highSpeed: false,
      select: {}, open: { _ in FakePipe() })
    let old = map.pipes[0x82]
    XCTAssertThrowsError(try map.replace(number: 1, alternate: 0, configuration: config, highSpeed: false,
      select: { throw USBError.message("native select failed") }, open: { _ in FakePipe() }))
    try map.replace(number: 1, alternate: 1, configuration: config, highSpeed: false,
      select: {}, open: { _ in FakePipe() })
    XCTAssertFalse(map.pipes[0x82] === old)
    XCTAssertEqual(map.endpoints(1), [0x82, 2]); XCTAssertEqual(map.alternates[1], 1)
    let pipe = try XCTUnwrap(map.pipes[0x82])
    let queue = IsoPipeQueue(pipe: pipe, highSpeed: false, interval: 2,
      maximumPayload: 64, currentFrame: { 100 })
    try queue.enqueue(data: NSMutableData(length: 4)!, packets: [IsoPacket(offset: 0, length: 4)],
      startFrame: 0, requestedInterval: 2, asap: true) { _, _, _ in }
    XCTAssertEqual(pipe.frames, [104])
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
    queue!.reset() // Closing a generation must not release native DMA memory.
    pipe.lists.removeAll(); queue = nil
    XCTAssertNotNil(allocation)
    allocation?.data.mutableBytes.storeBytes(of: UInt8(0xab), as: UInt8.self)
    allocation?.pointer[0].completeCount = 0
    pipe.completions[0](kIOReturnAborted)
    XCTAssertTrue(completed)
    pipe.completions.removeAll()
    XCTAssertNil(allocation)
  }

}
