// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import Foundation
import XCTest

@testable import LongcableCore

final class PersistenceAndControlTests: XCTestCase {
  private var temporary: URL!
  private var store: StorePaths!
  private let left = TargetConfig(vendor: 0x231d, product: 0x0201, location: 0x1234, label: "LEFT")
  private let right = TargetConfig(vendor: 0x231d, product: 0x0200, location: 0x5678, label: "RIGHT")
  private let extra = TargetConfig(vendor: 0x2104, product: 0x0313, location: 0x9999, label: "EYE")

  override func setUpWithError() throws {
    temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    store = StorePaths(targets: temporary.appendingPathComponent("targets.json").path,
      state: temporary.appendingPathComponent("sharing.json").path,
      launchDaemon: temporary.appendingPathComponent("service.plist").path)
  }
  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: temporary)
  }
  private func arguments(_ targets: [TargetConfig]) -> [String] {
    var result = ["127.0.0.1", "127.0.0.1"]
    for target in targets {
      result += [String(target.vendor, radix: 16), String(target.product, radix: 16),
        String(target.location, radix: 16), target.label]
    }
    return result
  }
  private func save<T: Encodable>(_ value: T, at path: String) throws {
    try JSONEncoder().encode(value).write(to: URL(fileURLWithPath: path), options: .atomic)
  }
  private func startup(_ arguments: [String]) throws {
    let plist = ["ProgramArguments": ["/isolated/test/daemon"] + arguments]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: URL(fileURLWithPath: store.launchDaemon))
  }
  private func server(_ config: DaemonConfig, console: @escaping () -> uid_t? = { 501 }) -> USBServer {
    USBServer(config: config, store: store, consoleUID: console, inventory: { [] }, log: { _ in })
  }
  private func pair() throws -> (Connection, Connection) {
    var descriptors: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
      throw USBError.message("socketpair failed")
    }
    let first = Connection(descriptors[0]), second = Connection(descriptors[1])
    XCTAssertTrue(first.configureLocal())
    XCTAssertTrue(second.configureLocal())
    return (first, second)
  }
  private func send(_ request: ControlRequest, on connection: Connection) throws {
    let payload = try JSONEncoder().encode(request)
    var header = Data(count: 4)
    header.put32(0, UInt32(payload.count))
    XCTAssertTrue(connection.write(header))
    XCTAssertTrue(connection.write(payload))
  }
  private func reply(from connection: Connection) throws -> ControlReply {
    let header = try XCTUnwrap(connection.read(4))
    let payload = try XCTUnwrap(connection.read(Int(header.u32(0))))
    return try JSONDecoder().decode(ControlReply.self, from: payload)
  }

  func testLegacyMigrationPreservesLocationIdentityAndDisabledState() throws {
    let oldArguments = ["127.0.0.1", "127.0.0.1", "231d", "0201", "1234"]
    let old = try DaemonConfig(arguments: oldArguments)
    try startup(oldArguments)
    try save(["1-1": false], at: store.state)
    let originalPlist = try Data(contentsOf: URL(fileURLWithPath: store.launchDaemon))
    let network = try DaemonConfig(arguments: arguments([]))
    XCTAssertEqual(try preflightInstall(config: network, store: store), old.targets)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.targets))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.launchDaemon)), originalPlist)
    try preserveStartupDevices(store: store)
    XCTAssertEqual(try savedTargets(at: store), old.targets)
    let migrated = server(network)
    try migrated.loadPersistentState()
    let target = try XCTUnwrap(migrated.targets.first)
    XCTAssertEqual(target.busID, "1-1")
    XCTAssertEqual(target.config.label, "")
    XCTAssertFalse(target.isEnabled)
    XCTAssertTrue(target.config.matches(vendor: 0x231d, product: 0x0201, location: 0x1234))
    XCTAssertFalse(target.config.matches(vendor: 0x231d, product: 0x0201, location: 0x5678))
  }

  func testNamedDeviceCanBeAppendedToMigratedLegacyCatalog() throws {
    let old = try DaemonConfig(arguments: ["127.0.0.1", "127.0.0.1", "231d", "0201", "1234"])
    let fresh = LocalUSBDevice(vendor: "2104", product: "0313", location: "00005678", name: "Eye", serial: "")
    let extended = try appendedDevice(fresh, to: old.targets)
    try save(extended, at: store.targets)
    let restored = server(try DaemonConfig(arguments: arguments([])))
    try restored.loadPersistentState()
    XCTAssertEqual(restored.targets.map { $0.config }, extended)
    XCTAssertEqual(restored.targets.map { $0.busID }, ["1-1", "1-2"])
    XCTAssertEqual(restored.targets[0].config, old.targets[0])
  }

  func testExplicitAppendPreservesSavedSlotsAndNetworkOnlyRestartKeepsAllTargets() throws {
    try startup(arguments([left]))
    try save([left, right], at: store.targets)
    try save(["LEFT": false, "RIGHT": true], at: store.state)
    let original = try Data(contentsOf: URL(fileURLWithPath: store.targets))
    let extended = try DaemonConfig(arguments: arguments([left, right, extra]))
    XCTAssertEqual(try preflightInstall(config: extended, store: store), [left, right, extra])
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.targets)), original)
    let configured = server(extended)
    try configured.loadPersistentState()
    XCTAssertEqual(configured.targets.map { $0.busID }, ["1-1", "1-2", "1-3"])
    XCTAssertEqual(configured.targets.map { $0.config }, [left, right, extra])
    XCTAssertFalse(configured.targets[0].isEnabled)
    XCTAssertTrue(configured.targets[1].isEnabled)
    let networkOnly = server(try DaemonConfig(arguments: arguments([])))
    try networkOnly.loadPersistentState()
    XCTAssertEqual(networkOnly.targets.map { $0.config }, [left, right, extra])
    XCTAssertEqual(networkOnly.targets.map { $0.wireID }, [0x10001, 0x10002, 0x10003])
    XCTAssertFalse(networkOnly.targets[0].isEnabled)
  }

  func testPreflightRejectsReorderAndChangedSlotsWithoutModifyingExistingFiles() throws {
    try startup(arguments([left]))
    try save([left, right], at: store.targets)
    try save(["LEFT": false], at: store.state)
    let before = try [store.targets, store.state, store.launchDaemon].map {
      try Data(contentsOf: URL(fileURLWithPath: $0))
    }
    for targets in [[right, left], [left, extra]] {
      let configuration = try DaemonConfig(arguments: arguments(targets))
      XCTAssertThrowsError(try preflightInstall(config: configuration, store: store))
      XCTAssertThrowsError(try server(configuration).loadPersistentState())
    }
    let after = try [store.targets, store.state, store.launchDaemon].map {
      try Data(contentsOf: URL(fileURLWithPath: $0))
    }
    XCTAssertEqual(after, before)
  }

  func testCorruptSharingSettingsRefuseStartupAndPreflightWithoutCatalogMutation() throws {
    let config = try DaemonConfig(arguments: arguments([left]))
    try startup(arguments([left]))
    for invalid in [Data("not json".utf8), Data("{\"LEFT\":\"false\"}".utf8)] {
      try invalid.write(to: URL(fileURLWithPath: store.state))
      let service = server(config)
      XCTAssertThrowsError(try service.loadPersistentState()) { error in
        XCTAssertTrue(String(describing: error).contains("sharing settings"))
      }
      XCTAssertEqual(service.listener, -1)
      XCTAssertThrowsError(try preflightInstall(config: config, store: store))
      XCTAssertThrowsError(try preserveStartupDevices(store: store))
      XCTAssertFalse(FileManager.default.fileExists(atPath: store.targets))
      XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: store.state)), invalid)
    }
  }

  func testExistingUnreadableSharingSettingsDoNotFallBackToEnabledDefaults() throws {
    // A dangling symlink exists but cannot be read, even when tests run as root.
    try FileManager.default.createSymbolicLink(atPath: store.state,
      withDestinationPath: temporary.appendingPathComponent("missing-preferences").path)
    let service = server(try DaemonConfig(arguments: arguments([left])))
    XCTAssertThrowsError(try service.loadPersistentState()) { error in
      XCTAssertTrue(String(describing: error).contains("sharing settings"))
    }
    XCTAssertEqual(service.listener, -1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.targets))
  }

  func testAuthorizedUnshareWriteFailureKeepsEnabledStateAndConnection() throws {
    try FileManager.default.createDirectory(atPath: store.state, withIntermediateDirectories: false)
    let service = server(try DaemonConfig(arguments: arguments([left])))
    let target = try XCTUnwrap(service.targets.first)
    let (daemon, client) = try pair()
    XCTAssertTrue(target.begin(daemon))
    let response = service.handleControl(ControlRequest(action: "unshare", busID: "1-1"), uid: 501)
    XCTAssertFalse(response.ok)
    XCTAssertTrue(response.message.contains("Could not save sharing settings"))
    XCTAssertTrue(target.isEnabled)
    XCTAssertTrue(daemon.write(Data([7])))
    XCTAssertEqual(client.read(1), Data([7]))
  }

  func testAuthorizedUnsharePersistsAndRestoresDisabledState() throws {
    let config = try DaemonConfig(arguments: arguments([left, right]))
    let service = server(config)
    try service.loadPersistentState()
    let (daemon, client) = try pair()
    XCTAssertTrue(service.targets[0].begin(daemon))
    let response = service.handleControl(ControlRequest(action: "unshare", busID: "1-1"), uid: 501)
    XCTAssertTrue(response.ok)
    XCTAssertNil(client.read(1))
    XCTAssertEqual(try savedSharing(at: store), ["LEFT": false, "RIGHT": true])
    let restarted = server(config)
    try restarted.loadPersistentState()
    XCTAssertFalse(restarted.targets[0].isEnabled)
    XCTAssertTrue(restarted.targets[1].isEnabled)
  }

  func testAuthorizedAddPersistsAppendAndRestoresExistingIdentity() throws {
    let fresh = LocalUSBDevice(vendor: "2104", product: "0313", location: "00009999", name: "Eye", serial: "")
    try save([left], at: store.targets)
    try save(["LEFT": false], at: store.state)
    let network = try DaemonConfig(arguments: arguments([]))
    let service = USBServer(config: network, store: store, consoleUID: { 501 },
      inventory: { [fresh] }, log: { _ in })
    try service.loadPersistentState()
    let response = service.handleControl(ControlRequest(action: "add", device: fresh), uid: 501)
    XCTAssertTrue(response.ok)
    let appended = service.targets.map { $0.config }
    XCTAssertEqual(appended.first, left)
    XCTAssertEqual(appended.count, 2)
    XCTAssertEqual(try savedTargets(at: store), appended)
    let restarted = server(network)
    try restarted.loadPersistentState()
    XCTAssertEqual(restarted.targets.map { $0.config }, appended)
    XCTAssertEqual(restarted.targets.map { $0.busID }, ["1-1", "1-2"])
    XCTAssertFalse(restarted.targets[0].isEnabled)
  }

  func testAuthorizedAddWriteFailureDoesNotAppendRunningCatalog() throws {
    let fresh = LocalUSBDevice(vendor: "2104", product: "0313", location: "00009999", name: "Eye", serial: "")
    try FileManager.default.createDirectory(atPath: store.targets, withIntermediateDirectories: false)
    let service = USBServer(config: try DaemonConfig(arguments: arguments([left])), store: store,
      consoleUID: { 501 }, inventory: { [fresh] }, log: { _ in })
    let response = service.handleControl(ControlRequest(action: "add", device: fresh), uid: 501)
    XCTAssertFalse(response.ok)
    XCTAssertEqual(service.targets.map { $0.config }, [left])
    XCTAssertEqual(service.targets.map { $0.busID }, ["1-1"])
  }

  func testFramedSocketUsesKernelPeerUIDAndRejectsNonConsoleUser() throws {
    guard geteuid() != 0 else { throw XCTSkip("The root peer is legitimately authorized") }
    let service = server(try DaemonConfig(arguments: arguments([left])), console: { geteuid() + 1 })
    let (daemon, client) = try pair()
    try send(ControlRequest(action: "unshare", busID: "1-1"), on: client)
    var observed: uid_t?
    ControlServer.serve(daemon) { request, uid in
      observed = uid
      return service.handleControl(request, uid: uid)
    }
    XCTAssertEqual(observed, geteuid())
    let response = try reply(from: client)
    XCTAssertFalse(response.ok)
    XCTAssertTrue(response.message.contains("signed-in Mac user"))
    XCTAssertTrue(service.targets[0].isEnabled)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.state))
  }

  func testPeerControlsUseAuthenticatedSocketIdentity() throws {
    let service = server(try DaemonConfig(arguments: arguments([])))
    for (uid, action, expected) in [(uid_t(502), "allow-peer", false), (501, "allow-peer", true),
                                   (502, "forget-peer", false), (0, "forget-peer", true)] {
      let (daemon, client) = try pair()
      defer { daemon.closeSocket(); client.closeSocket() }
      try send(ControlRequest(action: action, peer: "10.0.0.1"), on: client)
      ControlServer.serve(daemon, peerUID: { _ in uid }) { request, authenticatedUID in
        service.handleControl(request, uid: authenticatedUID)
      }
      XCTAssertEqual(try reply(from: client).ok, expected)
    }
    XCTAssertEqual(try savedPeers(at: store), [])
  }

  func testCredentialLookupFailureNeverDispatchesFramedRequest() throws {
    let (daemon, client) = try pair()
    try send(ControlRequest(action: "unshare", busID: "1-1"), on: client)
    ControlServer.serve(daemon, peerUID: { _ in nil }) { _, _ in
      XCTFail("Unauthenticated request reached the control handler")
      return ControlReply(ok: true, message: "unexpected", status: nil)
    }
    daemon.closeSocket()
    XCTAssertNil(client.read(1))
  }

  func testMissingConsoleIdentityNeverAuthorizesSentinelUID() throws {
    let config = try DaemonConfig(arguments: arguments([left]))
    for identity: uid_t? in [nil, UInt32.max, 0] {
      let service = server(config, console: { identity })
      XCTAssertFalse(service.handleControl(ControlRequest(action: "reconnect", busID: "1-1"), uid: UInt32.max).ok)
      XCTAssertTrue(service.handleControl(ControlRequest(action: "reconnect", busID: "1-1"), uid: 0).ok)
    }
  }
}
