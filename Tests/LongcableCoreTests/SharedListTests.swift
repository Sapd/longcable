// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import Foundation
import XCTest
@testable import LongcableCore

// GET /longcable/v1/shared on the USB/IP port: the Windows setup script asks the Mac
// which bus IDs it shares, including devices that are unplugged right now.
final class SharedListTests: XCTestCase {
  private var temporary: URL!
  private var store: StorePaths!
  private let left = TargetConfig(vendor: 0x231d, product: 0x0201, location: 0x1234, label: "LEFT")
  private let right = TargetConfig(vendor: 0x231d, product: 0x0200, location: 0x5678, label: "RIGHT")

  override func setUpWithError() throws {
    temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    store = StorePaths(targets: temporary.appendingPathComponent("targets.json").path,
      state: temporary.appendingPathComponent("sharing.json").path,
      launchDaemon: temporary.appendingPathComponent("service.plist").path)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

  private func server() throws -> USBServer {
    var args = ["127.0.0.1", "127.0.0.1"]
    for t in [left, right] {
      args += [String(t.vendor, radix: 16), String(t.product, radix: 16), String(t.location, radix: 16), t.label]
    }
    let s = USBServer(config: try DaemonConfig(arguments: args), store: store, consoleUID: { 501 },
      inventory: { [] }, log: { _ in })
    try s.loadPersistentState()
    return s
  }
  private func ask(_ s: USBServer, _ request: String) throws -> String { try ask(s, Data(request.utf8)) }
  private func ask(_ s: USBServer, _ request: Data) throws -> String {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw USBError.message("socketpair") }
    let serverSide = Connection(fds[0]), client = Connection(fds[1])
    XCTAssertTrue(serverSide.configureLocal()); XCTAssertTrue(client.configureLocal())
    XCTAssertTrue(client.write(request))
    s.handleClient(serverSide)
    serverSide.closeSocket()
    var out = Data()
    while let byte = client.read(1, timeoutMS: 500) { out.append(byte) }
    return String(decoding: out, as: UTF8.self)
  }
  private let request = "GET /longcable/v1/shared HTTP/1.0\r\nHost: mac\r\n\r\n"

  func testListsSharedDevicesEvenWhenUnpluggedAndTheMic() throws {
    let s = try server()
    XCTAssertTrue(s.handleControl(ControlRequest(action: "unshare", busID: "1-2"), uid: 501).ok)
    XCTAssertTrue(s.handleControl(ControlRequest(action: "virtual-mic", enabled: true), uid: 501).ok)
    let reply = try ask(s, request)
    XCTAssertTrue(reply.hasPrefix("HTTP/1.0 200 OK\r\n"), reply)
    let body = reply.components(separatedBy: "\r\n\r\n").last ?? ""
    XCTAssertEqual(body, "longcable 1\n1-1\n2-1\nend\n")
    XCTAssertTrue(reply.contains("Content-Length: \(body.utf8.count)\r\n"))
  }

  // AutoSync on Windows only acts when the same Mac answers at the address.
  func testReplyNamesThisMac() throws {
    let s = try server()
    let reply = try ask(s, request)
    XCTAssertTrue(reply.contains("\r\nX-Longcable-Id: \(VirtualMic.macSerial())\r\n"), reply)
    s.developmentOptions(alsoShared: [], noSharedList: false, sharedListID: "other-mac")
    XCTAssertTrue(try ask(s, request).contains("\r\nX-Longcable-Id: other-mac\r\n"))
  }

  func testNothingSharedIsAnExplicitEmptyList() throws {
    let s = try server()
    for bus in ["1-1", "1-2"] {
      XCTAssertTrue(s.handleControl(ControlRequest(action: "unshare", busID: bus), uid: 501).ok)
    }
    let reply = try ask(s, request)
    XCTAssertTrue(reply.hasSuffix("\r\n\r\nlongcable 1\nend\n"), reply)
  }

  func testOtherPathsAreNotFound() throws {
    let reply = try ask(try server(), "GET /etc/passwd HTTP/1.0\r\n\r\n")
    XCTAssertTrue(reply.hasPrefix("HTTP/1.0 404 Not Found\r\n"), reply)
    XCTAssertFalse(reply.contains("longcable 1"))
  }

  func testOversizedRequestGetsNoList() throws {
    let reply = try ask(try server(), "GET /longcable/v1/shared HTTP/1.0\r\n" + String(repeating: "X", count: 3000))
    XCTAssertFalse(reply.contains("200 OK"), reply)
  }

  func testUSBIPDeviceListStillWorks() throws {
    let reply = try ask(try server(), Data([1, 0x11, 0x80, 0x05, 0, 0, 0, 0]))
    XCTAssertTrue(reply.utf8.starts(with: [1, 0x11, 0, 5]), "OP_REP_DEVLIST")
  }
}
