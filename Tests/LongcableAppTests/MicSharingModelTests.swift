// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation
import LongcableMicCapture
import XCTest
@testable import Longcable

final class FakeFeeder: MicFeeding {
  var onListening: ((Bool) -> Void)?
  var onError: ((String?) -> Void)?
  var running = false
  func start(deviceUID: String?) { running = true }
  func stop() { running = false }
  func change(deviceUID: String?) {}
}

@MainActor final class FakeService {
  var reply: MicServiceReply = .ok
  var sent = [Bool]()
  func send(_ on: Bool) async -> MicServiceReply { sent.append(on); return reply }
}

@MainActor final class MicSharingModelTests: XCTestCase {
  // Each test gets its own settings, removed again afterwards (they would otherwise
  // pile up in ~/Library/Preferences).
  private var suites = [String]()
  override func tearDown() async throws {
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
    for name in suites {
      // Flush, then delete. (Clearing the domain first makes cfprefsd write an
      // empty file back later.)
      CFPreferencesSynchronize(name as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name + ".plist"))
    }
    suites.removeAll()
  }
  private func defaults(enabled: Bool) -> UserDefaults {
    let name = "longcable-test-\(UUID().uuidString)"
    suites.append(name)
    let d = UserDefaults(suiteName: name)!
    d.set(enabled, forKey: "virtualMicEnabled")
    return d
  }
  private func model(_ feeder: FakeFeeder, _ service: FakeService, enabled: Bool,
                     permission: Bool = true) -> MicSharingModel {
    MicSharingModel(feeder: feeder, defaults: defaults(enabled: enabled),
      send: { await service.send($0) }, permission: { permission })
  }

  // The service could not be told to turn the mic off: the app must keep feeding
  // it and keep showing "on", or Windows keeps a mic that nobody feeds.
  func testRefusedTurnOffKeepsFeeding() async {
    let feeder = FakeFeeder(), service = FakeService()
    let m = model(feeder, service, enabled: false)
    await m.apply(true)
    XCTAssertTrue(m.enabled); XCTAssertTrue(feeder.running)
    service.reply = .refused("busy")
    await m.apply(false)
    XCTAssertTrue(m.enabled)
    XCTAssertTrue(feeder.running)
  }

  // No service running means nothing is offered to Windows: turning off works locally.
  func testTurnOffWithServiceNotRunningTurnsOffLocally() async {
    let feeder = FakeFeeder(), service = FakeService()
    let m = model(feeder, service, enabled: false)
    await m.apply(true)
    service.reply = .unreachable("not running")
    await m.apply(false)
    XCTAssertFalse(m.enabled)
    XCTAssertFalse(feeder.running)
  }

  func testFailedTurnOnDoesNotFeed() async {
    let feeder = FakeFeeder(), service = FakeService()
    service.reply = .unreachable("down")
    let m = model(feeder, service, enabled: false)
    await m.apply(true)
    XCTAssertFalse(m.enabled); XCTAssertFalse(feeder.running)
  }

  func testDeniedPermissionStaysOff() async {
    let feeder = FakeFeeder(), service = FakeService()
    let m = model(feeder, service, enabled: false, permission: false)
    await m.apply(true)
    XCTAssertFalse(m.enabled); XCTAssertTrue(m.permissionDenied); XCTAssertFalse(feeder.running)
    XCTAssertEqual(service.sent, [])
  }

  // At login the service may not answer yet; the feeder retries on its own, so
  // it starts right away instead of waiting for a one-shot request that can fail.
  func testLaunchWithMicOnStartsFeedingEvenIfServiceIsDown() async {
    let feeder = FakeFeeder(), service = FakeService()
    service.reply = .unreachable("starting")
    let m = model(feeder, service, enabled: true)
    await Task.yield()
    XCTAssertTrue(m.enabled)
    XCTAssertTrue(feeder.running)
  }

  // The app's setting wins: the next status poll fixes a service that disagrees.
  func testReconcilePushesAppSettingToService() async {
    let feeder = FakeFeeder(), service = FakeService()
    let m = model(feeder, service, enabled: true)
    await m.reconcile(service: false)
    XCTAssertEqual(service.sent, [true])
    await m.reconcile(service: true)
    XCTAssertEqual(service.sent, [true], "nothing to fix")
    await m.reconcile(service: nil)
    XCTAssertEqual(service.sent, [true], "older service without the mic")
    let off = model(FakeFeeder(), service, enabled: false)
    await off.reconcile(service: true)
    XCTAssertEqual(service.sent, [true, false])
  }

  // A startup sync must never undo a quick "turn off".
  func testTurnOffRightAfterLaunchStaysOff() async {
    let feeder = FakeFeeder(), service = FakeService()
    let m = model(feeder, service, enabled: true)
    await m.apply(false)
    await m.reconcile(service: true)  // the service still says on from before
    XCTAssertFalse(m.enabled)
    XCTAssertFalse(feeder.running)
    XCTAssertEqual(service.sent, [false, false])
  }

  func testEnsurePermissionReportsDenial() async {
    let denied = model(FakeFeeder(), FakeService(), enabled: false, permission: false)
    let ok = await denied.ensurePermission()
    XCTAssertFalse(ok); XCTAssertTrue(denied.permissionDenied)
    let allowed = model(FakeFeeder(), FakeService(), enabled: false, permission: true)
    let granted = await allowed.ensurePermission()
    XCTAssertTrue(granted); XCTAssertFalse(allowed.permissionDenied)
  }

  func testOldServiceGetsUpdateHint() {
    XCTAssertEqual(MicSharingModel.message(for: "Unknown device"),
      "Update the Longcable service to use Longcable Mic (run the installer again).")
    XCTAssertEqual(MicSharingModel.message(for: "Unknown action"),
      "Update the Longcable service to use Longcable Mic (run the installer again).")
    XCTAssertEqual(MicSharingModel.message(for: "Disk full"), "Disk full")
  }
}
