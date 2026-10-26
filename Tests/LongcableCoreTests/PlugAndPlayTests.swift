// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import XCTest

@testable import LongcableCore

final class PlugAndPlayTests: XCTestCase {
  let first = TargetConfig(vendor: 0x231d, product: 0x0201, location: 0x1234, label: "VKBLEFT0201")
  let fresh = LocalUSBDevice(
    vendor: "2104", product: "0313", location: "00005678", name: "EyeChip", serial: "serial")
  func testNetworkOnlyFirstRunStartsWithNoSharedDevices() throws {
    let config = try DaemonConfig(arguments: ["127.0.0.1", "127.0.0.1"])
    XCTAssertTrue(config.targets.isEmpty)
    XCTAssertEqual(USBServer(config: config).status().devices.count, 0)
  }
  func testAddingDevicePreservesExistingIdentityAndOrder() throws {
    let result = try addingConnectedDevice(fresh, inventory: [fresh], to: [first])
    XCTAssertEqual(result[0], first)
    XCTAssertEqual(result.count, 2)
    XCTAssertEqual(result[1].label, "USB21040313")
    XCTAssertTrue(result[1].matches(vendor: 0x2104, product: 0x0313, location: 999))
    XCTAssertEqual(Target(result[0], slot: 0).busID, "1-1")
    XCTAssertEqual(Target(result[1], slot: 1).busID, "1-2")
  }
  func testUnpluggedAndAmbiguousDeviceCannotBeAdded() {
    XCTAssertThrowsError(try addingConnectedDevice(fresh, inventory: [], to: [first]))
    let duplicate = LocalUSBDevice(
      vendor: "2104", product: "0313", location: "00009999", name: "Other", serial: "different")
    XCTAssertThrowsError(
      try addingConnectedDevice(fresh, inventory: [fresh, duplicate], to: [first]))
    XCTAssertThrowsError(
      try appendedDevice(
        LocalUSBDevice(
          vendor: "231d", product: "0201", location: "00005678", name: "Duplicate", serial: ""),
        to: [first]))
  }
  func testSavedCatalogRoundTripAndStartupMigration() throws {
    let catalog = try appendedDevice(fresh, to: [first])
    let decoded = try JSONDecoder().decode([TargetConfig].self, from: JSONEncoder().encode(catalog))
    XCTAssertEqual(decoded, catalog)
    XCTAssertNoThrow(try validateSavedTargets(decoded, base: [first]))
    XCTAssertNoThrow(try validateSavedTargets(decoded, base: []))
    XCTAssertThrowsError(try validateSavedTargets(Array(decoded.reversed()), base: [first]))
    XCTAssertThrowsError(try validateSavedTargets([], base: [first]))
  }
  func testReusedPortHintDoesNotReassignExistingDevice() throws {
    let device = LocalUSBDevice(
      vendor: "2104", product: "0313", location: "00001234", name: "EyeChip", serial: "")
    let catalog = try appendedDevice(device, to: [first])
    XCTAssertEqual(catalog[0], first)
    XCTAssertNotEqual(catalog[1].location, first.location)
    XCTAssertTrue(catalog[1].matches(vendor: 0x2104, product: 0x0313, location: 0x1234))
  }
  func testDeviceLimitAndInvalidIdentifiers() throws {
    let full = (0..<16).map {
      TargetConfig(vendor: UInt16($0 + 1), product: 1, location: UInt32($0), label: "DEV\($0)")
    }
    XCTAssertThrowsError(try appendedDevice(fresh, to: full))
    XCTAssertThrowsError(
      try appendedDevice(
        LocalUSBDevice(vendor: "nothex", product: "1", location: "1", name: "bad", serial: ""),
        to: []))
  }
  func testUnauthorizedAddCannotChangeCatalog() throws {
    let server = USBServer(config: try DaemonConfig(arguments: ["127.0.0.1", "127.0.0.1"]))
    XCTAssertFalse(
      server.handleControl(ControlRequest(action: "add", device: fresh), uid: UInt32.max).ok)
    XCTAssertTrue(server.status().devices.isEmpty)
  }
}
