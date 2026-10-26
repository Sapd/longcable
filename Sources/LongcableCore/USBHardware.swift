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
  var chosen: io_service_t?
  while true {
    let s = IOIteratorNext(iterator)
    if s == 0 { break }
    if config.matches(
      vendor: number(s, "idVendor"), product: number(s, "idProduct"),
      location: number(s, "locationID"))
    {
      if let previous = chosen {
        IOObjectRelease(previous)
        IOObjectRelease(s)
        return nil
      }
      chosen = s
    } else {
      IOObjectRelease(s)
    }
  }
  return chosen
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
  var pipes = [UInt8: IOUSBHostPipe]()
  var types = [UInt8: UInt8]()
  private var packetSizes = [UInt8: Int]()
  private var interfaceByNumber = [UInt8: IOUSBHostInterface]()
  private var endpointsByInterface = [UInt8: Set<UInt8>]()
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
      try openPipes(interface)
    }
    guard let config = device.configurationDescriptor, !interfaces.isEmpty,
      interfaces.count == Int(config.pointee.bNumInterfaces)
    else { throw USBError.message("Incomplete interfaces") }
  }
  private func openPipes(_ interface: IOUSBHostInterface) throws {
    let descriptor = interface.interfaceDescriptor
    let config = interface.configurationDescriptor
    let start = UnsafeRawPointer(descriptor)
    let base = UnsafeRawPointer(config)
    let total = Int(UInt16(littleEndian: config.pointee.wTotalLength))
    let offset = base.distance(to: start)
    guard offset >= 0 && offset + 9 <= total && descriptor.pointee.bLength >= 9 else {
      throw USBError.message("Invalid interface descriptor")
    }
    let bytes = Data(bytes: base, count: total)
    var selectedPipes = [UInt8: IOUSBHostPipe]()
    var selectedTypes = [UInt8: UInt8]()
    var selectedPacketSizes = [UInt8: Int]()
    var i = offset + Int(descriptor.pointee.bLength)
    while i + 2 <= total && bytes[i] >= 2 && i + Int(bytes[i]) <= total && bytes[i + 1] != 4 {
      if bytes[i + 1] == 5 && bytes[i] >= 7 {
        let address = bytes[i + 2]
        let type = bytes[i + 3] & 3
        if type == 2 || type == 3 {
          selectedPipes[address] = try interface.copyPipe(withAddress: Int(address))
          selectedTypes[address] = type
          selectedPacketSizes[address] = Int(bytes.u16LE(i + 4) & 0x7ff)
        } else if type == 1 {
          throw USBError.message("Isochronous transfers are not supported")
        }
      }
      i += Int(bytes[i])
    }
    for (address, pipe) in selectedPipes {
      pipes[address] = pipe
      types[address] = selectedTypes[address]
      packetSizes[address] = selectedPacketSizes[address]
    }
    endpointsByInterface[descriptor.pointee.bInterfaceNumber] = Set(selectedPipes.keys)
  }
  func endpointsForInterface(_ number: UInt8) -> Set<UInt8>? {
    guard interfaceByNumber[number] != nil else { return nil }
    return endpointsByInterface[number] ?? []
  }
  func selectInterface(_ number: UInt8) throws -> Bool {
    guard let interface = interfaceByNumber[number] else { return false }
    // Selecting even the current alternate resets this interface's endpoint state.
    // The SDK aborts/closes only this interface's old pipes; other interfaces stay live.
    try guarded { try interface.selectAlternateSetting(0) }
    for address in endpointsByInterface[number] ?? [] {
      pipes.removeValue(forKey: address)
      types.removeValue(forKey: address)
      packetSizes.removeValue(forKey: address)
    }
    endpointsByInterface.removeValue(forKey: number)
    try guarded { try openPipes(interface) }
    return true
  }
  private func clearInterfaces() {
    for pipe in pipes.values { try? guarded { try pipe.__abort(with: .synchronous) } }
    for interface in interfaces { try? guarded { interface.destroy() } }
    pipes.removeAll()
    types.removeAll()
    packetSizes.removeAll()
    interfaces.removeAll()
    interfaceByNumber.removeAll()
    endpointsByInterface.removeAll()
  }
  func endpointType(_ address: UInt8) -> UInt8? { types[address] }
  func maximumPacketSize(_ address: UInt8) -> Int? { packetSizes[address] }
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
    guard let pipe = pipes[address] else { throw USBError.message("No endpoint") }
    try guarded {
      try pipe.enqueueIORequest(with: data, completionTimeout: timeout,
        completionHandler: { result, count in completion(result, Int(count)) })
    }
  }
  func abort(_ address: UInt8) throws {
    if address == 0 {
      guard let device else { throw USBError.message("No capture") }
      try guarded { try device.__abortDeviceRequests(with: .synchronous) }
    } else {
      guard let pipe = pipes[address] else { throw USBError.message("No endpoint") }
      try guarded { try pipe.__abort(with: .synchronous) }
    }
  }
  func clearHalt(_ address: UInt8) throws {
    guard let pipe = pipes[address] else { throw USBError.message("No endpoint") }
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
