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
  func selectInterface(_ number: UInt8, alternate: UInt8) throws -> Bool
  func currentAlternate(_ number: UInt8) -> UInt8?
  func supportsAlternate(_ number: UInt8, alternate: UInt8) -> Bool
  func enqueueIso(_ address: UInt8, data: NSMutableData, packets: [IsoPacket],
    startFrame: UInt32, interval: UInt32, asap: Bool,
    completion: @escaping (IOReturn, UInt32, [IsoPacket]) -> Void) throws
  func endpointsForInterface(_ number: UInt8) -> Set<UInt8>?
}

final class Transfer {
  let seq: UInt32, direction: UInt32, endpoint: UInt32
  let data: NSMutableData
  var isoPackets = [IsoPacket]()
  var startFrame: UInt32 = 0
  var interval: UInt32 = 0
  var isoCompleted = false
  var deviceDescriptor = false
  var flags: UInt32 = 0
  var request: IOUSBDeviceRequest?
  var zeroPacketPhase = false
  var payloadBytes = 0
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
  // pending tracks requests still owed a wire reply. active retains unlinked
  // native requests until completion, but never work from a closed generation.
  var pending = [UInt32: Transfer]()
  private var active = [UInt8: [Transfer]]()
  private var queued = [UInt8: [Transfer]]()
  var closed = false
  private var transportBroken = false
  private struct IsoProgress {
    var generation: UInt64 = 0
    var lastCompletion: Int64 = 0
    var logged = false
  }
  private var isoProgress = [UInt8: IsoProgress]()
  private var isoWatchdog: DispatchSourceTimer?
  private let now: () -> Int64
  private let log: (String) -> Void
  init(_ target: Target, _ connection: Connection, transport: USBTransferTransport? = nil,
    now: @escaping () -> Int64 = monotonicMS,
    log: @escaping (String) -> Void = { EventLog.shared.write($0) }) {
    self.now = now; self.log = log
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
    Array(pending.values) + active.values.flatMap { $0 }.filter { pending[$0.seq] !== $0 }
  }
  var outstandingCount: Int { serialized { retainedJobs.count } }
  var outstandingBytes: Int { serialized { retainedJobs.reduce(0) { $0 + $1.data.length } } }

  func complete(_ job: Transfer, result: IOReturn, bytes: Int) {
    serialized { finish(job, result: result, bytes: bytes) }
  }
  private func finish(_ job: Transfer, result: IOReturn, bytes: Int, statusOverride: Int32? = nil) {
    active[job.address]?.removeAll { $0 === job }
    if active[job.address]?.isEmpty == true { active.removeValue(forKey: job.address) }
    defer { startNext(job.address) }
    guard !closed, pending[job.seq] === job else { return }
    pending.removeValue(forKey: job.seq)
    if !job.isoPackets.isEmpty && !job.isoCompleted {
      let status = statusOverride ?? usbStatus(result)
      job.isoPackets = job.isoPackets.map {
        IsoPacket(offset: $0.offset, length: $0.length, status: status == 0 ? -18 : status)
      }
    }
    let count = job.isoPackets.isEmpty ? min(max(0, bytes), job.data.length)
      : job.isoPackets.reduce(0) { $0 + Int($1.actualLength) }
    if (result == kIOReturnSuccess || (result == kIOReturnUnderrun && count < job.expectedLength))
      && job.deviceDescriptor
      && target.identity?.overlaySerial == true && count >= 17 {
      job.data.mutableBytes.storeBytes(of: UInt8(254), toByteOffset: 16, as: UInt8.self)
    }
    let shortTransfer = job.isoPackets.isEmpty && job.direction == 1 && count < job.expectedLength
      && (result == kIOReturnSuccess || result == kIOReturnUnderrun)
    let status = statusOverride ?? (shortTransfer ? (job.flags & 1 != 0 ? -121 : 0)
      : (!job.isoPackets.isEmpty && result == kIOReturnUnderrun ? 0 : usbStatus(result)))
    var header = Data(count: 48)
    header.put32(0, 3)
    header.put32(4, job.seq)
    header.put32(8, target.wireID)
    header.put32(12, job.direction)
    header.put32(16, job.endpoint)
    header.put32(20, UInt32(bitPattern: status))
    header.put32(24, UInt32(count))
    if !job.isoPackets.isEmpty {
      header.put32(28, job.startFrame)
      header.put32(32, UInt32(job.isoPackets.count))
      header.put32(36, UInt32(job.isoPackets.filter { $0.status != 0 }.count))
    }
    var ok = connection.write(header)
    if ok && job.direction == 1 && count > 0 {
      if job.isoPackets.isEmpty {
        ok = connection.write(Data(bytes: job.data.bytes, count: count))
      } else {
        var packed = Data()
        for p in job.isoPackets where p.actualLength > 0 {
          packed.append(Data(bytes: job.data.bytes.advanced(by: Int(p.offset)), count: Int(p.actualLength)))
        }
        ok = connection.write(packed)
      }
    }
    if ok && !job.isoPackets.isEmpty { ok = connection.write(IsoPacket.encode(job.isoPackets)) }
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
    guard active[job.address]?.contains(where: { $0 === job }) == true else { return }
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
      // Detach the entire old generation before finish() can refill a pipe.
      // Native closures retain each job (and iso frame list) independently;
      // they may arrive late or never, but cannot gate the replacement pipe.
      if var progress = isoProgress[address] {
        progress.generation &+= 1
        progress.lastCompletion = now(); progress.logged = false
        isoProgress[address] = progress
      }
      discarded += active.removeValue(forKey: address) ?? []
      discarded += queued.removeValue(forKey: address) ?? []
    }
    for job in discarded { finish(job, result: kIOReturnAborted, bytes: 0) }
  }

  func submit(_ h: Data) throws -> Bool {
    guard h.count == 48 else { return false }
    let seq = h.u32(4), direction = h.u32(12), ep = h.u32(16), length = h.u32(24)
    let packets = h.u32(32)
    guard h.u32(8) == target.wireID, direction <= 1, ep <= 15, length <= 1_048_576,
      (packets <= IsoPacket.limit || packets == UInt32.max),
      ep != 0 || packets == 0 || packets == UInt32.max else { return false }
    let job = Transfer(seq: seq, direction: direction, endpoint: ep, length: Int(length))
    job.flags = h.u32(20)
    job.startFrame = h.u32(28)
    job.interval = h.u32(36)
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
    if packets > 0 && packets != UInt32.max {
      guard let descriptors = connection.read(Int(packets) * 16),
        let decoded = IsoPacket.decode(descriptors, count: Int(packets), bufferLength: Int(length))
      else { return false }
      job.isoPackets = decoded.map { IsoPacket(offset: $0.offset, length: $0.length) }
    }
    return serialized {
      let retained = retainedJobs
      guard !closed, !transportBroken, retained.count < 64, pending[seq] == nil,
        retained.reduce(0, { $0 + $1.data.length }) + Int(length) <= 8_388_608 else { return false }
      if !job.isoPackets.isEmpty {
        if !pending.values.contains(where: { $0.address == job.address && !$0.isoPackets.isEmpty }) {
          var progress = isoProgress[job.address] ?? IsoProgress()
          progress.lastCompletion = now(); progress.logged = false
          isoProgress[job.address] = progress
        }
        startIsoWatchdog()
      }
      pending[seq] = job
      queued[job.address, default: []].append(job)
      target.queued(pending.count)
      startNext(job.address)
      return true
    }
  }
  private func startNext(_ address: UInt8) {
    guard !closed, !transportBroken,
      var jobs = queued[address], let first = jobs.first else { return }
    let running = active[address] ?? []
    // Iso streams need multiple URBs on the controller to avoid a TCP round-trip
    // between consecutive frame lists. Bulk/control/interrupt stay serialized.
    guard running.isEmpty || (!first.isoPackets.isEmpty && running.count < 8
      && running.allSatisfy { !$0.isoPackets.isEmpty }) else { return }
    let job = jobs.removeFirst()
    queued[address] = jobs
    guard pending[job.seq] === job else { startNext(address); return }
    active[address, default: []].append(job)
    // DMA allocation, buffer ownership and callback scheduling flags are host-local
    // metadata. ISO_ASAP is meaningful only for an isochronous pipe.
    let supportedFlags: UInt32 = 0x1 | 0x2 | 0x4 | 0x40 | 0x80 | 0x100 | 0x200
    let isIso = !job.isoPackets.isEmpty
    guard job.flags & ~supportedFlags == 0,
      job.flags & 2 == 0 || isIso,
      isIso == (transport.endpointType(address) == 1),
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
          guard request.wValue <= 255, request.wIndex <= 255, request.wLength == 0,
            transport.supportsAlternate(UInt8(request.wIndex), alternate: UInt8(request.wValue)) else {
            finish(job, result: pipeStalled, bytes: 0); return
          }
          guard let previous = transport.currentAlternate(UInt8(request.wIndex)),
            let endpoints = transport.endpointsForInterface(UInt8(request.wIndex)) else {
            finish(job, result: pipeStalled, bytes: 0); return
          }
          do {
            invalidateEndpoints(endpoints)
            let selected = try transport.selectInterface(UInt8(request.wIndex), alternate: UInt8(request.wValue))
            finish(job, result: selected ? kIOReturnSuccess : pipeStalled, bytes: 0)
          } catch {
            // A failed native select may already have closed the old pipes.
            // Reselect and reopen them before deciding whether the session is lost.
            do {
              guard try transport.selectInterface(UInt8(request.wIndex), alternate: previous) else {
                throw USBError.message("Could not recover previous alternate")
              }
              finish(job, result: pipeStalled, bytes: 0)
            } catch {
              transportBroken = true
              finish(job, result: nativeError(error), bytes: 0)
              connection.interrupt()
            }
          }
        } else if request.bmRequestType == 0x81 && request.bRequest == 10 {
          guard request.wValue == 0, request.wIndex <= 255, request.wLength == 1,
            let alternate = transport.currentAlternate(UInt8(request.wIndex)) else {
            finish(job, result: pipeStalled, bytes: 0); return
          }
          job.data.mutableBytes.storeBytes(of: alternate, as: UInt8.self)
          finish(job, result: kIOReturnSuccess, bytes: 1)
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
        if isIso {
          try transport.enqueueIso(address, data: job.data, packets: job.isoPackets,
            startFrame: job.startFrame, interval: job.interval, asap: job.flags & 2 != 0) {
              [weak self, job] result, frame, packets in
              self?.operations.async { [weak self, job] in
                guard let self, self.active[job.address]?.contains(where: { $0 === job }) == true else { return }
                if var progress = self.isoProgress[job.address] {
                  progress.lastCompletion = self.now(); progress.logged = false
                  self.isoProgress[job.address] = progress
                }
                job.startFrame = frame
                job.isoPackets = packets
                job.isoCompleted = true
                self.nativeCompleted(job, result: result, bytes: 0)
              }
            }
          startNext(address)
          return
        }
        // Bulk reads may wait indefinitely for legitimate device data, like interrupts.
        try transport.enqueueIO(address, data: job.data.length == 0 ? nil : job.data,
          timeout: 0, completion: callback(job))
      }
    } catch { finish(job, result: nativeError(error), bytes: 0) }
  }
  private func startIsoWatchdog() {
    guard isoWatchdog == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: operations)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { [weak self] in self?.checkIsoWatchdog() }
    isoWatchdog = timer
    timer.resume()
  }
  // Internal entry point lets tests advance a fake clock without sleeping.
  func checkIsoWatchdog() {
    serialized {
      guard !closed else { return }
      for (address, var progress) in isoProgress {
        let waiting = pending.values.filter { $0.address == address && !$0.isoPackets.isEmpty }.count
        guard waiting > 0, !progress.logged, now() - progress.lastCompletion > 2000 else { continue }
        progress.logged = true
        isoProgress[address] = progress
        let running = active[address]?.count ?? 0
        let queuedCount = queued[address]?.count ?? 0
        log("Iso endpoint \(String(format: "0x%02x", address)) stalled >2s generation \(progress.generation) active \(running) queued \(queuedCount) pending \(waiting)")
      }
    }
  }
  deinit { isoWatchdog?.cancel() }
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
      if active[job.address]?.contains(where: { $0 === job }) == true {
        // IOUSBHost exposes pipe-wide abort only. If other iso URBs share this
        // pipe, cancel this wire request logically and retain its native memory
        // until completion rather than aborting neighbouring stream packets.
        // Already scheduled OUT packets may still reach the device after UNLINK.
        if !job.isoPackets.isEmpty && (active[job.address]?.count ?? 0) > 1 { return }
        do {
          try transport.abort(job.address)
          // A pipe-wide iso abort closes this scheduling generation even when
          // IOUSBHost never calls back. Shared-pipe logical UNLINK above does
          // not abort neighbours and continues to retain its native admission.
          if !job.isoPackets.isEmpty { invalidateEndpoints([job.address]) }
        }
        catch { transportBroken = true; connection.interrupt() }
      } else {
        queued[job.address]?.removeAll { $0 === job }
      }
    }
  }
  func shutdownTransfers() {
    serialized {
      closed = true
      isoWatchdog?.cancel(); isoWatchdog = nil
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
      try usb.open(target.matchingConfig, configuration: identity.configuration,
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
