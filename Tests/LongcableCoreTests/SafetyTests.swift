// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import XCTest
@testable import LongcableCore

final class SafetyTests: XCTestCase {
  let apple = LocalUSBDevice(vendor: "05ac", product: "1234", location: "00005678", name: "Internal", serial: "")
  let explicit = TargetConfig(vendor: 0x05ac, product: 0x1234, location: 0x5678, label: "APPLE")
  func testAppleHiddenUnlessExactConfiguredTriple() {
    XCTAssertTrue(visibleDevices([apple], configured: []).isEmpty)
    XCTAssertEqual(visibleDevices([apple], configured: [explicit]).count, 1)
    XCTAssertFalse(deviceMayBeShared(vendor: 0x05ac, product: 0x1235, location: 0x5678, configured: [explicit]))
    XCTAssertFalse(deviceMayBeShared(vendor: 0x05ac, product: 0x1234, location: 0x5679, configured: [explicit]))
    XCTAssertTrue(deviceMayBeShared(vendor: 0x231d, product: 0x201, location: 99, configured: []))
  }
  func testAppleCannotBeAddedThroughGUIOrControl() throws {
    XCTAssertThrowsError(try appendedDevice(apple, to: []))
    let server = USBServer(config: try DaemonConfig(arguments: ["127.0.0.1", "127.0.0.1"]),
      store: .live, consoleUID: { 501 }, inventory: { [self.apple] }, log: { _ in })
    XCTAssertTrue(server.status().availableDevices?.isEmpty == true)
    XCTAssertFalse(server.handleControl(ControlRequest(action: "add", device: apple), uid: 501).ok)
    XCTAssertTrue(server.targets.isEmpty)
  }
  func testAppleCaptureMatchRemainsLocationPinnedEvenWithLabel() throws {
    let config = try DaemonConfig(arguments: ["0.0.0.0", "127.0.0.1", "05ac", "1234", "5678", "APPLE"])
    XCTAssertTrue(config.targets[0].matches(vendor: 0x05ac, product: 0x1234, location: 0x5678))
    XCTAssertFalse(config.targets[0].matches(vendor: 0x05ac, product: 0x1234, location: 0x5679))
  }
  func accepted(_ config: DaemonConfig, _ ip: String) -> Bool {
    var address = in_addr()
    XCTAssertEqual(inet_pton(AF_INET, ip, &address), 1)
    return config.allowsPeer(address)
  }
  func testWildcardListenWithAllowlist() throws {
    let config = try DaemonConfig(arguments: ["0.0.0.0", "192.168.1.2,100.86.73.38"])
    XCTAssertTrue(accepted(config, "192.168.1.2"))
    XCTAssertTrue(accepted(config, "100.86.73.38"))
    XCTAssertFalse(accepted(config, "192.168.1.3"))
    XCTAssertNil(config.securityWarning)
  }
  func testStrictSinglePeerStillWorks() throws {
    let config = try DaemonConfig(arguments: ["127.0.0.1", "127.0.0.2"])
    XCTAssertTrue(accepted(config, "127.0.0.2"))
    XCTAssertFalse(accepted(config, "127.0.0.1"))
  }
  func testAnyPeerHasLoudWarning() throws {
    let config = try DaemonConfig(arguments: ["0.0.0.0", "any"])
    XCTAssertTrue(accepted(config, "192.168.1.99"))
    XCTAssertTrue(config.securityWarning?.contains("WARNING") == true)
    XCTAssertTrue(config.securityWarning?.contains("NO AUTHENTICATION") == true)
  }
  func testInvalidPeerListsRejected() {
    for peers in ["", "0.0.0.0", "255.255.255.255", "any,127.0.0.1", "127.0.0.1,", ",127.0.0.1", "127.0.0.1,127.0.0.1", "::1", "host", "127.0.0.1, 127.0.0.2"] {
      XCTAssertThrowsError(try DaemonConfig(arguments: ["0.0.0.0", peers]), peers)
    }
    XCTAssertThrowsError(try DaemonConfig(arguments: ["invalid", "any"]))
  }
}
