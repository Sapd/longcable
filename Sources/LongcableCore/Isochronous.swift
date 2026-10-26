// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation
import IOKit
import IOUSBHost

// IOUSBHost firstFrameNumber is in milliseconds, in this host's clock.
let isoASAPLead: UInt64 = 4
func isoFirstFrame(current: UInt64, next: UInt64) -> UInt64 {
  next > current ? next : current + isoASAPLead
}
func isoPacketStatus(_ result: IOReturn) -> Int32 {
  switch result {
  case kIOReturnSuccess, kIOReturnUnderrun: return 0
  case kIOReturnInvalid, kIOReturnIsoTooOld, kIOReturnIsoTooNew: return -18
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
// descriptor intervals, native list construction, and packet completion mapping.
final class IsoPipeQueue {
  let pipe: IsoRequestPipe
  let highSpeed: Bool
  let interval: UInt32
  let maximumPayload: Int
  let currentFrame: () -> UInt64
  private var nextFrame: UInt64 = 0
  private var generation: UInt64 = 0
  // Native callbacks may arrive on a different queue, or inline in enqueue.
  private let lock = NSRecursiveLock()
  private var loggedIntervalMismatch = false
  private var lastFailureLog: Int64?
  private let endpointAddress: UInt8
  private let log: (String) -> Void
  init(pipe: IsoRequestPipe, highSpeed: Bool, interval: UInt32, maximumPayload: Int, endpointAddress: UInt8 = 0,
    log: @escaping (String) -> Void = { EventLog.shared.write($0) },
    currentFrame: @escaping () -> UInt64) {
    self.pipe = pipe; self.highSpeed = highSpeed; self.interval = interval
    self.maximumPayload = maximumPayload; self.currentFrame = currentFrame
    self.endpointAddress = endpointAddress; self.log = log
  }
  func reset() {
    lock.lock(); defer { lock.unlock() }
    nextFrame = 0; generation &+= 1
  }
  private func logFailure(_ result: IOReturn) {
    guard result != kIOReturnSuccess && result != kIOReturnUnderrun else { return }
    let now = monotonicMS()
    guard lastFailureLog == nil || now - lastFailureLog! >= 1000 else { return }
    lastFailureLog = now
    log(String(format: "Iso endpoint 0x%02x native status 0x%08x", endpointAddress, UInt32(bitPattern: result)))
  }
  func enqueue(data: NSMutableData, packets: [IsoPacket], startFrame: UInt32,
    requestedInterval: UInt32, asap: Bool,
    completion: @escaping (IOReturn, UInt32, [IsoPacket]) -> Void) throws {
    lock.lock(); defer { lock.unlock() }
    if requestedInterval != 0 && requestedInterval != interval && !loggedIntervalMismatch {
      loggedIntervalMismatch = true
      log("Iso endpoint \(String(format: "0x%02x", endpointAddress)) ignoring client interval \(requestedInterval); descriptor interval \(interval)")
    }
    guard interval > 0,
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
    // Client start_frame and ASAP flags refer to a foreign controller clock.
    // Every request chains on our native queue, including non-ASAP submits.
    let frame = isoFirstFrame(current: currentFrame(), next: nextFrame)
    try submit(data: data, packets: packets, frame: frame, duration: duration,
      generation: generation, retry: true, completion: completion)
  }
  private func submit(data: NSMutableData, packets: [IsoPacket], frame: UInt64,
    duration: UInt64, generation: UInt64, retry: Bool,
    completion: @escaping (IOReturn, UInt32, [IsoPacket]) -> Void) throws {
    let lastFrame = frame + UInt64(packets.count - 1) * UInt64(interval) / (highSpeed ? 8 : 1)
    guard lastFrame <= currentFrame() + 1024 else {
      throw NSError(domain: "IOUSBHost", code: Int(kIOReturnBadArgument))
    }
    let wireFrame = UInt32(truncatingIfNeeded: frame * (highSpeed ? 8 : 1))
    let list = IsoFrameList(data: data, packets: packets)
    let previousNext = nextFrame
    let reservedNext = max(nextFrame, frame + duration)
    nextFrame = reservedNext
    do {
      try pipe.enqueue(data: data, list: list, firstFrame: frame) { [weak self, list] result in
        if let self {
          self.lock.lock(); defer { self.lock.unlock() }
          self.logFailure(result)
          if result == kIOReturnIsoTooOld && retry && self.generation == generation {
            let retryFrame = max(self.nextFrame, self.currentFrame() + 2 * isoASAPLead)
            do {
              try self.submit(data: data, packets: packets, frame: retryFrame,
                duration: duration, generation: generation, retry: false, completion: completion)
            } catch {
              let status = IOReturn(truncatingIfNeeded: (error as NSError).code)
              self.logFailure(status)
              let failed = IsoFrameList(data: data, packets: packets)
              completion(status, UInt32(truncatingIfNeeded: retryFrame * (self.highSpeed ? 8 : 1)),
                failed.results(overall: status))
            }
            return
          }
        }
        completion(result, wireFrame, list.results(overall: result))
      }
    } catch {
      if self.generation == generation && nextFrame == reservedNext { nextFrame = previousNext }
      let status = IOReturn(truncatingIfNeeded: (error as NSError).code)
      logFailure(status)
      if status == kIOReturnIsoTooOld && retry && self.generation == generation {
        try submit(data: data, packets: packets, frame: max(nextFrame, currentFrame() + 2 * isoASAPLead),
          duration: duration, generation: generation, retry: false, completion: completion)
      } else { throw error }
    }
  }
}
