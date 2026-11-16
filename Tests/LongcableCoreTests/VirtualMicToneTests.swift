// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation
import XCTest
@testable import LongcableCore

final class VirtualMicToneTests: XCTestCase {
  func testToneSourceProducesExpectedFrequency() {
    let tone = ToneSource(frequency: 440, buffer: MicBuffer())
    // Generated in pieces, as the timer does: phase must carry across calls.
    var samples = [Int16]()
    for _ in 0..<100 { samples += tone.generate(count: 480) }
    XCTAssertEqual(samples.count, 48_000)
    var crossings = 0
    for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
    XCTAssertEqual(Double(crossings), 880, accuracy: 4)
    XCTAssertEqual(Int(samples.max()!), Int(Double(Int16.max) * 0.25), accuracy: 2)
  }

  func testToneFillsBufferOnlyWhileRunning() {
    let buffer = MicBuffer()
    var now: Int64 = 0
    let tone = ToneSource(frequency: 440, buffer: buffer, clock: { now }, startTimer: false)
    tone.start()
    now = 20; tone.tick()
    XCTAssertEqual(buffer.fill, 960)
    tone.stop()
    now = 40; tone.tick()
    XCTAssertEqual(buffer.fill, 960)
  }
}
