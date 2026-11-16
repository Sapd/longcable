// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import Foundation
import XCTest
@testable import LongcableCore

final class VirtualMicServerTests: XCTestCase {
  private var temporary: URL!
  private var store: StorePaths!
  private var streaming = [Bool]()
  private let left = TargetConfig(vendor: 0x231d, product: 0x0201, location: 0x1234, label: "LEFT")

  override func setUpWithError() throws {
    temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    store = StorePaths(targets: temporary.appendingPathComponent("targets.json").path,
      state: temporary.appendingPathComponent("sharing.json").path,
      launchDaemon: temporary.appendingPathComponent("service.plist").path)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

  private func server(targets: [TargetConfig] = [], console: @escaping () -> uid_t? = { 501 }) throws -> USBServer {
    var args = ["127.0.0.1", "127.0.0.1"]
    for t in targets {
      args += [String(t.vendor, radix: 16), String(t.product, radix: 16), String(t.location, radix: 16), t.label]
    }
    let s = USBServer(config: try DaemonConfig(arguments: args), store: store, consoleUID: console,
      inventory: { [] }, log: { _ in },
      makeMicDevice: { [unowned self] buffer, serial, onStreaming in
        VirtualMicTransport(buffer: buffer, serial: serial, clock: { 0 }, startTimer: false,
          onStreaming: { value in self.streaming.append(value); onStreaming(value) })
      })
    try s.loadPersistentState()
    return s
  }
  private func pair() throws -> (Connection, Connection) {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw USBError.message("socketpair") }
    let a = Connection(fds[0]), b = Connection(fds[1])
    XCTAssertTrue(a.configureLocal()); XCTAssertTrue(b.configureLocal())
    return (a, b)
  }
  private func devlist(_ s: USBServer) throws -> [Data] {
    let (serverSide, client) = try pair()
    XCTAssertTrue(client.write(Data([1, 0x11, 0x80, 0x05, 0, 0, 0, 0])))
    s.handleClient(serverSide)
    serverSide.closeSocket()
    let header = try XCTUnwrap(client.read(8))
    XCTAssertEqual(Array(header[0..<4]), [1, 0x11, 0, 5])
    let count = try XCTUnwrap(client.read(4)).u32(0)
    return try (0..<Int(count)).map { _ in
      let record = try XCTUnwrap(client.read(312))
      _ = try XCTUnwrap(client.read(Int(record[311]) * 4))
      return record
    }
  }
  private func toggle(_ s: USBServer, _ enabled: Bool, uid: uid_t = 501) -> ControlReply {
    s.handleControl(ControlRequest(action: "virtual-mic", enabled: enabled), uid: uid)
  }
  private func busID(_ record: Data) -> String {
    String(decoding: record[256..<288].prefix { $0 != 0 }, as: UTF8.self)
  }

  func testOffByDefaultDevlistUnchanged() throws {
    let s = try server()
    XCTAssertEqual(try devlist(s).count, 0)
    XCTAssertEqual(s.status().virtualMic?.enabled, false)
    XCTAssertEqual(s.status().virtualMic?.state, "Off")
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.virtualMic))
  }

  func testEnableListsBus21WithVirtualRecord() throws {
    let s = try server()
    let reply = toggle(s, true)
    XCTAssertTrue(reply.ok, reply.message)
    XCTAssertEqual(reply.status?.virtualMic?.state, "Waiting for Windows")
    let records = try devlist(s)
    XCTAssertEqual(records.map(busID), ["2-1"])
    XCTAssertEqual(Array(records[0][300..<304]), [0x12, 0x09, 0x00, 0x01])
    XCTAssertFalse(s.status().devices.contains { $0.id == "2-1" }, "not a DeviceCard")
  }

  func testFlagPersistsAcrossRestart() throws {
    XCTAssertTrue(toggle(try server(), true).ok)
    XCTAssertEqual(try server().status().virtualMic?.enabled, true)
    XCTAssertTrue(toggle(try server(), false).ok)
    XCTAssertEqual(try server().status().virtualMic?.enabled, false)
  }

  func testCorruptFlagFileMeansOffNotStartupFailure() throws {
    try Data("{nope".utf8).write(to: URL(fileURLWithPath: store.virtualMic))
    XCTAssertEqual(try server().status().virtualMic?.enabled, false)
  }

  func testSharingRewriteKeepsVirtualMicFlag() throws {
    let s = try server(targets: [left])
    XCTAssertTrue(toggle(s, true).ok)
    let reply = s.handleControl(ControlRequest(action: "unshare", busID: "1-1"), uid: 501)
    XCTAssertTrue(reply.ok, reply.message)
    XCTAssertEqual(try server(targets: [left]).status().virtualMic?.enabled, true)
  }

  func testOnlySignedInUserCanToggle() throws {
    let s = try server()
    XCTAssertFalse(toggle(s, true, uid: 777).ok)
    XCTAssertEqual(s.status().virtualMic?.enabled, false)
    XCTAssertFalse(s.handleControl(ControlRequest(action: "virtual-mic"), uid: 501).ok, "enabled is required")
  }

  func testDisablingTearsDownLiveSession() throws {
    let s = try server()
    XCTAssertTrue(toggle(s, true).ok)
    let (serverSide, client) = try pair()
    var importRequest = Data([1, 0x11, 0x80, 0x03, 0, 0, 0, 0])
    var bus = Data(count: 32); bus.putString(0, 32, "2-1")
    importRequest.append(bus)
    XCTAssertTrue(client.write(importRequest))
    let done = expectation(description: "session ended")
    DispatchQueue.global().async { s.handleClient(serverSide); serverSide.closeSocket(); done.fulfill() }
    let header = try XCTUnwrap(client.read(8))
    XCTAssertEqual(header.u32(4), 0, "import accepted")
    let record = try XCTUnwrap(client.read(312))
    XCTAssertEqual(busID(record), "2-1")
    // SET_INTERFACE 1 alt 1 starts streaming.
    var h = Data(count: 48)
    h.put32(0, 1); h.put32(4, 1); h.put32(8, VirtualMic.wireID)
    h.replaceSubrange(40..<48, with: [0x01, 11, 1, 0, 1, 0, 0, 0])
    XCTAssertTrue(client.write(h))
    XCTAssertEqual(try XCTUnwrap(client.read(48)).u32(20), 0)
    XCTAssertEqual(s.status().virtualMic?.state, "Windows is listening")
    XCTAssertTrue(toggle(s, false).ok)
    wait(for: [done], timeout: 5)
    XCTAssertEqual(streaming, [true, false])
    XCTAssertEqual(s.status().virtualMic?.state, "Off")
    XCTAssertEqual(try devlist(s).count, 0)
  }

  func testReconnectMicWhenOffIsRefused() throws {
    let s = try server()
    let reply = s.handleControl(ControlRequest(action: "reconnect", busID: "2-1"), uid: 501)
    XCTAssertFalse(reply.ok)
    XCTAssertEqual(reply.message, "Longcable Mic is off")
    XCTAssertFalse(s.handleControl(ControlRequest(action: "reconnect", busID: "2-1"), uid: 777).ok)
  }

  func testReconnectMicDropsLiveSession() throws {
    let s = try server()
    XCTAssertTrue(toggle(s, true).ok)
    let (serverSide, client) = try pair()
    var importRequest = Data([1, 0x11, 0x80, 0x03, 0, 0, 0, 0])
    var bus = Data(count: 32); bus.putString(0, 32, "2-1")
    importRequest.append(bus)
    XCTAssertTrue(client.write(importRequest))
    let done = expectation(description: "session ended")
    DispatchQueue.global().async { s.handleClient(serverSide); serverSide.closeSocket(); done.fulfill() }
    XCTAssertEqual(try XCTUnwrap(client.read(8)).u32(4), 0)
    _ = try XCTUnwrap(client.read(312))
    let reply = s.handleControl(ControlRequest(action: "reconnect", busID: "2-1"), uid: 501)
    XCTAssertTrue(reply.ok, reply.message)
    wait(for: [done], timeout: 5)
    XCTAssertEqual(s.status().virtualMic?.enabled, true, "reconnect keeps it on")
  }

  // The test server must not look like the installed one to Windows, or both
  // claim the same USB identity when attached side by side.
  func testDevelopmentServerHasItsOwnSerial() throws {
    let dev = USBServer.virtualMicDevelopment(config: try DaemonConfig(arguments: ["127.0.0.1", "127.0.0.1"]))
    let serial = try XCTUnwrap(dev.virtualMic.identity?.serial)
    XCTAssertNotEqual(serial, VirtualMic.macSerial())
    XCTAssertEqual(serial, VirtualMic.macSerial() + "-test")
  }

  func testImportRefusedWhileDisabled() throws {
    let s = try server()
    let (serverSide, client) = try pair()
    var importRequest = Data([1, 0x11, 0x80, 0x03, 0, 0, 0, 0])
    var bus = Data(count: 32); bus.putString(0, 32, "2-1")
    importRequest.append(bus)
    XCTAssertTrue(client.write(importRequest))
    s.handleClient(serverSide)
    serverSide.closeSocket()
    XCTAssertEqual(try XCTUnwrap(client.read(8)).u32(4), 1)
  }
}
