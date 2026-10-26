// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation
import IOKit
import IOUSBHost

// firstFrameNumber is always in milliseconds; Linux HS start_frame/interval
// use microframes. Foreign controller clocks and expired frames fall back to ASAP.
func isoFirstFrame(current: UInt64, requested: UInt32, asap: Bool, highSpeed: Bool) -> UInt64 {
  let frame = UInt64(requested) / (highSpeed ? 8 : 1)
  let earliest = current + 2
  return !asap && frame >= earliest && frame <= current + 1024
    && (!highSpeed || requested % 8 == 0) ? frame : earliest
}
func isoPacketStatus(_ result: IOReturn) -> Int32 {
  switch result {
  case kIOReturnSuccess, kIOReturnUnderrun: return 0
  case kIOReturnInvalid, IOReturn(bitPattern: 0xe000_400e), IOReturn(bitPattern: 0xe000_400f): return -18
  case kIOReturnOverrun: return -75
  default:
    let status = usbStatus(result)
    return status == -5 ? -71 : status
  }
}

// Own both native memory and the data until the completion handler has returned,
// including after UNLINK/alternate selection/teardown. Never pass an escaped Swift
// Array's temporary withUnsafeMutableBufferPointer to an asynchronous API.
final class IsoFrameList {
  let pointer: UnsafeMutablePointer<IOUSBHostIsochronousTransaction>
  let packets: [IsoPacket]
  let data: NSMutableData
  init(data: NSMutableData, packets: [IsoPacket]) {
    self.data = data
    self.packets = packets
    pointer = .allocate(capacity: packets.count)
    for (i, packet) in packets.enumerated() {
      var transaction = IOUSBHostIsochronousTransaction()
      transaction.status = kIOReturnInvalid
      transaction.requestCount = packet.length
      transaction.offset = packet.offset
      pointer.advanced(by: i).initialize(to: transaction)
    }
  }
  func results(overall: IOReturn) -> [IsoPacket] {
    packets.enumerated().map { i, packet in
      let frame = pointer[i]
      let result = frame.status == kIOReturnInvalid && overall != kIOReturnSuccess
        && overall != kIOReturnUnderrun ? overall : frame.status
      return IsoPacket(offset: packet.offset, length: packet.length,
        actualLength: min(frame.completeCount, packet.length), status: isoPacketStatus(result))
    }
  }
  deinit { pointer.deinitialize(count: packets.count); pointer.deallocate() }
}

// Locate by number AND alternate rather than assuming interfaceDescriptor points
// at the newly selected alternate on every macOS version. The original config
// descriptor, forwarded intact on endpoint zero, advertises all alternate modes.
func interfaceOffset(_ bytes: Data, number: UInt8, alternate: UInt8) -> Int? {
  guard bytes.count >= 9, bytes[0] >= 9 else { return nil }
  var i = Int(bytes[0])
  while i + 2 <= bytes.count {
    let length = Int(bytes[i])
    guard length >= 2, length <= bytes.count - i else { return nil }
    if bytes[i + 1] == 4 && length >= 9 && bytes[i + 2] == number && bytes[i + 3] == alternate { return i }
    i += length
  }
  return nil
}

protocol IsoRequestPipe: AnyObject {
  func enqueue(data: NSMutableData, list: IsoFrameList, firstFrame: UInt64,
    completion: @escaping (IOReturn) -> Void) throws
}
extension IOUSBHostPipe: IsoRequestPipe {
  func enqueue(data: NSMutableData, list: IsoFrameList, firstFrame: UInt64,
    completion: @escaping (IOReturn) -> Void) throws {
    try guarded {
      try enqueueIORequest(with: data, transactionList: list.pointer,
        transactionListCount: list.packets.count, firstFrameNumber: firstFrame, options: [],
        completionHandler: { [list] result, _ in
          // Capture the allocation even if the request has been unlinked.
          withExtendedLifetime(list) { completion(result) }
        })
    }
  }
}

// Shared by native pipes and fake pipes: tests exercise the actual frame selection,
// interval validation, native list construction, and packet completion mapping.
final class IsoPipeQueue {
  let pipe: IsoRequestPipe
  let highSpeed: Bool
  let interval: UInt32
  let maximumPayload: Int
  let currentFrame: () -> UInt64
  private var nextFrame: UInt64 = 0
  init(pipe: IsoRequestPipe, highSpeed: Bool, interval: UInt32, maximumPayload: Int,
    currentFrame: @escaping () -> UInt64) {
    self.pipe = pipe; self.highSpeed = highSpeed; self.interval = interval
    self.maximumPayload = maximumPayload; self.currentFrame = currentFrame
  }
  func reset() { nextFrame = 0 }
  func enqueue(data: NSMutableData, packets: [IsoPacket], startFrame: UInt32,
    requestedInterval: UInt32, asap: Bool,
    completion: @escaping (IOReturn, UInt32, [IsoPacket]) -> Void) throws {
    guard interval > 0, requestedInterval == 0 || requestedInterval == interval,
      !packets.isEmpty, packets.count <= IsoPacket.limit,
      packets.allSatisfy({ $0.length <= maximumPayload && $0.offset <= data.length
        && $0.length <= data.length - Int($0.offset) }) else {
      throw NSError(domain: "IOUSBHost", code: Int(kIOReturnBadArgument))
    }
    let serviceUnits = UInt64(packets.count) * UInt64(interval)
    // Native firstFrameNumber cannot express a fractional millisecond. Reject
    // these HS URBs rather than silently inserting gaps between frame lists.
    guard !highSpeed || serviceUnits % 8 == 0 else {
      throw NSError(domain: "IOUSBHost", code: Int(kIOReturnUnsupported))
    }
    let duration = serviceUnits / (highSpeed ? 8 : 1)
    let current = currentFrame()
    let frame = max(nextFrame, isoFirstFrame(current: current,
      requested: startFrame, asap: asap, highSpeed: highSpeed))
    let lastFrame = frame + UInt64(packets.count - 1) * UInt64(interval) / (highSpeed ? 8 : 1)
    guard frame <= current + 1024, lastFrame <= current + 1024 else {
      throw NSError(domain: "IOUSBHost", code: Int(kIOReturnBadArgument))
    }
    let wireFrame = UInt32(truncatingIfNeeded: frame * (highSpeed ? 8 : 1))
    let list = IsoFrameList(data: data, packets: packets)
    // EXPERIMENTAL: native transactions run at the descriptor's service interval.
    // HS frame lists must span whole milliseconds until sub-frame scheduling
    // can be validated. Non-ASAP clock translation also needs hardware validation.
    try pipe.enqueue(data: data, list: list, firstFrame: frame) { [list] result in
      completion(result, wireFrame, list.results(overall: result))
    }
    nextFrame = frame + duration
  }
}
