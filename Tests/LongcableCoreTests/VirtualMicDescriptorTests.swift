// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation
import XCTest
@testable import LongcableCore

final class VirtualMicDescriptorTests: XCTestCase {
  private func descriptors(_ c: Data) -> [Data] {
    var result = [Data]()
    var i = 0
    while i < c.count {
      let length = Int(c[i])
      XCTAssertGreaterThanOrEqual(length, 2, "descriptor at \(i)")
      guard length >= 2, i + length <= c.count else { XCTFail("overrun at \(i)"); return result }
      result.append(Data(c[i..<(i + length)]))
      i += length
    }
    XCTAssertEqual(i, c.count)
    return result
  }

  func testDeviceDescriptorPinsIdentity() {
    let d = VirtualMic.deviceDescriptor
    XCTAssertEqual(d.count, 18)
    XCTAssertEqual(d[0], 18)
    XCTAssertEqual(d[1], 1)
    XCTAssertEqual(d.u16LE(2), 0x0110)
    XCTAssertEqual(d[4], 0); XCTAssertEqual(d[5], 0); XCTAssertEqual(d[6], 0)
    XCTAssertEqual(d[7], 64)
    XCTAssertEqual(d.u16LE(8), 0x1209)
    XCTAssertEqual(d.u16LE(10), 0x0001)
    XCTAssertEqual(d.u16LE(12), 0x0100)
    XCTAssertEqual([d[14], d[15], d[16], d[17]], [1, 2, 3, 1])
  }

  func testConfigurationWalksCleanlyAndTotalsMatch() {
    let c = VirtualMic.configurationDescriptor
    XCTAssertEqual(c[1], 2)
    XCTAssertEqual(Int(c.u16LE(2)), c.count)
    XCTAssertEqual(c[4], 2)
    XCTAssertEqual(c[5], 1)
    XCTAssertEqual(c[7], 0x80)
    XCTAssertEqual(c[8], 50)
    let all = descriptors(c)
    let interfaces = all.filter { $0[1] == 4 }
    XCTAssertEqual(interfaces.map { [$0[2], $0[3], $0[4], $0[5], $0[6]] },
      [[0, 0, 0, 1, 1], [1, 0, 0, 1, 2], [1, 1, 1, 1, 2]])
    // The audio control header's wTotalLength covers header + both terminals.
    let header = all.first { $0[1] == 0x24 && $0[2] == 1 && $0.count == 9 }!
    XCTAssertEqual(header.u16LE(3), 0x0100)
    XCTAssertEqual(Int(header.u16LE(5)), 9 + 12 + 9)
    XCTAssertEqual(header[7], 1); XCTAssertEqual(header[8], 1)
    let input = all.first { $0[1] == 0x24 && $0[2] == 2 }!
    XCTAssertEqual(input[3], 1); XCTAssertEqual(input.u16LE(4), 0x0201); XCTAssertEqual(input[7], 1)
    let output = all.first { $0[1] == 0x24 && $0[2] == 3 && $0.count == 9 }!
    XCTAssertEqual(output[3], 2); XCTAssertEqual(output.u16LE(4), 0x0101); XCTAssertEqual(output[7], 1)
  }

  func testStreamingFormatIsMono16Bit48k() {
    let all = descriptors(VirtualMic.configurationDescriptor)
    let general = all.first { $0[1] == 0x24 && $0[2] == 1 && $0.count == 7 }!
    XCTAssertEqual(general[3], 2); XCTAssertEqual(general.u16LE(5), 0x0001)
    let format = all.first { $0[1] == 0x24 && $0[2] == 2 && $0.count == 11 }!
    XCTAssertEqual(Array(format[3...7]), [1, 1, 2, 16, 1])
    XCTAssertEqual(Array(format[8...10]), [0x80, 0xBB, 0x00])
  }

  func testStreamingEndpointIsAsyncIsoIn98Bytes() {
    let all = descriptors(VirtualMic.configurationDescriptor)
    let endpoints = all.filter { $0[1] == 5 }
    XCTAssertEqual(endpoints.count, 1)
    let ep = endpoints[0]
    XCTAssertEqual(ep.count, 9)
    XCTAssertEqual(ep[2], 0x81); XCTAssertEqual(ep[3], 0x05)
    XCTAssertEqual(ep.u16LE(4), 98); XCTAssertEqual(ep[6], 1)
    XCTAssertEqual(ep[7], 0); XCTAssertEqual(ep[8], 0)
    let classEndpoint = all.first { $0[1] == 0x25 }!
    XCTAssertEqual(Array(classEndpoint), [7, 0x25, 1, 1, 0, 0, 0])
  }

  func testAlternateOneIsFoundByExistingParser() {
    XCTAssertNotNil(interfaceOffset(VirtualMic.configurationDescriptor, number: 1, alternate: 1))
    XCTAssertNotNil(interfaceOffset(VirtualMic.configurationDescriptor, number: 1, alternate: 0))
    XCTAssertNil(interfaceOffset(VirtualMic.configurationDescriptor, number: 1, alternate: 2))
  }

  func testStringDescriptors() {
    XCTAssertEqual(VirtualMic.stringDescriptor(0, serial: "x"), Data([4, 3, 0x09, 0x04]))
    XCTAssertEqual(VirtualMic.stringDescriptor(1, serial: "x"), serialDescriptor("Longcable"))
    XCTAssertEqual(VirtualMic.stringDescriptor(2, serial: "x"), serialDescriptor("Longcable Mic"))
    XCTAssertEqual(VirtualMic.stringDescriptor(3, serial: "abc"), serialDescriptor("abc"))
    XCTAssertNil(VirtualMic.stringDescriptor(9, serial: "x"))
  }

  func testIdentityRecordMatchesBus21() {
    let id = VirtualMic.identity(serial: "abc")
    XCTAssertEqual(id.record.count, 312)
    var busID = Data(count: 32); busID.putString(0, 32, "2-1")
    XCTAssertEqual(id.record[256..<288], busID[0..<32])
    XCTAssertEqual(id.record.u32(288), 2)
    XCTAssertEqual(id.record.u32(292), 1)
    XCTAssertEqual(id.record.u32(296), 2)
    // USB/IP records are big-endian.
    XCTAssertEqual(Array(id.record[300..<304]), [0x12, 0x09, 0x00, 0x01])
    XCTAssertEqual(id.record[309], 1); XCTAssertEqual(id.record[310], 1); XCTAssertEqual(id.record[311], 2)
    XCTAssertEqual(id.classes, Data([1, 1, 0, 0, 1, 2, 0, 0]))
    XCTAssertFalse(id.overlaySerial)
    XCTAssertEqual(id.configuration, 1)
    XCTAssertEqual(id.name, "Longcable Mic")
    XCTAssertEqual(id.serial, "abc")
    XCTAssertEqual(VirtualMic.busID, "2-1")
    XCTAssertEqual(VirtualMic.wireID, 0x0002_0001)
  }

  func testMacSerialIsStableHex() {
    let a = VirtualMic.macSerial(), b = VirtualMic.macSerial()
    XCTAssertEqual(a, b)
    XCTAssertEqual(a.count, 12)
    XCTAssertTrue(a.allSatisfy { $0.isHexDigit })
  }
}
