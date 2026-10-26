// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import Foundation
import IOKit
import IOUSBHost

let pipeStalled = IOReturn(bitPattern: 0xe000_404f)

// Native operations are issued on Session's serial queue. Completion handlers may
// arrive on any queue, including synchronously inside enqueue/abort in a transport.
protocol USBTransferTransport: AnyObject {
  func endpointType(_ address: UInt8) -> UInt8?
  func maximumPacketSize(_ address: UInt8) -> Int?
  func enqueueControl(_ request: IOUSBDeviceRequest, data: NSMutableData,
    completion: @escaping (IOReturn, Int) -> Void) throws
  func enqueueIO(_ address: UInt8, data: NSMutableData?, timeout: TimeInterval,
    completion: @escaping (IOReturn, Int) -> Void) throws
  func abort(_ address: UInt8) throws
  func clearHalt(_ address: UInt8) throws
  func reconfigure(_ configuration: UInt8) throws
  func selectInterface(_ number: UInt8) throws -> Bool
  func endpointsForInterface(_ number: UInt8) -> Set<UInt8>?
}

final class Transfer {
  let seq: UInt32, direction: UInt32, endpoint: UInt32
  let data: NSMutableData
  var deviceDescriptor = false
  var flags: UInt32 = 0
  var request: IOUSBDeviceRequest?
  var zeroPacketPhase = false
  var payloadBytes = 0
  var resetAborted = false
  var address: UInt8 { endpoint == 0 ? 0 : UInt8(endpoint | (direction == 1 ? 0x80 : 0)) }
  var expectedLength: Int { request.map { Int($0.wLength) } ?? data.length }
  init(seq: UInt32, direction: UInt32, endpoint: UInt32, length: Int) {
    self.seq = seq
    self.direction = direction
    self.endpoint = endpoint
    data = NSMutableData(length: length)!
  }
}
final class Session {
  let target: Target, connection: Connection
  let usb = CapturedDevice()
  let transport: USBTransferTransport
  private let operations = DispatchQueue(label: "org.sapd.longcable.session.operations")
  private let operationKey = DispatchSpecificKey<Bool>()
  // pending tracks requests still owed a wire reply. active also retains cancelled
  // native requests, so UNLINK cannot release their count/buffer admission budget.
  var pending = [UInt32: Transfer]()
  private var active = [UInt8: Transfer]()
  private var queued = [UInt8: [Transfer]]()
  var closed = false
  private var transportBroken = false
  init(_ target: Target, _ connection: Connection, transport: USBTransferTransport? = nil) {
    self.target = target
    self.connection = connection
    self.transport = transport ?? usb
    operations.setSpecific(key: operationKey, value: true)
  }
  @discardableResult private func serialized<T>(_ operation: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: operationKey) == true { return try operation() }
    return try operations.sync(execute: operation)
  }
  // A queue fence also makes fake native callbacks deterministic in regression tests.
  func synchronize() { serialized {} }
  private var retainedJobs: [Transfer] {
    Array(pending.values) + active.values.filter { pending[$0.seq] !== $0 }
  }
  var outstandingCount: Int { serialized { retainedJobs.count } }
  var outstandingBytes: Int { serialized { retainedJobs.reduce(0) { $0 + $1.data.length } } }

  func complete(_ job: Transfer, result: IOReturn, bytes: Int) {
    serialized { finish(job, result: result, bytes: bytes) }
  }
  private func finish(_ job: Transfer, result: IOReturn, bytes: Int, statusOverride: Int32? = nil) {
    if active[job.address] === job { active.removeValue(forKey: job.address) }
    defer { startNext(job.address) }
    guard !closed, pending[job.seq] === job else { return }
    pending.removeValue(forKey: job.seq)
    let count = min(max(0, bytes), job.data.length)
    if (result == kIOReturnSuccess || (result == kIOReturnUnderrun && count < job.expectedLength))
      && job.deviceDescriptor
      && target.identity?.overlaySerial == true && count >= 17 {
      job.data.mutableBytes.storeBytes(of: UInt8(254), toByteOffset: 16, as: UInt8.self)
    }
    let shortTransfer = job.direction == 1 && count < job.expectedLength
      && (result == kIOReturnSuccess || result == kIOReturnUnderrun)
    let status = statusOverride ?? (shortTransfer ? (job.flags & 1 != 0 ? -121 : 0) : usbStatus(result))
    var header = Data(count: 48)
    header.put32(0, 3)
    header.put32(4, job.seq)
    header.put32(8, target.wireID)
    header.put32(12, job.direction)
    header.put32(16, job.endpoint)
    header.put32(20, UInt32(bitPattern: status))
    header.put32(24, UInt32(count))
    var ok = connection.write(header)
    if ok && job.direction == 1 && count > 0 {
      ok = connection.write(Data(bytes: job.data.bytes, count: count))
    }
    target.transfer(count, status: status, pending: pending.count, native: result)
    if !ok || result == kIOReturnNoDevice || result == kIOReturnNotAttached {
      transportBroken = true
      connection.interrupt()
    }
  }
  private func callback(_ job: Transfer) -> (IOReturn, Int) -> Void {
    { [weak self, job] result, bytes in
      // Never begin the next request from a native abort's completion routine:
      // the pipe-wide abort must have returned before a queued request is issued.
      self?.operations.async { [weak self, job] in
        self?.nativeCompleted(job, result: result, bytes: bytes)
      }
    }
  }
  private func nativeCompleted(_ job: Transfer, result: IOReturn, bytes: Int) {
    guard active[job.address] === job else { return }
    // A successful callback can have been posted before a reset but processed
    // afterwards. It must never append a ZLP to the replacement pipe generation.
    if job.resetAborted {
      finish(job, result: kIOReturnAborted, bytes: job.zeroPacketPhase ? job.payloadBytes : bytes)
      return
    }
    if !closed, pending[job.seq] === job, !job.zeroPacketPhase,
      result == kIOReturnSuccess, job.flags & 0x40 != 0,
      bytes == job.data.length, bytes > 0,
      let packet = transport.maximumPacketSize(job.address), packet > 0,
      bytes % packet == 0 {
      job.zeroPacketPhase = true
      job.payloadBytes = bytes
      do {
        try transport.enqueueIO(job.address, data: nil, timeout: 0, completion: callback(job))
      } catch { finish(job, result: nativeError(error), bytes: bytes) }
      return
    }
    finish(job, result: result, bytes: job.zeroPacketPhase ? job.payloadBytes : bytes)
  }
  private func nativeError(_ error: Error) -> IOReturn {
    let code = IOReturn(truncatingIfNeeded: (error as NSError).code)
    return code == kIOReturnSuccess ? kIOReturnError : code
  }
  private func invalidateEndpoints(_ addresses: Set<UInt8>) {
    var discarded = [Transfer]()
    for address in addresses {
      active[address]?.resetAborted = true
      discarded += queued.removeValue(forKey: address) ?? []
    }
    // Remove every affected queue before finishing any item; finish() may start
    // a successor, and pre-reset OUT work must never reach freshly reset pipes.
    for job in discarded { finish(job, result: kIOReturnAborted, bytes: 0) }
  }
  func submit(_ h: Data) throws -> Bool {
    let seq = h.u32(4), direction = h.u32(12), ep = h.u32(16), length = h.u32(24)
    let packets = h.u32(32)
    guard h.u32(8) == target.wireID, direction <= 1, ep <= 15, length <= 1_048_576,
      packets == 0 || packets == UInt32.max else { return false }
    let job = Transfer(seq: seq, direction: direction, endpoint: ep, length: Int(length))
    job.flags = h.u32(20)
    if ep == 0 {
      let setup = Data(h[40..<48])
      var request = IOUSBDeviceRequest()
      request.bmRequestType = setup[0]
      request.bRequest = setup[1]
      request.wValue = setup.u16LE(2)
      request.wIndex = setup.u16LE(4)
      request.wLength = setup.u16LE(6)
      guard request.wLength <= length,
        ((request.bmRequestType & 0x80) == 0 ? 0 : 1) == direction else { return false }
      job.request = request
      job.deviceDescriptor = setup[0] == 0x80 && setup[1] == 6 && request.wValue == 0x0100
    }
    if direction == 0 && length > 0 {
      guard let body = connection.read(Int(length)) else { return false }
      body.copyBytes(to: job.data.mutableBytes.assumingMemoryBound(to: UInt8.self), count: body.count)
    }
    return serialized {
      let retained = retainedJobs
      guard !closed, !transportBroken, retained.count < 64, pending[seq] == nil,
        retained.reduce(0, { $0 + $1.data.length }) + Int(length) <= 8_388_608 else { return false }
      pending[seq] = job
      queued[job.address, default: []].append(job)
      target.queued(pending.count)
      startNext(job.address)
      return true
    }
  }
  private func startNext(_ address: UInt8) {
    guard !closed, !transportBroken, active[address] == nil,
      var jobs = queued[address], !jobs.isEmpty else { return }
    let job = jobs.removeFirst()
    queued[address] = jobs
    guard pending[job.seq] === job else { startNext(address); return }
    active[address] = job
    // DMA allocation, buffer ownership and callback scheduling flags are host-local
    // metadata. ISO_ASAP and unknown transfer semantics are explicitly unsupported.
    let supportedFlags: UInt32 = 0x1 | 0x4 | 0x40 | 0x80 | 0x100 | 0x200
    guard job.flags & ~supportedFlags == 0,
      job.flags & 0x40 == 0 || (job.endpoint != 0 && job.direction == 0
        && transport.endpointType(address) == 2 && (transport.maximumPacketSize(address) ?? 0) > 0)
    else { finish(job, result: kIOReturnUnsupported, bytes: 0, statusOverride: -95); return }
    do {
      if let request = job.request {
        if target.identity?.overlaySerial == true && request.bmRequestType == 0x80
          && request.bRequest == 6 && request.wValue == 0x03fe {
          let descriptor = serialDescriptor(target.config.label)
          let count = min(descriptor.count, Int(request.wLength))
          descriptor.copyBytes(to: job.data.mutableBytes.assumingMemoryBound(to: UInt8.self), count: count)
          finish(job, result: kIOReturnSuccess, bytes: count)
        } else if request.bmRequestType == 0 && request.bRequest == 5 {
          finish(job, result: request.wValue <= 127 && request.wIndex == 0 && request.wLength == 0
            ? kIOReturnSuccess : pipeStalled, bytes: 0)
        } else if request.bmRequestType == 0 && request.bRequest == 9 {
          guard request.wValue == UInt16(target.identity?.configuration ?? 0),
            request.wIndex == 0, request.wLength == 0 else {
            finish(job, result: pipeStalled, bytes: 0); return
          }
          do {
            invalidateEndpoints(Set(active.keys).union(queued.keys).subtracting([0]))
            try transport.reconfigure(UInt8(request.wValue))
            finish(job, result: kIOReturnSuccess, bytes: 0)
          } catch {
            transportBroken = true
            finish(job, result: nativeError(error), bytes: 0)
            connection.interrupt()
          }
        } else if request.bmRequestType == 1 && request.bRequest == 11 {
          guard request.wValue == 0, request.wIndex <= 255, request.wLength == 0 else {
            finish(job, result: pipeStalled, bytes: 0); return
          }
          guard let endpoints = transport.endpointsForInterface(UInt8(request.wIndex)) else {
            finish(job, result: pipeStalled, bytes: 0); return
          }
          do {
            invalidateEndpoints(endpoints)
            let selected = try transport.selectInterface(UInt8(request.wIndex))
            finish(job, result: selected ? kIOReturnSuccess : pipeStalled, bytes: 0)
          } catch {
            transportBroken = true
            finish(job, result: nativeError(error), bytes: 0)
            connection.interrupt()
          }
        } else if request.bmRequestType == 2 && request.bRequest == 1
          && request.wValue == 0 && request.wLength == 0 {
          guard request.wIndex <= 255, transport.endpointType(UInt8(request.wIndex)) != nil else {
            finish(job, result: pipeStalled, bytes: 0); return
          }
          invalidateEndpoints([UInt8(request.wIndex)])
          try transport.clearHalt(UInt8(request.wIndex))
          finish(job, result: kIOReturnSuccess, bytes: 0)
        } else {
          try transport.enqueueControl(request, data: job.data, completion: callback(job))
        }
      } else {
        guard transport.endpointType(address) != nil else {
          finish(job, result: pipeStalled, bytes: 0); return
        }
        // Bulk reads may wait indefinitely for legitimate device data, like interrupts.
        try transport.enqueueIO(address, data: job.data.length == 0 ? nil : job.data,
          timeout: 0, completion: callback(job))
      }
    } catch { finish(job, result: nativeError(error), bytes: 0) }
  }
  func unlink(_ h: Data) {
    guard h.u32(8) == target.wireID else { connection.interrupt(); return }
    serialized {
      let job = pending.removeValue(forKey: h.u32(20))
      var reply = Data(count: 48)
      reply.put32(0, 4)
      reply.put32(4, h.u32(4))
      reply.put32(8, target.wireID)
      reply.put32(20, job == nil ? 0 : UInt32(bitPattern: -104))
      if !connection.write(reply) { connection.interrupt() }
      target.queued(pending.count)
      guard let job else { return }
      if active[job.address] === job {
        do { try transport.abort(job.address) }
        catch { transportBroken = true; connection.interrupt() }
      } else {
        queued[job.address]?.removeAll { $0 === job }
      }
    }
  }
  func shutdownTransfers() {
    serialized {
      closed = true
      pending.removeAll()
      queued.removeAll()
      usb.release()
      // Native completion closures retain their buffers through teardown.
      active.removeAll()
    }
  }
  func run() {
    usb.disconnected = { [weak self] in self?.connection.interrupt() }
    defer {
      shutdownTransfers()
      target.ended()
      EventLog.shared.write("Released \(target.busID)")
    }
    do {
      let identity = target.identity!
      try usb.open(target.config, configuration: identity.configuration,
        expectedRegistryID: identity.registryID == 0 ? nil : identity.registryID)
      guard connection.operation(3, 0), connection.write(identity.record) else { return }
      target.attached(usb.location)
      EventLog.shared.write("Imported \(target.busID) physical port \(String(format:"%08x",usb.location))")
      while let h = connection.read(48, idle: true) {
        if h.u32(0) == 1 { if try !submit(h) { break } }
        else if h.u32(0) == 2 { unlink(h) }
        else { break }
      }
    } catch {
      target.failed(error)
      EventLog.shared.write("\(target.busID): \(error)")
      _ = connection.operation(3, 1)
    }
  }
}
func serialDescriptor(_ serial: String) -> Data {
  let text = serial.data(using: .utf16LittleEndian)!
  var data = Data([UInt8(text.count + 2), 3])
  data.append(text)
  return data
}
