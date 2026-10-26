// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation
import XCTest
@testable import LongcableCore

final class IdenticalDeviceTests: XCTestCase {
  private func target(_ port: UInt32, _ label: String) -> TargetConfig {
    TargetConfig(vendor: 0x231d, product: 0x201, location: port, label: label)
  }
  private func device(_ port: UInt32, serial: String = "") -> LocalUSBDevice {
    LocalUSBDevice(vendor: "231d", product: "0201", location: String(format: "%08x", port),
      name: "Stick", serial: serial)
  }
  private func arguments(_ secondPort: String = "2", label: String = "RIGHT") -> [String] {
    ["127.0.0.1", "127.0.0.1", "231d", "0201", "1", "LEFT",
     "231d", "0201", secondPort, label]
  }
  func testConfigAndSavedCatalogAcceptDistinctPorts() throws {
    let catalog = try DaemonConfig(arguments: arguments()).targets
    XCTAssertEqual(catalog, [target(1, "LEFT"), target(2, "RIGHT")])
    let decoded = try JSONDecoder().decode([TargetConfig].self, from: JSONEncoder().encode(catalog))
    XCTAssertNoThrow(try validateSavedTargets(decoded, base: catalog))
    XCTAssertEqual(try reconciledTargets(saved: decoded, startup: catalog), catalog)
  }
  func testConfigAndSavedCatalogRejectExactDuplicatesAndLabels() {
    XCTAssertThrowsError(try DaemonConfig(arguments: arguments("1")))
    XCTAssertThrowsError(try DaemonConfig(arguments: arguments(label: "LEFT")))
    XCTAssertThrowsError(try validateSavedTargets([target(1, "LEFT"), target(1, "RIGHT")], base: []))
    XCTAssertThrowsError(try validateSavedTargets([target(1, "LEFT"), target(2, "LEFT")], base: []))
  }
  func testMatchingUsesEachPortEvenWithReversedInventory() {
    let catalog = [target(1, "LEFT"), target(2, "RIGHT")]
    let devices = [device(2), device(1)]
    for config in catalog {
      let match = resolvedTarget(config, configured: catalog, devices: devices)
      XCTAssertEqual(match.portBound, true)
      XCTAssertEqual(devices.filter { match.matches($0) }.map { $0.location },
                     [String(format: "%08x", config.location)])
    }
  }
  func testConfiguredPairStaysPinnedWithOnlyOneConnected() {
    let catalog = [target(1, "LEFT"), target(2, "RIGHT")]
    let moved = device(3)
    for config in catalog {
      XCTAssertFalse(resolvedTarget(config, configured: catalog, devices: [moved]).matches(moved))
    }
  }
  func testIdentityCacheNeverSwapsDevicesAndClearsMovedTarget() {
    let catalog = [target(1, "LEFT"), target(2, "RIGHT")]
    var devices = [device(1), device(2)]
    var loads = [String: Int]()
    let targets = catalog.enumerated().map { index, config in
      Target(config, slot: index, context: { (catalog, devices) }, registryIdentity: { match in
        devices.first(where: { match.matches($0) }).flatMap { UInt64($0.location, radix: 16) }
      }, identityLoader: { match, bus, _ in
        loads[bus, default: 0] += 1
        var record = Data(count: 312)
        record.putString(256, 32, bus)
        return Identity(record: record, classes: Data(), configuration: 1,
          overlaySerial: true, name: "Stick", serial: match.label,
          registryID: UInt64(match.location))
      })
    }
    targets.forEach { XCTAssertTrue($0.ensureIdentity()) }
    devices.reverse()
    targets.forEach { XCTAssertTrue($0.ensureIdentity()) }
    XCTAssertEqual(loads, ["1-1": 1, "1-2": 1])
    XCTAssertEqual(targets.map { $0.identity?.serial }, ["LEFT", "RIGHT"])
    devices = [device(3), device(2)]
    XCTAssertFalse(targets[0].ensureIdentity())
    XCTAssertNil(targets[0].identity)
    XCTAssertTrue(targets[1].ensureIdentity())
    XCTAssertEqual(targets[1].identity?.registryID, 2)
    XCTAssertEqual(targets.map { $0.busID }, ["1-1", "1-2"])
  }
  func testUniqueSeriallessDeviceStillFollowsPorts() {
    let config = target(1, "LEFT")
    let match = resolvedTarget(config, configured: [config], devices: [device(3)])
    XCTAssertTrue(match.matches(device(3)))
    XCTAssertNotEqual(match.portBound, true)
    var devices = [device(1)]
    var loads = 0
    let cached = Target(config, slot: 0, context: { ([config], devices) },
      registryIdentity: { match in
        devices.first(where: { match.matches($0) }).flatMap { UInt64($0.location, radix: 16) }
      }, identityLoader: { _, _, _ in
        loads += 1
        return Identity(record: Data(), classes: Data(), configuration: 1,
          overlaySerial: true, name: "Stick", serial: "LEFT")
      })
    XCTAssertTrue(cached.ensureIdentity())
    devices = [device(3)]
    XCTAssertTrue(cached.ensureIdentity())
    XCTAssertEqual(loads, 2)
    XCTAssertEqual(cached.identity?.serial, "LEFT")
    XCTAssertEqual(cached.busID, "1-1")
  }
  func testSerialDeviceFollowsItsSerialAmongIdenticalModels() {
    let catalog = [target(1, "LEFT"), target(2, "RIGHT")]
    let initial = [device(1, serial: "A"), device(2, serial: "B")]
    let learned = catalog.map { resolvedTarget($0, configured: catalog, devices: initial) }
    let moved = [device(4, serial: "B"), device(3, serial: "A")]
    for (index, config) in learned.enumerated() {
      let match = resolvedTarget(config, configured: catalog, devices: moved)
      XCTAssertEqual(moved.filter { match.matches($0) }.map { $0.serial }, [index == 0 ? "A" : "B"])
      XCTAssertNotEqual(match.portBound, true)
    }
  }
  func testConnectedDuplicatePinsSingleConfiguredTargetAndDoesNotGuessLater() {
    let config = target(1, "LEFT")
    let match = resolvedTarget(config, configured: [config], devices: [device(1), device(2)])
    XCTAssertTrue(match.matches(device(1)))
    XCTAssertFalse(match.matches(device(2)))
    XCTAssertFalse(resolvedTarget(match, configured: [config], devices: [device(3)]).matches(device(3)))
  }
  func testControlAddPinsSecondDeviceAndShowsMovedDeviceAsAvailable() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = StorePaths(targets: directory.appendingPathComponent("targets.json").path,
      state: directory.appendingPathComponent("state.json").path,
      launchDaemon: directory.appendingPathComponent("service.plist").path)
    var devices = [device(1), device(2)]
    let server = USBServer(config: try DaemonConfig(arguments: Array(arguments().prefix(6))),
      store: store, consoleUID: { 501 }, inventory: { devices }, log: { _ in })
    let reply = server.handleControl(ControlRequest(action: "add", device: device(2)), uid: 501)
    XCTAssertTrue(reply.ok, reply.message)
    XCTAssertEqual(server.targets.map { $0.config.location }, [1, 2])
    XCTAssertEqual(server.targets.map { $0.busID }, ["1-1", "1-2"])
    XCTAssertEqual(Set(server.targets.map { $0.config.label }).count, 2)
    XCTAssertTrue(server.status().availableDevices?.isEmpty == true)
    devices = [device(1), device(3)]
    let status = server.status()
    XCTAssertEqual(status.devices[1].state, "Not plugged in")
    XCTAssertTrue(status.devices[1].lastError?.contains("bound to its USB port") == true)
    XCTAssertEqual(status.availableDevices?.map { $0.location }, [device(3).location])
    XCTAssertFalse(server.handleControl(ControlRequest(action: "add", device: device(2)), uid: 501).ok)
    XCTAssertEqual(try savedTargets(at: store)?.count, 2)
    try server.loadPersistentState()
    XCTAssertEqual(server.targets.map { $0.busID }, ["1-1", "1-2"])
    XCTAssertEqual(server.status().devices[1].state, "Not plugged in")
    XCTAssertEqual(server.status().availableDevices?.map { $0.location }, [device(3).location])
  }
}
