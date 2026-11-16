// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import LongcableCore
import XCTest
@testable import Longcable

final class MicrophoneChoiceTests: XCTestCase {
  private func device(_ id: String, enabled: Bool, audio: Bool) -> DeviceStatus {
    DeviceStatus(id: id, name: id, model: "0fd9:0070", serial: id, enabled: enabled, state: "",
      location: "", completed: 0, bytes: 0, errors: 0, pending: 0, lastActivity: nil, lastError: nil, audio: audio)
  }
  private let stick = DeviceStatus(id: "1-1", name: "VKB", model: "231d:0201", serial: "", enabled: true, state: "",
    location: "", completed: 0, bytes: 0, errors: 0, pending: 0, lastActivity: nil, lastError: nil, audio: false)

  func testCurrentChoice() {
    XCTAssertEqual(MicrophoneChoice.current(micEnabled: false, devices: [stick, device("1-5", enabled: false, audio: true)]), .off)
    XCTAssertEqual(MicrophoneChoice.current(micEnabled: true, devices: [stick, device("1-5", enabled: false, audio: true)]), .mac)
    XCTAssertEqual(MicrophoneChoice.current(micEnabled: false, devices: [stick, device("1-5", enabled: true, audio: true)]),
      .handOver("1-5"))
    // Both on (set up before this card existed): Longcable Mic is what works, and
    // the passed-through mic is the conflict to point out.
    XCTAssertEqual(MicrophoneChoice.current(micEnabled: true, devices: [stick, device("1-5", enabled: true, audio: true)]), .mac)
    XCTAssertEqual(MicrophoneChoice.conflicting(micEnabled: true, devices: [stick, device("1-5", enabled: true, audio: true)]), ["1-5"])
    XCTAssertEqual(MicrophoneChoice.conflicting(micEnabled: false, devices: [device("1-5", enabled: true, audio: true)]), [])
    // A shared stick is not a microphone choice.
    XCTAssertEqual(MicrophoneChoice.current(micEnabled: false, devices: [stick]), .off)
  }

  // Permission first, so a denied permission gives nothing up; then give the
  // passed-through mic back to the Mac, then start Longcable Mic.
  func testShareTheMacsMicChecksPermissionThenGivesTheMicBack() {
    let steps = MicrophoneChoice.steps(to: .mac, micEnabled: false, devices: [stick, device("1-5", enabled: true, audio: true)])
    XCTAssertEqual(steps, [.ensurePermission, .unshare("1-5"), .micOn])
    XCTAssertEqual(MicrophoneChoice.steps(to: .mac, micEnabled: true, devices: [device("1-5", enabled: true, audio: true)]),
      [.unshare("1-5")], "fixing a both-on setup")
  }

  // Share the chosen mic first: if that fails, Longcable Mic keeps running.
  func testHandOverSharesFirstThenTurnsLongcableMicOff() {
    let devices = [stick, device("1-5", enabled: false, audio: true), device("1-6", enabled: true, audio: true)]
    XCTAssertEqual(MicrophoneChoice.steps(to: .handOver("1-5"), micEnabled: true, devices: devices),
      [.share("1-5"), .unshare("1-6"), .micOff])
    XCTAssertEqual(MicrophoneChoice.steps(to: .handOver("1-6"), micEnabled: false, devices: devices), [],
      "already the case")
  }

  func testOffStopsBothButNeverTouchesOtherDevices() {
    XCTAssertEqual(MicrophoneChoice.steps(to: .off, micEnabled: true, devices: [stick, device("1-5", enabled: true, audio: true)]),
      [.micOff, .unshare("1-5")])
  }

  func testHandOverANewUSBMicAddsIt() {
    let fresh = LocalUSBDevice(vendor: "0fd9", product: "0070", location: "02100000", name: "Elgato Wave:3", serial: "", audio: true)
    XCTAssertEqual(MicrophoneChoice.steps(to: .handOverNew(fresh), micEnabled: true, devices: [stick]),
      [.add(fresh), .micOff])
  }
}
