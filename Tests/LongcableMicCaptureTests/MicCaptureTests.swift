// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import AVFoundation
import XCTest
@testable import LongcableMicCapture

final class MicCaptureTests: XCTestCase {
  // A default-input change can race stop(); a session built after stop must not
  // be kept, or the Mac would keep recording with nobody listening.
  func testSessionBuiltAfterStopIsRejected() {
    let capture = MicCapture(deviceUID: nil)
    capture.stop()
    XCTAssertFalse(capture.install(AVCaptureSession()))
    XCTAssertFalse(capture.isRecording)
  }

  // A chosen input that isn't plugged in must not silently become the default mic.
  func testMissingChosenInputFailsInsteadOfRecordingDefault() {
    let capture = MicCapture(deviceUID: "no-such-input-\(UUID().uuidString)")
    XCTAssertThrowsError(try capture.start { _ in }) { error in
      XCTAssertTrue(String(describing: error).contains("not connected"), String(describing: error))
    }
    XCTAssertFalse(capture.isRecording)
  }
}
