// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation
import IOKit
import IOUSBHost

// The made-up microphone as a Session device. There is no host controller, so a
// 1 ms timer is the USB frame clock Windows sees: each packet is filled from the
// MicBuffer as its frame passes, and the URB completes after its last frame.
final class VirtualMicTransport: SessionDevice {
  private final class PendingIso {
    let start: Int64, due: Int64
    let data: NSMutableData
    var packets: [IsoPacket]
    var filled = 0
    let completion: (IOReturn, UInt32, [IsoPacket]) -> Void
    init(start: Int64, due: Int64, data: NSMutableData, packets: [IsoPacket],
         completion: @escaping (IOReturn, UInt32, [IsoPacket]) -> Void) {
      self.start = start; self.due = due; self.data = data; self.packets = packets
      self.completion = completion
    }
  }
  private let buffer: MicBuffer
  private let serial: String
  private let clock: () -> Int64
  private let onStreaming: (Bool) -> Void
  private let lock = NSLock()
  private var alternate: UInt8 = 0
  private var nextFrame: Int64?
  private var queue = [PendingIso]()
  private var timer: DispatchSourceTimer?
  let location: UInt32 = 0

  init(buffer: MicBuffer, serial: String, clock: @escaping () -> Int64 = monotonicMS,
       startTimer: Bool = true, onStreaming: @escaping (Bool) -> Void) {
    self.buffer = buffer
    self.serial = serial
    self.clock = clock
    self.onStreaming = onStreaming
    if startTimer {
      let source = DispatchSource.makeTimerSource(
        queue: DispatchQueue(label: "org.sapd.longcable.virtual-mic", qos: .userInteractive))
      source.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(200))
      source.setEventHandler { [weak self] in self?.tick() }
      timer = source
      source.resume()
    }
  }
  deinit { timer?.cancel() }

  func tick() {
    let now = clock()
    let done: [PendingIso] = lock.withLock {
      // URBs are back to back on the timeline, so frames pass in queue order.
      for urb in queue {
        while urb.filled < urb.packets.count && urb.start + Int64(urb.filled) + 1 <= now {
          let packet = urb.packets[urb.filled]
          let bytes = buffer.readPacket(into: urb.data.mutableBytes.advanced(by: Int(packet.offset)),
            capacityBytes: Int(packet.length))
          urb.packets[urb.filled] = IsoPacket(offset: packet.offset, length: packet.length,
            actualLength: UInt32(bytes), status: 0)
          urb.filled += 1
        }
        if urb.filled < urb.packets.count { break }
      }
      let count = queue.prefix { $0.filled == $0.packets.count }.count
      defer { queue.removeFirst(count) }
      return Array(queue.prefix(count))
    }
    for urb in done {
      urb.completion(kIOReturnSuccess, UInt32(truncatingIfNeeded: urb.start), urb.packets)
    }
  }

  private func cancelQueued() {
    let cancelled: [PendingIso] = lock.withLock {
      defer { queue.removeAll(); nextFrame = nil }
      return queue
    }
    for urb in cancelled { urb.completion(kIOReturnAborted, UInt32(truncatingIfNeeded: urb.start), urb.packets) }
  }

  // MARK: USBTransferTransport

  func endpointType(_ address: UInt8) -> UInt8? {
    address == VirtualMic.streamingEndpoint && lock.withLock({ alternate }) == 1 ? 1 : nil
  }
  func maximumPacketSize(_ address: UInt8) -> Int? {
    address == VirtualMic.streamingEndpoint ? VirtualMic.maxPacketBytes : nil
  }

  func enqueueControl(_ request: IOUSBDeviceRequest, data: NSMutableData,
    completion: @escaping (IOReturn, Int) -> Void) throws {
    func reply(_ bytes: Data) {
      let count = min(bytes.count, Int(request.wLength), data.length)
      bytes.copyBytes(to: data.mutableBytes.assumingMemoryBound(to: UInt8.self), count: count)
      completion(kIOReturnSuccess, count)
    }
    let rate = Data([0x80, 0xBB, 0x00])
    switch (request.bmRequestType, request.bRequest) {
    case (0x80, 6):
      let index = UInt8(request.wValue & 0xff)
      switch request.wValue >> 8 {
      case 1 where index == 0: reply(VirtualMic.deviceDescriptor)
      case 2 where index == 0: reply(VirtualMic.configurationDescriptor)
      case 3:
        if let string = VirtualMic.stringDescriptor(index, serial: serial) { reply(string) }
        else { completion(pipeStalled, 0) }
      default: completion(pipeStalled, 0)
      }
    case (0x80, 0), (0x81, 0), (0x82, 0):
      reply(Data([0, 0]))
    case (0x22, 0x01) where request.wValue == 0x0100 && request.wIndex == UInt16(VirtualMic.streamingEndpoint)
      && request.wLength == 3 && data.length >= 3:
      completion(Data(bytes: data.bytes, count: 3) == rate ? kIOReturnSuccess : pipeStalled, 0)
    case (0xA2, 0x81...0x83)
      where request.wValue == 0x0100 && request.wIndex == UInt16(VirtualMic.streamingEndpoint):
      reply(rate)
    default:
      completion(pipeStalled, 0)
    }
  }

  func enqueueIO(_ address: UInt8, data: NSMutableData?, timeout: TimeInterval,
    completion: @escaping (IOReturn, Int) -> Void) throws {
    throw USBError.message("The virtual microphone has no bulk or interrupt endpoints")
  }

  func enqueueIso(_ address: UInt8, data: NSMutableData, packets: [IsoPacket],
    startFrame: UInt32, interval: UInt32, asap: Bool,
    completion: @escaping (IOReturn, UInt32, [IsoPacket]) -> Void) throws {
    guard endpointType(address) == 1 else { throw USBError.message("Endpoint not streaming") }
    lock.withLock {
      let now = clock()
      // Start, or resync after a stall longer than the buffer can cover.
      if nextFrame.map({ $0 + 100 < now }) ?? true { nextFrame = now + 1 }
      let start = nextFrame!
      let due = start + Int64(packets.count)
      nextFrame = due
      queue.append(PendingIso(start: start, due: due, data: data, packets: packets, completion: completion))
    }
  }

  func abort(_ address: UInt8) throws { cancelQueued() }
  func clearHalt(_ address: UInt8) throws { cancelQueued() }

  func reconfigure(_ configuration: UInt8) throws {
    guard configuration == 1 else { throw USBError.message("Unknown configuration \(configuration)") }
    _ = try selectInterface(1, alternate: 0)
  }

  func selectInterface(_ number: UInt8, alternate value: UInt8) throws -> Bool {
    guard supportsAlternate(number, alternate: value) else { return false }
    guard number == 1 else { return true }
    let previous = lock.withLock { () -> UInt8 in
      defer { alternate = value }
      return alternate
    }
    if value == 1 {
      buffer.reset()
      if previous != 1 { onStreaming(true) }
    } else {
      cancelQueued()
      if previous == 1 { onStreaming(false) }
    }
    return true
  }
  func currentAlternate(_ number: UInt8) -> UInt8? {
    number == 0 ? 0 : number == 1 ? lock.withLock { alternate } : nil
  }
  func supportsAlternate(_ number: UInt8, alternate: UInt8) -> Bool {
    (number == 0 && alternate == 0) || (number == 1 && alternate <= 1)
  }
  func endpointsForInterface(_ number: UInt8) -> Set<UInt8>? {
    number == 0 ? [] : number == 1 ? [VirtualMic.streamingEndpoint] : nil
  }

  // MARK: SessionDevice

  func release() {
    timer?.cancel()
    timer = nil
    _ = try? selectInterface(1, alternate: 0)
  }
}
