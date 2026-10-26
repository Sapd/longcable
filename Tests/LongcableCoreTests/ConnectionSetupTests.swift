// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import Foundation
import XCTest
@testable import LongcableCore

final class ConnectionSetupTests: XCTestCase {
  func testAddressPreferenceAndMissingTailscale() {
    let addresses = ConnectionAddresses(tailscaleIP: "100.64.1.2", magicDNS: "mac.tail.ts.net.", lanIP: "192.168.1.2")
    XCTAssertTrue(addresses.prefersTailscale)
    XCTAssertEqual(addresses.address(tailscale: true), "mac.tail.ts.net")
    XCTAssertEqual(addresses.address(tailscale: false), "192.168.1.2")
    XCTAssertEqual(ConnectionAddresses(tailscaleIP: "100.64.1.2").address(tailscale: true), "100.64.1.2")
    XCTAssertFalse(ConnectionAddresses(lanIP: "192.168.1.2").prefersTailscale)
    XCTAssertNil(ConnectionAddresses().address(tailscale: true))
  }
  func testWindowsCommands() {
    XCTAssertEqual(ConnectionSetup.windowsQuick(server: "mac"), "irm https://github.com/Sapd/longcable/releases/latest/download/setup-windows.ps1 -OutFile $env:TEMP\\longcable-setup.ps1; & $env:TEMP\\longcable-setup.ps1 -Server 'mac'")
    XCTAssertEqual(ConnectionSetup.windowsManual(server: "mac", busIDs: ["1-1", "1-2"]), """
    $usbip = 'C:\\Program Files\\USBip\\usbip.exe'
    & $usbip list -r 'mac'
    & $usbip attach -r 'mac' -b '1-1' --receive-mode=low-latency
    & $usbip attach -r 'mac' -b '1-2' --receive-mode=low-latency
    & $usbip port --stash
    """)
  }
  func testWindowsDeviceCommandIncludesOnlyOneDevice() {
    XCTAssertEqual(ConnectionSetup.windowsDevice(server: "192.168.1.2", busID: "1-2"), """
    $usbip = 'C:\\Program Files\\USBip\\usbip.exe'
    & $usbip attach -r '192.168.1.2' -b '1-2' --receive-mode=low-latency
    & $usbip port --stash
    """)
  }
  func testWindowsDeviceCommandQuotesMagicDNSAndBusID() throws {
    let addresses = ConnectionAddresses(tailscaleIP: "100.64.1.2", magicDNS: "mac's.tail.ts.net.")
    let server = try XCTUnwrap(addresses.address(tailscale: addresses.prefersTailscale))
    XCTAssertEqual(ConnectionSetup.windowsDevice(server: server, busID: "1-'2").components(separatedBy: "\n")[1],
      "& $usbip attach -r 'mac''s.tail.ts.net' -b '1-''2' --receive-mode=low-latency")
  }
  func testWindowsDeviceCommandNetworkChoice() throws {
    let addresses = ConnectionAddresses(tailscaleIP: "100.64.1.2", magicDNS: "mac.tail.ts.net.", lanIP: "192.168.1.2")
    for (tailscale, expected) in [(addresses.prefersTailscale, "mac.tail.ts.net"), (false, "192.168.1.2")] {
      let server = try XCTUnwrap(addresses.address(tailscale: tailscale))
      XCTAssertTrue(ConnectionSetup.windowsDevice(server: server, busID: "1-1")
        .contains("attach -r '\(expected)' -b '1-1'"))
    }
    for addresses in [ConnectionAddresses(tailscaleIP: "100.64.1.2", lanIP: "192.168.1.2"),
      ConnectionAddresses(lanIP: "192.168.1.2")] {
      let server = try XCTUnwrap(addresses.address(tailscale: addresses.prefersTailscale))
      XCTAssertTrue(ConnectionSetup.windowsDevice(server: server, busID: "1-1")
        .contains("attach -r '\(addresses.tailscaleIP ?? "192.168.1.2")' -b '1-1'"))
    }
  }
  func testLinuxCommandsAndQuoting() {
    XCTAssertEqual(ConnectionSetup.linux(server: "192.168.1.2", busIDs: ["1-1"]), "sudo modprobe vhci-hcd\nusbip list -r '192.168.1.2'\nsudo usbip attach -r '192.168.1.2' -b '1-1'")
    XCTAssertTrue(ConnectionSetup.windowsQuick(server: "a'b").hasSuffix("-Server 'a''b'"))
    XCTAssertEqual(ConnectionSetup.linux(server: "a'b", busIDs: []), "sudo modprobe vhci-hcd\nusbip list -r 'a'\\''b'")
  }
}
final class PeerSetupTests: XCTestCase {
  var temporary: URL!
  var store: StorePaths!
  override func setUpWithError() throws {
    temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    store = StorePaths(targets: temporary.appendingPathComponent("targets.json").path,
      state: temporary.appendingPathComponent("sharing.json").path,
      launchDaemon: temporary.appendingPathComponent("job.plist").path)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }
  func address(_ value: String) -> in_addr {
    var result = in_addr(); XCTAssertEqual(inet_pton(AF_INET, value, &result), 1); return result
  }
  func server(console: @escaping () -> uid_t? = { 501 }) throws -> USBServer {
    USBServer(config: try DaemonConfig(arguments: ["0.0.0.0", "192.168.1.0/24"]), store: store,
      consoleUID: console, inventory: { [] }, log: { _ in })
  }
  func testCIDRBoundariesAndHostBits() throws {
    for (range, included, excluded) in [
      ("192.168.1.23/24", "192.168.1.255", "192.168.2.0"),
      ("100.64.0.0/10", "100.127.255.255", "100.128.0.0"),
      ("10.0.0.1/32", "10.0.0.1", "10.0.0.2")
    ] {
      let config = try DaemonConfig(arguments: ["0.0.0.0", range + ",127.0.0.1"])
      XCTAssertTrue(config.allowsPeer(address(included)))
      XCTAssertFalse(config.allowsPeer(address(excluded)))
      XCTAssertTrue(config.allowsPeer(address("127.0.0.1")))
      XCTAssertNil(config.securityWarning)
    }
    XCTAssertTrue(try IPv4Peer("0.0.0.0/0").contains(address("203.0.113.1")))
  }
  func testInvalidCIDRs() {
    for value in ["192.168.1.0/33", "192.168.1.0/-1", "1.2.3.4/", "1.2.3.4/1/2", "a/24", "any", "1.2.3.4/ 24"] {
      XCTAssertThrowsError(try IPv4Peer(value), value)
    }
  }
  func testPersistMergeForgetAndRestart() throws {
    let service = try server()
    try service.loadPersistentState()
    XCTAssertTrue(service.handleControl(ControlRequest(action: "allow-peer", peer: "100.64.0.0/10"), uid: 501).ok)
    XCTAssertTrue(service.handleControl(ControlRequest(action: "allow-peer", peer: "100.64.0.0/10"), uid: 501).ok)
    XCTAssertEqual(try savedPeers(at: store), ["100.64.0.0/10"])
    let restarted = try server(); try restarted.loadPersistentState()
    XCTAssertTrue(restarted.acceptPeer(address("100.64.2.3")))
    XCTAssertEqual(restarted.status().allowedPeers, ["192.168.1.0/24", "100.64.0.0/10"])
    XCTAssertTrue(restarted.handleControl(ControlRequest(action: "forget-peer", peer: "100.64.0.0/10"), uid: 0).ok)
    XCTAssertFalse(restarted.acceptPeer(address("100.64.2.3")))
    XCTAssertTrue(restarted.handleControl(ControlRequest(action: "forget-peer", peer: "192.168.1.0/24"), uid: 0).ok)
    XCTAssertTrue(restarted.acceptPeer(address("192.168.1.20")))
    XCTAssertEqual(try savedPeers(at: store), [])
  }
  func testPeerAuthorizationAndValidation() throws {
    for console: uid_t? in [501, nil, 0, UInt32.max] {
      let service = try server(console: { console })
      for action in ["allow-peer", "forget-peer"] {
        XCTAssertFalse(service.handleControl(ControlRequest(action: action, peer: "10.0.0.1"), uid: 502).ok)
        XCTAssertFalse(service.handleControl(ControlRequest(action: action, peer: "10.0.0.1"), uid: UInt32.max).ok)
        XCTAssertTrue(service.handleControl(ControlRequest(action: action, peer: "10.0.0.1"), uid: 0).ok)
      }
    }
    let service = try server()
    for peer in ["any", "bad", "1.2.3.4,5.6.7.8"] {
      XCTAssertFalse(service.handleControl(ControlRequest(action: "allow-peer", peer: peer), uid: 501).ok)
    }
  }
  func testWriteFailureDoesNotAllowPeer() throws {
    try FileManager.default.createDirectory(atPath: store.peers, withIntermediateDirectories: false)
    let service = try server()
    XCTAssertFalse(service.handleControl(ControlRequest(action: "allow-peer", peer: "10.0.0.1"), uid: 501).ok)
    XCTAssertFalse(service.acceptPeer(address("10.0.0.1")))
  }
  func testUnsafeAndCorruptPersistenceFailsClosed() throws {
    try savePeers(["10.0.0.1"], at: store)
    var info = stat(); XCTAssertEqual(lstat(store.peers, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o600)
    XCTAssertEqual(info.st_uid, geteuid())
    chmod(store.peers, 0o644)
    XCTAssertThrowsError(try server().loadPersistentState())
    chmod(store.peers, 0o600)
    try Data("bad json".utf8).write(to: URL(fileURLWithPath: store.peers))
    XCTAssertThrowsError(try server().loadPersistentState())
    try FileManager.default.removeItem(atPath: store.peers)
    try FileManager.default.createSymbolicLink(atPath: store.peers, withDestinationPath: store.state)
    XCTAssertThrowsError(try savedPeers(at: store))
  }
  func testRefusedHistoryBoundedDeduplicatedAndAllowClearsIt() throws {
    let service = try server()
    let now = Date(timeIntervalSince1970: 123)
    for n in 1...12 { XCTAssertFalse(service.acceptPeer(address("10.0.0.\(n)"), now: now)) }
    XCTAssertEqual(service.status().refusedPeers?.count, 10)
    XCTAssertFalse(service.acceptPeer(address("10.0.0.5"), now: now.addingTimeInterval(1)))
    XCTAssertEqual(service.status().refusedPeers?.first?.address, "10.0.0.5")
    XCTAssertEqual(service.status().refusedPeers?.first?.timestamp, now.addingTimeInterval(1))
    XCTAssertTrue(service.handleControl(ControlRequest(action: "allow-peer", peer: "10.0.0.0/24"), uid: 501).ok)
    XCTAssertEqual(service.status().refusedPeers?.count, 0)
    XCTAssertTrue(service.acceptPeer(address("10.0.0.5")))
    let data = try JSONEncoder().encode(service.status())
    XCTAssertNotNil(try JSONDecoder().decode(ServerStatus.self, from: data).refusedPeers)
  }
}
