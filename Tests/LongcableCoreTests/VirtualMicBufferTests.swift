// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation
import XCTest
@testable import LongcableCore

final class VirtualMicBufferTests: XCTestCase {
  private func read(_ buffer: MicBuffer, capacity: Int = 98) -> [Int16] {
    var bytes = [UInt8](repeating: 0xAA, count: capacity)
    let count = bytes.withUnsafeMutableBytes { buffer.readPacket(into: $0.baseAddress!, capacityBytes: capacity) }
    return (0..<(count / 2)).map { Int16(bitPattern: UInt16(bytes[$0 * 2]) | UInt16(bytes[$0 * 2 + 1]) << 8) }
  }
  private func ramp(_ count: Int, from start: Int = 1) -> [Int16] { (0..<count).map { Int16(truncatingIfNeeded: start + $0) } }

  func testPrimingSendsSilence48() {
    let buffer = MicBuffer()
    buffer.write(ramp(MicBuffer.target - 1))
    let packet = read(buffer)
    XCTAssertEqual(packet.count, 48)
    XCTAssertTrue(packet.allSatisfy { $0 == 0 })
    XCTAssertEqual(buffer.fill, MicBuffer.target - 1)
  }

  func testSteadyStateSends48() {
    let buffer = MicBuffer()
    buffer.write(ramp(MicBuffer.target + 48))
    XCTAssertEqual(read(buffer), ramp(48))
    XCTAssertEqual(buffer.fill, MicBuffer.target)
  }

  func testHighFillSends49() {
    let buffer = MicBuffer()
    buffer.write(ramp(MicBuffer.target + MicBuffer.band + 1))
    XCTAssertEqual(read(buffer).count, 49)
  }

  func testLowFillSends47() {
    let buffer = MicBuffer()
    buffer.write(ramp(MicBuffer.target))
    var sizes = [Int]()
    // Drain without refilling; once fill drops below target − band packets shrink.
    while buffer.fill >= MicBuffer.target - MicBuffer.band { sizes.append(read(buffer).count) }
    XCTAssertEqual(read(buffer).count, 47)
    XCTAssertTrue(sizes.allSatisfy { $0 == 48 })
  }

  func testUnderrunPadsWithZerosAndReprimes() {
    let buffer = MicBuffer()
    buffer.write(ramp(MicBuffer.target))
    // Drain everything that is left in 47-sample packets after the band.
    var last = [Int16]()
    while buffer.fill > 0 { last = read(buffer) }
    XCTAssertEqual(last.count, 47)
    XCTAssertTrue(last.contains(0), "short tail is padded with zeros")
    // 960 → three 48-sample packets (to 816), then 17 × 47, leaving 17 real samples.
    XCTAssertEqual(last.filter { $0 != 0 }.count, 17)
    XCTAssertEqual(Array(last.suffix(30)), [Int16](repeating: 0, count: 30))
    // Empty → priming again: below target only silence.
    buffer.write(ramp(10, from: 5000))
    let packet = read(buffer)
    XCTAssertEqual(packet.count, 48)
    XCTAssertTrue(packet.allSatisfy { $0 == 0 })
  }

  func testOverflowDropsOldest() {
    let buffer = MicBuffer()
    buffer.write(ramp(6000))
    XCTAssertEqual(buffer.fill, MicBuffer.maximum)
    XCTAssertEqual(read(buffer).first, 1201)
  }

  func testCapacitySmallerThanPacketClamps() {
    let buffer = MicBuffer()
    buffer.write(ramp(MicBuffer.target + 200))
    XCTAssertEqual(read(buffer, capacity: 64).count, 32)
  }

  func testResetEmptiesAndReprimes() {
    let buffer = MicBuffer()
    buffer.write(ramp(MicBuffer.target + 100))
    buffer.reset()
    XCTAssertEqual(buffer.fill, 0)
    buffer.write(ramp(100))
    XCTAssertTrue(read(buffer).allSatisfy { $0 == 0 })
  }
}
