// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation
import XCTest
@testable import LongcableCore

// A device another app holds (Wave Link holds the Wave:3) can't be opened to read
// its descriptors, but macOS still knows its name and whether it's an audio device.
final class DeviceNameTests: XCTestCase {
  private var temporary: URL!
  private var store: StorePaths!
  private let wave = TargetConfig(vendor: 0x0fd9, product: 0x0070, location: 0x02100000, label: "USB0FD90070")

  override func setUpWithError() throws {
    temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    store = StorePaths(targets: temporary.appendingPathComponent("targets.json").path,
      state: temporary.appendingPathComponent("sharing.json").path,
      launchDaemon: temporary.appendingPathComponent("service.plist").path)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

  func testNameAndAudioComeFromMacOSAndAreRemembered() throws {
    var present = [LocalUSBDevice(vendor: "0fd9", product: "0070", location: "02100000",
      name: "Elgato Wave:3", serial: "", audio: true)]
    let s = USBServer(config: try DaemonConfig(arguments: ["127.0.0.1", "127.0.0.1", "fd9", "70", "2100000", "USB0FD90070"]),
      store: store, consoleUID: { 501 }, inventory: { present }, log: { _ in })
    try s.loadPersistentState()
    XCTAssertEqual(s.status().devices.first?.name, "Elgato Wave:3")
    XCTAssertEqual(s.status().devices.first?.audio, true)
    present = []  // unplugged: keep what we learned
    XCTAssertEqual(s.status().devices.first?.name, "Elgato Wave:3")
    XCTAssertEqual(s.status().devices.first?.audio, true)
  }

  func testOtherDevicesAreNotAudio() throws {
    let present = [LocalUSBDevice(vendor: "231d", product: "0201", location: "00001234",
      name: "VKBsim Gladiator EVO L", serial: "", audio: false)]
    let s = USBServer(config: try DaemonConfig(arguments: ["127.0.0.1", "127.0.0.1", "231d", "201", "1234", "LEFT"]),
      store: store, consoleUID: { 501 }, inventory: { present }, log: { _ in })
    try s.loadPersistentState()
    XCTAssertEqual(s.status().devices.first?.audio, false)
    XCTAssertEqual(s.status().devices.first?.name, "VKBsim Gladiator EVO L")
  }

  // A microphone has an audio streaming interface and no camera part. Interfaces
  // are (class, subclass) as macOS lists them without opening the device.
  func testWhatCountsAsAMicrophone() {
    let wave3: [(UInt32, UInt32)] = [(1, 1), (1, 2), (1, 2), (255, 240), (254, 1)]
    XCTAssertTrue(isMicrophone(interfaces: wave3))
    XCTAssertFalse(isMicrophone(interfaces: [(14, 1), (14, 2), (1, 1), (1, 2)]), "webcam with a microphone")
    XCTAssertFalse(isMicrophone(interfaces: [(1, 1), (1, 3)]), "MIDI keyboard")
    XCTAssertFalse(isMicrophone(interfaces: [(14, 1), (14, 2), (255, 0)]), "eye tracker")
    XCTAssertFalse(isMicrophone(interfaces: [(3, 0)]), "joystick")
  }

  // Values as macOS reports them for real devices: (class, subclass, protocol).
  func testDeviceKinds() {
    XCTAssertEqual(deviceKind(deviceClass: 0, interfaces: [(8, 6, 98), (8, 6, 80)], name: "Ugreen Storage Device"), "storage")
    XCTAssertEqual(deviceKind(deviceClass: 0, interfaces: [(3, 1, 1), (3, 1, 1), (3, 0, 0)], name: "Keychron Q6 HE"), "keyboard")
    XCTAssertEqual(deviceKind(deviceClass: 0, interfaces: [(3, 1, 2)], name: "Mouse"), "mouse")
    XCTAssertEqual(deviceKind(deviceClass: 0, interfaces: [(3, 1, 1), (3, 0, 0), (11, 0, 0)], name: "YubiKey OTP+FIDO+CCID"),
                   "security-key", "a key that also types counts as a key")
    XCTAssertEqual(deviceKind(deviceClass: 0, interfaces: [(3, 0, 0)], name: "Security Key by Yubico"), "security-key")
    XCTAssertEqual(deviceKind(deviceClass: 239, interfaces: [(14, 1, 0), (14, 2, 0), (1, 1, 0), (1, 2, 0)], name: "Webcam"), "camera")
    XCTAssertNil(deviceKind(deviceClass: 0, interfaces: [(3, 0, 0)], name: " VKBsim Gladiator EVO R"))
  }

  func testDockPartsAndDisplayAdaptersAreMinor() {
    // USB-C billboards only describe display modes.
    XCTAssertTrue(isMinorDevice(deviceClass: 17, interfaces: [(17, 0, 0)], vendor: 0x2109, hubVendor: 0x2188))
    XCTAssertTrue(isMinorDevice(deviceClass: 0, interfaces: [(255, 0, 0), (17, 0, 0)], vendor: 0x2188, hubVendor: 0x2188))
    // Made by the same company as the hub it sits behind: part of the dock.
    XCTAssertTrue(isMinorDevice(deviceClass: 0, interfaces: [(3, 0, 0)], vendor: 0x2188, hubVendor: 0x2188))
    // A keyboard or joystick plugged into the dock is not.
    XCTAssertFalse(isMinorDevice(deviceClass: 0, interfaces: [(3, 1, 1)], vendor: 0x3434, hubVendor: 0x2188))
    XCTAssertFalse(isMinorDevice(deviceClass: 0, interfaces: [(3, 0, 0)], vendor: 0x231d, hubVendor: nil))
  }

  func testMicrophoneIsRememberedAcrossRestartWhileUnplugged() throws {
    let args = ["127.0.0.1", "127.0.0.1", "fd9", "70", "2100000", "USB0FD90070"]
    let wave = LocalUSBDevice(vendor: "0fd9", product: "0070", location: "02100000", name: "Elgato Wave:3", serial: "", audio: true)
    let first = USBServer(config: try DaemonConfig(arguments: args), store: store, consoleUID: { 501 },
      inventory: { [wave] }, log: { _ in })
    try first.loadPersistentState()
    XCTAssertEqual(first.status().devices.first?.audio, true)
    let restarted = USBServer(config: try DaemonConfig(arguments: args), store: store, consoleUID: { 501 },
      inventory: { [] }, log: { _ in })
    try restarted.loadPersistentState()
    XCTAssertEqual(restarted.status().devices.first?.audio, true, "unplugged after a restart")
  }

  // While Windows has the device, macOS may stop listing its interfaces.
  func testMicrophoneIsNotForgottenWhenInterfacesVanish() throws {
    var audio = true
    let s = USBServer(config: try DaemonConfig(arguments: ["127.0.0.1", "127.0.0.1", "fd9", "70", "2100000", "USB0FD90070"]),
      store: store, consoleUID: { 501 },
      inventory: { [LocalUSBDevice(vendor: "0fd9", product: "0070", location: "02100000", name: "Elgato Wave:3", serial: "", audio: audio)] },
      log: { _ in })
    try s.loadPersistentState()
    XCTAssertEqual(s.status().devices.first?.audio, true)
    audio = false
    XCTAssertEqual(s.status().devices.first?.audio, true)
  }
}
