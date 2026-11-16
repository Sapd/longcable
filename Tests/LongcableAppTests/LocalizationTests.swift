// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation
import XCTest
@testable import Longcable

// The service sends English; the app translates its states and messages for display.
final class LocalizationTests: XCTestCase {
  private var bundle: Bundle!
  private var folder: URL!

  override func setUpWithError() throws {
    // A bundle holding the German service table, as the packaged app would.
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("../../Localization/de.lproj/Service.strings")
    try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("Service.strings"))
    bundle = Bundle(url: folder)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

  func testStatesAreTranslated() {
    XCTAssertEqual(serviceText("Connected to Windows", bundle: bundle), "Mit Windows verbunden")
    XCTAssertEqual(serviceText("Not plugged in", bundle: bundle), "Nicht angeschlossen")
  }

  func testMessagesWithValuesAreTranslated() {
    XCTAssertEqual(serviceText("In use by Discord (pid 4711). Close it to share this device.", bundle: bundle),
                   "Wird von Discord verwendet (PID 4711). Beende die App, um dieses Gerät freizugeben.")
    XCTAssertEqual(serviceText("In use by the macOS driver AppleUSBAudio. Disconnect other apps using it, then try again.", bundle: bundle),
                   "Wird vom macOS-Treiber AppleUSBAudio verwendet. Trenne andere Apps, die es nutzen, und versuche es erneut.")
  }

  func testUnknownTextStaysAsItIs() {
    XCTAssertEqual(serviceText("Reading descriptors for 1-2 failed: timeout", bundle: bundle),
                   "Reading descriptors for 1-2 failed: timeout")
  }
}
