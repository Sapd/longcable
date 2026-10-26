// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation
import IOKit
import IOKit.usb
import IOUSBHost

func number(_ service: io_service_t, _ key: String) -> UInt32 {
  (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
    .takeRetainedValue() as? NSNumber)?.uint32Value ?? UInt32.max
}
func text(_ service: io_service_t, _ key: String) -> String {
  IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
    .takeRetainedValue() as? String ?? ""
}
func findDevice(_ config: TargetConfig) -> io_service_t? {
  var iterator: io_iterator_t = 0
  guard
    IOServiceGetMatchingServices(
      kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS
  else { return nil }
  defer { IOObjectRelease(iterator) }
  var services = [io_service_t]()
  var devices = [LocalUSBDevice]()
  while true {
    let service = IOIteratorNext(iterator)
    if service == 0 { break }
    services.append(service)
    devices.append(LocalUSBDevice(
      vendor: String(format: "%04x", number(service, "idVendor")),
      product: String(format: "%04x", number(service, "idProduct")),
      location: String(format: "%08x", number(service, "locationID")),
      name: "", serial: text(service, "USB Serial Number")))
  }
  let resolved = resolvedTarget(config, configured: [config], devices: devices)
  let matches = devices.indices.filter { resolved.matches(devices[$0]) }
  let chosen = matches.count == 1 ? matches[0] : nil
  for index in services.indices where index != chosen { IOObjectRelease(services[index]) }
  return chosen.map { services[$0] }
}

extension TargetConfig {
  func sameModel(_ device: LocalUSBDevice) -> Bool {
    UInt16(device.vendor, radix: 16) == vendor && UInt16(device.product, radix: 16) == product
  }
  func matches(_ device: LocalUSBDevice) -> Bool {
    guard let v = UInt32(device.vendor, radix: 16), let p = UInt32(device.product, radix: 16),
      let l = UInt32(device.location, radix: 16) else { return false }
    return matches(vendor: v, product: p, location: l, serial: device.serial)
  }
}

// Resolve before every lookup, including cache validation and capture. Unknown
// startup identities learn a serial only at their own port or from a unique model.
func resolvedTarget(_ config: TargetConfig, configured: [TargetConfig],
                    devices: [LocalUSBDevice]) -> TargetConfig {
  var result = config
  guard config.vendor != 0x05ac, !config.label.isEmpty else { return result }
  let model = devices.filter { config.sameModel($0) }
  let peers = configured.filter { $0.vendor == config.vendor && $0.product == config.product }
  if result.hardwareSerial == nil && result.portBound != true {
    let candidate = model.first { UInt32($0.location, radix: 16) == config.location }
      ?? (model.count == 1 && peers.count == 1 ? model.first : nil)
    if let candidate, !candidate.serial.isEmpty { result.hardwareSerial = candidate.serial }
  }
  let seriallessPeers = peers.filter { peer in
    peer.hardwareSerial == nil && !model.contains {
      UInt32($0.location, radix: 16) == peer.location && !$0.serial.isEmpty
    }
  }
  if result.hardwareSerial == nil &&
      (model.filter { $0.serial.isEmpty }.count > 1 || seriallessPeers.count > 1) {
    result.portBound = true
  }
  return result
}

func descriptorData<T>(_ pointer: UnsafePointer<T>, _ count: Int) -> Data {
  Data(bytes: pointer, count: count)
}
struct Identity {
  var record: Data
  var classes: Data
  var configuration: UInt8
  var overlaySerial: Bool
  var name: String
  var serial: String
  var registryID: UInt64 = 0
}
func loadIdentity(_ config: TargetConfig, busID: String, wireID: UInt32) throws -> Identity {
  guard let service = findDevice(config) else {
    throw USBError.message("Device absent or ambiguous")
  }
  defer { IOObjectRelease(service) }
  let name = text(service, "USB Product Name")
  let serial = text(service, "USB Serial Number")
  let speed = number(service, "Device Speed")
  var registryID: UInt64 = 0
  guard IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS else {
    throw USBError.message("Could not identify the physical USB device")
  }
  return try guarded {
    let device = try IOUSBHostDevice(
      __ioService: service, options: [], queue: nil, interestHandler: nil)
    defer { device.destroy() }
    guard let d = device.deviceDescriptor else { throw USBError.message("No device descriptor") }
    let desc = descriptorData(d, 18)
    let c = try device.configurationDescriptor(with: 0)
    let configData = descriptorData(c, Int(UInt16(littleEndian: c.pointee.wTotalLength)))
    guard configData.count >= 9 else { throw USBError.message("Invalid configuration") }
    var record = Data(count: 312)
    record.putString(
      0, 256,
      config.label.isEmpty
        ? String(format: "/macos/usb/%08x", config.location) : "/macos/identity/" + config.label)
    record.putString(256, 32, busID)
    record.put32(288, 1)
    record.put32(292, wireID & 0xffff)
    record.put32(296, speed <= 2 ? speed + 1 : (speed <= 4 ? 5 : 0))
    record.put16(300, desc.u16LE(8))
    record.put16(302, desc.u16LE(10))
    record.put16(304, desc.u16LE(12))
    record[306] = desc[4]
    record[307] = desc[5]
    record[308] = desc[6]
    record[309] = configData[5]
    record[310] = desc[17]
    record[311] = configData[4]
    var classes = Data()
    var i = Int(configData[0])
    while i + 2 <= configData.count && configData[i] >= 2
      && i + Int(configData[i]) <= configData.count
    {
      if configData[i + 1] == 4 && configData[i] >= 9 && configData[i + 3] == 0 {
        classes.append(contentsOf: [configData[i + 5], configData[i + 6], configData[i + 7], 0])
      }
      i += Int(configData[i])
    }
    guard classes.count == Int(configData[4]) * 4 else {
      throw USBError.message("Incomplete interface descriptors")
    }
    return Identity(
      record: record, classes: classes, configuration: configData[5],
      overlaySerial: !config.label.isEmpty && desc[16] == 0,
      name: name.isEmpty ? config.label : name, serial: serial.isEmpty ? config.label : serial,
      registryID: registryID)
  }
}
final class CapturedDevice: USBTransferTransport {
  var device: IOUSBHostDevice?
  var interfaces = [IOUSBHostInterface]()
  private struct NativePipe {
    let pipe: IOUSBHostPipe
    let iso: IsoPipeQueue?
  }
  private let pipeMap = InterfacePipeMap<NativePipe>()
  private var highSpeed = false
  private var superSpeed = false
  private var interfaceByNumber = [UInt8: IOUSBHostInterface]()
  var location: UInt32 = 0
  var disconnected: (() -> Void)?
  let queue = DispatchQueue(label: "org.sapd.longcable.usb.callbacks")
  func open(_ config: TargetConfig, configuration: UInt8, expectedRegistryID: UInt64? = nil) throws {
    guard let service = findDevice(config) else {
      throw USBError.message("Device absent or ambiguous")
    }
    defer { IOObjectRelease(service) }
    if let expectedRegistryID {
      var actualID: UInt64 = 0
      guard IORegistryEntryGetRegistryEntryID(service, &actualID) == KERN_SUCCESS,
        actualID == expectedRegistryID else {
        throw USBError.message("USB device changed before capture; refresh its identity")
      }
    }
    location = number(service, "locationID")
    highSpeed = number(service, "Device Speed") >= 2
    superSpeed = number(service, "Device Speed") >= 3
    try guarded {
      device = try IOUSBHostDevice(
        __ioService: service, options: .deviceCapture, queue: queue,
        interestHandler: { [weak self] _, message, _ in
          if message == 0xe000_0010 { self?.disconnected?() }
        })
    }
    try reconfigure(configuration)
  }
  func reconfigure(_ configuration: UInt8) throws {
    guard let device else { throw USBError.message("No capture") }
    clearInterfaces()
    try guarded { try device.__configure(withValue: Int(configuration), matchInterfaces: false) }
    usleep(500_000)
    let deadline = monotonicMS() + 2500
    var last: Error = USBError.message("Interfaces not ready")
    repeat {
      do {
        try guarded { try openInterfaces() }
        return
      } catch { last = error }
      clearInterfaces()
      usleep(100_000)
    } while monotonicMS() < deadline
    throw last
  }
  private func openInterfaces() throws {
    guard let device = device else { throw USBError.message("No capture") }
    var iterator: io_iterator_t = 0
    guard
      IORegistryEntryGetChildIterator(device.ioService, kIOServicePlane, &iterator) == KERN_SUCCESS
    else { throw USBError.message("No interfaces") }
    defer { IOObjectRelease(iterator) }
    while true {
      let s = IOIteratorNext(iterator)
      if s == 0 { break }
      defer { IOObjectRelease(s) }
      if IOObjectConformsTo(s, "IOUSBHostInterface") == 0 { continue }
      let interface = try IOUSBHostInterface(
        __ioService: s, options: [], queue: queue, interestHandler: nil)
      interfaces.append(interface)
      let number = interface.interfaceDescriptor.pointee.bInterfaceNumber
      guard interfaceByNumber[number] == nil else { throw USBError.message("Duplicate interface") }
      interfaceByNumber[number] = interface
      try openPipes(interface, alternate: interface.interfaceDescriptor.pointee.bAlternateSetting)
    }
    guard let config = device.configurationDescriptor, !interfaces.isEmpty,
      interfaces.count == Int(config.pointee.bNumInterfaces)
    else { throw USBError.message("Incomplete interfaces") }
  }
  private func openPipes(_ interface: IOUSBHostInterface, alternate: UInt8,
    selecting: Bool = false) throws {
    let number = interface.interfaceDescriptor.pointee.bInterfaceNumber
    let config = interface.configurationDescriptor
    let bytes = descriptorData(config, Int(UInt16(littleEndian: config.pointee.wTotalLength)))
    try pipeMap.replace(number: number, alternate: alternate, configuration: bytes, highSpeed: highSpeed,
      select: { if selecting { try interface.selectAlternateSetting(Int(alternate)) } },
      open: { endpoint in
        let pipe = try interface.copyPipe(withAddress: Int(endpoint.address))
        var iso: IsoPipeQueue?
        if let interval = endpoint.isoInterval, let device, !superSpeed {
          iso = IsoPipeQueue(pipe: pipe, highSpeed: highSpeed, interval: interval,
            maximumPayload: endpoint.maximumPayload, currentFrame: { device.__frameNumber(withTime: nil) })
        }
        return NativePipe(pipe: pipe, iso: iso)
      })
  }
  func endpointsForInterface(_ number: UInt8) -> Set<UInt8>? { pipeMap.endpoints(number) }
  func currentAlternate(_ number: UInt8) -> UInt8? { pipeMap.alternates[number] }
  func supportsAlternate(_ number: UInt8, alternate: UInt8) -> Bool {
    guard let interface = interfaceByNumber[number] else { return false }
    let config = interface.configurationDescriptor
    return interfaceEndpoints(descriptorData(config, Int(UInt16(littleEndian: config.pointee.wTotalLength))),
      number: number, alternate: alternate, highSpeed: highSpeed) != nil
  }
  func selectInterface(_ number: UInt8, alternate: UInt8) throws -> Bool {
    guard let interface = interfaceByNumber[number], supportsAlternate(number, alternate: alternate) else { return false }
    // Native selection aborts/closes old pipes on only this interface.
    try guarded { try openPipes(interface, alternate: alternate, selecting: true) }
    return true
  }
  private func clearInterfaces() {
    for binding in pipeMap.pipes.values { try? guarded { try binding.pipe.__abort(with: .synchronous) } }
    for interface in interfaces { try? guarded { interface.destroy() } }
    pipeMap.removeAll()
    interfaces.removeAll()
    interfaceByNumber.removeAll()
  }
  func endpointType(_ address: UInt8) -> UInt8? { pipeMap.descriptors[address]?.type }
  func maximumPacketSize(_ address: UInt8) -> Int? { pipeMap.descriptors[address]?.maximumPayload }

  func enqueueControl(_ request: IOUSBDeviceRequest, data: NSMutableData,
    completion: @escaping (IOReturn, Int) -> Void) throws {
    guard let device else { throw USBError.message("No capture") }
    try guarded {
      try device.__enqueue(request, data: data, completionTimeout: 5,
        completionHandler: { result, count in completion(result, Int(count)) })
    }
  }
  func enqueueIO(_ address: UInt8, data: NSMutableData?, timeout: TimeInterval,
    completion: @escaping (IOReturn, Int) -> Void) throws {
    guard let pipe = pipeMap.pipes[address]?.pipe else { throw USBError.message("No endpoint") }
    try guarded {
      try pipe.enqueueIORequest(with: data, completionTimeout: timeout,
        completionHandler: { result, count in completion(result, Int(count)) })
    }
  }
  func enqueueIso(_ address: UInt8, data: NSMutableData, packets: [IsoPacket],
    startFrame: UInt32, interval: UInt32, asap: Bool,
    completion: @escaping (IOReturn, UInt32, [IsoPacket]) -> Void) throws {
    // USB 3 companion-descriptor burst sizing is not implemented yet. Do not
    // issue incorrectly sized native transfers for SuperSpeed iso endpoints.
    guard let queue = pipeMap.pipes[address]?.iso else {
      throw NSError(domain: "IOUSBHost", code: Int(kIOReturnUnsupported))
    }
    try queue.enqueue(data: data, packets: packets, startFrame: startFrame,
      requestedInterval: interval, asap: asap, completion: completion)
  }
  func abort(_ address: UInt8) throws {
    pipeMap.pipes[address]?.iso?.reset()
    if address == 0 {
      guard let device else { throw USBError.message("No capture") }
      try guarded { try device.__abortDeviceRequests(with: .synchronous) }
    } else {
      guard let pipe = pipeMap.pipes[address]?.pipe else { throw USBError.message("No endpoint") }
      try guarded { try pipe.__abort(with: .synchronous) }
    }
  }
  func clearHalt(_ address: UInt8) throws {
    guard let pipe = pipeMap.pipes[address]?.pipe else { throw USBError.message("No endpoint") }
    try guarded { try pipe.clearStall() }
  }
  func release() {
    // Removal callback captures only the session weakly; no retain cycle with capture.
    clearInterfaces()
    if let d = device { try? guarded { d.destroy() } }
    device = nil
  }
  deinit { release() }
}

public struct LocalUSBDevice: Codable, Sendable {
  public let vendor: String
  public let product: String
  public let location: String
  public let name: String
  public let serial: String
}
func deviceMayBeShared(vendor: UInt32, product: UInt32, location: UInt32,
                       configured: [TargetConfig]) -> Bool {
  vendor != 0x05ac || configured.contains {
    UInt32($0.vendor) == vendor && UInt32($0.product) == product && $0.location == location
  }
}
func visibleDevices(_ devices: [LocalUSBDevice], configured: [TargetConfig]) -> [LocalUSBDevice] {
  devices.filter {
    guard let vendor = UInt32($0.vendor, radix: 16),
          let product = UInt32($0.product, radix: 16),
          let location = UInt32($0.location, radix: 16) else { return false }
    return deviceMayBeShared(vendor: vendor, product: product, location: location, configured: configured)
  }
}
public func discoverUSBDevices(allowedAppleDevices: [TargetConfig] = []) -> [LocalUSBDevice] {
  var iterator: io_iterator_t = 0
  guard
    IOServiceGetMatchingServices(
      kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS
  else { return [] }
  defer { IOObjectRelease(iterator) }
  var result = [LocalUSBDevice]()
  while true {
    let service = IOIteratorNext(iterator)
    if service == 0 { break }
    defer { IOObjectRelease(service) }
    let vendor = number(service, "idVendor")
    let product = number(service, "idProduct")
    guard vendor <= 65535, product <= 65535, number(service, "bDeviceClass") != 9,
      deviceMayBeShared(vendor: vendor, product: product, location: number(service, "locationID"),
                        configured: allowedAppleDevices) else { continue }
    result.append(
      LocalUSBDevice(
        vendor: String(format: "%04x", vendor), product: String(format: "%04x", product),
        location: String(format: "%08x", number(service, "locationID")),
        name: text(service, "USB Product Name"), serial: text(service, "USB Serial Number")))
  }
  return result.sorted { $0.location < $1.location }
}
