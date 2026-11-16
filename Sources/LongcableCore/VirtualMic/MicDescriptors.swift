// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import CryptoKit
import Foundation
import IOKit

// What the app needs to know about Longcable Mic.
public enum LongcableMic {
  public static let busID = VirtualMic.busID
}

// A made-up USB Audio Class 1 microphone: mono, 16 bit, 48 kHz, one asynchronous
// isochronous IN endpoint. Windows loads its built-in usbaudio driver for it.
enum VirtualMic {
  // pid.codes test ID; replace with an allocated PID before release.
  static let vendor: UInt16 = 0x1209, product: UInt16 = 0x0001
  static let busID = "2-1", wireID: UInt32 = 0x0002_0001
  static let streamingEndpoint: UInt8 = 0x81
  static let maxPacketBytes = 98  // 49 samples × 2 bytes
  static let sampleRate = 48_000
  static let manufacturer = "Longcable", productName = "Longcable Mic"

  static var deviceDescriptor: Data {
    Data([18, 1, 0x10, 0x01, 0, 0, 0, 64,
          UInt8(vendor & 0xff), UInt8(vendor >> 8), UInt8(product & 0xff), UInt8(product >> 8),
          0x00, 0x01, 1, 2, 3, 1])
  }

  static var configurationDescriptor: Data {
    // Appended piece by piece: one long `+` chain of literals is too slow for the
    // Swift type checker on some compilers.
    let rate: [UInt8] = [UInt8(sampleRate & 0xff), UInt8((sampleRate >> 8) & 0xff), UInt8(sampleRate >> 16)]
    var body: [UInt8] = []
    body += [9, 4, 0, 0, 0, 1, 1, 0, 0] as [UInt8]  // interface 0: audio control
    body += [9, 0x24, 1, 0x00, 0x01, 30, 0, 1, 1] as [UInt8]  // AC header: bcdADC 1.00, total 30, streaming interface 1
    body += [12, 0x24, 2, 1, 0x01, 0x02, 0, 1, 0x00, 0x00, 0, 0] as [UInt8]  // input terminal 1: microphone, mono
    body += [9, 0x24, 3, 2, 0x01, 0x01, 0, 1, 0] as [UInt8]  // output terminal 2: USB streaming, from terminal 1
    body += [9, 4, 1, 0, 0, 1, 2, 0, 0] as [UInt8]  // interface 1 alt 0: zero bandwidth
    body += [9, 4, 1, 1, 1, 1, 2, 0, 0] as [UInt8]  // interface 1 alt 1: one endpoint
    body += [7, 0x24, 1, 2, 1, 0x01, 0x00] as [UInt8]  // AS general: terminal 2, delay 1, PCM
    body += [11, 0x24, 2, 1, 1, 2, 16, 1] as [UInt8]  // Type I: mono, 2-byte, 16-bit, one rate
    body += rate
    body += [9, 5, streamingEndpoint, 0x05, UInt8(maxPacketBytes), 0, 1, 0, 0] as [UInt8]  // iso IN async
    body += [7, 0x25, 1, 0x01, 0, 0, 0] as [UInt8]  // class endpoint: sampling frequency control
    let total = 9 + body.count
    let header: [UInt8] = [9, 2, UInt8(total & 0xff), UInt8(total >> 8), 2, 1, 0, 0x80, 50]
    return Data(header + body)
  }

  static func stringDescriptor(_ index: UInt8, serial: String) -> Data? {
    switch index {
    case 0: return Data([4, 3, 0x09, 0x04])
    case 1: return serialDescriptor(manufacturer)
    case 2: return serialDescriptor(productName)
    case 3: return serialDescriptor(serial)
    default: return nil
    }
  }

  static func identity(serial: String) -> Identity {
    let d = deviceDescriptor, c = configurationDescriptor
    var record = Data(count: 312)
    record.putString(0, 256, "/macos/virtual/longcable-mic")
    record.putString(256, 32, busID)
    record.put32(288, wireID >> 16)
    record.put32(292, wireID & 0xffff)
    record.put32(296, 2)  // full speed
    record.put16(300, vendor)
    record.put16(302, product)
    record.put16(304, d.u16LE(12))
    record[306] = d[4]; record[307] = d[5]; record[308] = d[6]
    record[309] = c[5]; record[310] = d[17]; record[311] = c[4]
    return Identity(record: record, classes: Data([1, 1, 0, 0, 1, 2, 0, 0]),
      configuration: c[5], overlaySerial: false, name: productName, serial: serial)
  }

  // Stable per Mac, not reversible to the hardware UUID.
  static func macSerial() -> String {
    let service = IOServiceGetMatchingService(kIOMainPortDefault,
      IOServiceMatching("IOPlatformExpertDevice"))
    defer { if service != 0 { IOObjectRelease(service) } }
    guard service != 0,
      let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString,
        kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    else { return "000000000000" }
    return SHA256.hash(data: Data(uuid.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
  }
}
