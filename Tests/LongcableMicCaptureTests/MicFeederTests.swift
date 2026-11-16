// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation
import LongcableCore
import XCTest
@testable import LongcableMicCapture

final class FakeSource: MicSource {
  static let lock = NSLock()
  static var running = [FakeSource]()
  static var failing: Set<String> = []
  let uid: String?
  var onFailure: ((String) -> Void)?
  init(uid: String? = nil, onFailure: ((String) -> Void)? = nil) { self.uid = uid; self.onFailure = onFailure }
  func start(_ onSamples: @escaping (UnsafeBufferPointer<Int16>) -> Void) throws {
    if Self.lock.withLock({ Self.failing.contains(uid ?? "default") }) {
      throw USBError.message("cannot record \(uid ?? "default")")
    }
    Self.lock.withLock { Self.running.append(self) }
  }
  func stop() { Self.lock.withLock { Self.running.removeAll { $0 === self } } }
}

// Plays scripted messages, then blocks until closed; after close it waits for
// `releaseAfterClose` so tests can hold an old loop at that point.
final class FakeChannel: MicChannel {
  private let lock = NSLock()
  private var script: [AudioMessage]
  private let wake = DispatchSemaphore(value: 0)
  private var closed = false
  let releaseAfterClose: DispatchSemaphore?
  private let endAfterScript: Bool
  // Holds the first message until released, to deliver it late.
  let holdFirst: DispatchSemaphore?
  init(_ script: [AudioMessage], holdAfterClose: Bool = false, endAfterScript: Bool = false,
       holdFirst: Bool = false) {
    self.script = script
    releaseAfterClose = holdAfterClose ? DispatchSemaphore(value: 0) : nil
    self.endAfterScript = endAfterScript
    self.holdFirst = holdFirst ? DispatchSemaphore(value: 0) : nil
  }
  func connect() throws {}
  func receive() -> AudioMessage? {
    if let holdFirst, lock.withLock({ !script.isEmpty }) { holdFirst.wait() }
    if let next = lock.withLock({ () -> AudioMessage? in
      guard !script.isEmpty else { return nil }
      return script.removeFirst()
    }) { return next }
    if endAfterScript { return nil }
    wake.wait()
    releaseAfterClose?.wait()
    return nil
  }
  func send(samples: UnsafeBufferPointer<Int16>) -> Bool { true }
  func close() {
    let first = lock.withLock { () -> Bool in defer { closed = true }; return !closed }
    if first { wake.signal() }
  }
}

final class MicFeederTests: XCTestCase {
  override func setUp() {
    FakeSource.lock.withLock { FakeSource.running.removeAll(); FakeSource.failing = [] }
  }
  private func feeder(_ channels: [FakeChannel]) -> MicFeeder {
    let lock = NSLock()
    var queue = channels
    return MicFeeder(makeSource: { uid, failed in FakeSource(uid: uid, onFailure: failed) },
      makeChannel: { lock.withLock { queue.count > 1 ? queue.removeFirst() : queue[0] } },
      retryDelay: 0.05)
  }
  private var runningUIDs: [String?] { FakeSource.lock.withLock { FakeSource.running.map(\.uid) } }
  private var runningCount: Int { FakeSource.lock.withLock { FakeSource.running.count } }
  private func eventually(_ condition: @escaping () -> Bool) {
    let deadline = Date().addingTimeInterval(3)
    while !condition() && Date() < deadline { usleep(5_000) }
  }

  func testDuplicateStartKeepsOneCapture() {
    let channel = FakeChannel([.start, .start])
    let feeder = MicFeeder(makeSource: { _, _ in FakeSource() }, makeChannel: { channel }, retryDelay: 0.05)
    feeder.start(deviceUID: nil)
    eventually { self.runningCount > 0 }
    usleep(100_000)
    XCTAssertEqual(runningCount, 1)
    feeder.stop()
    eventually { self.runningCount == 0 }
    XCTAssertEqual(runningCount, 0)
  }

  func testOldLoopCannotStopNewCapture() {
    let old = FakeChannel([.start], holdAfterClose: true)
    let new = FakeChannel([.start])
    let channels = NSLock()
    var queue = [old, new]
    let feeder = MicFeeder(makeSource: { _, _ in FakeSource() },
      makeChannel: { channels.withLock { queue.removeFirst() } }, retryDelay: 0.05)
    feeder.start(deviceUID: nil)
    eventually { self.runningCount == 1 }
    feeder.stop()
    feeder.start(deviceUID: nil)
    usleep(100_000)
    eventually { self.runningCount == 1 }
    let newCapture = FakeSource.lock.withLock { FakeSource.running.first }
    XCTAssertNotNil(newCapture)
    old.releaseAfterClose?.signal()  // the old loop now runs its cleanup
    usleep(100_000)
    XCTAssertTrue(FakeSource.lock.withLock { FakeSource.running.contains { $0 === newCapture } })
    feeder.stop()
  }

  func testChangeWhileRecordingSwitchesInput() {
    let f = feeder([FakeChannel([.start])])
    var events = [Bool]()
    let events_lock = NSLock()
    f.onListening = { v in events_lock.withLock { events.append(v) } }
    f.start(deviceUID: "A")
    eventually { self.runningUIDs == ["A"] }
    f.change(deviceUID: "B")
    eventually { self.runningUIDs == ["B"] }
    XCTAssertEqual(runningUIDs, ["B"])
    XCTAssertEqual(events_lock.withLock { events }, [true], "no off/on flicker on a switch")
    f.stop()
  }

  func testStopMessageEndsCapture() {
    let f = feeder([FakeChannel([.start, .stop])])
    f.start(deviceUID: nil)
    usleep(150_000)
    XCTAssertEqual(runningCount, 0)
    f.stop()
  }

  func testChangeAfterStopMessageDoesNotRecord() {
    let f = feeder([FakeChannel([.start, .stop])])
    f.start(deviceUID: "A")
    usleep(150_000)
    f.change(deviceUID: "B")
    usleep(100_000)
    XCTAssertEqual(runningCount, 0, "Windows is not listening: switching input must not record")
    f.stop()
  }

  func testReconnectsAfterServiceDrop() {
    let first = FakeChannel([.start], endAfterScript: true)
    let second = FakeChannel([.start])
    let f = feeder([first, second])
    f.start(deviceUID: nil)
    eventually { self.runningCount == 1 && first !== second }
    usleep(300_000)
    XCTAssertEqual(runningCount, 1, "recording again on the new connection")
    f.stop()
    eventually { self.runningCount == 0 }
    XCTAssertEqual(runningCount, 0)
  }

  func testChangeAfterFailedStartRetries() {
    FakeSource.lock.withLock { FakeSource.failing = ["A"] }
    let f = feeder([FakeChannel([.start])])
    var errors = [String?]()
    let errorLock = NSLock()
    f.onError = { e in errorLock.withLock { errors.append(e) } }
    f.start(deviceUID: "A")
    usleep(150_000)
    XCTAssertEqual(runningCount, 0)
    f.change(deviceUID: "B")
    eventually { self.runningUIDs == ["B"] }
    XCTAssertEqual(runningUIDs, ["B"])
    XCTAssertEqual(errorLock.withLock { errors.last } ?? "set", nil, "the error clears once recording works")
    f.stop()
  }

  func testLateStartFromOldConnectionIsIgnored() {
    let old = FakeChannel([.start], holdFirst: true)
    let new = FakeChannel([.start])
    let f = feeder([old, new])
    f.start(deviceUID: "old")
    usleep(50_000)
    f.stop()
    f.start(deviceUID: "new")
    eventually { self.runningUIDs == ["new"] }
    let current = FakeSource.lock.withLock { FakeSource.running.first }
    old.holdFirst?.signal()
    usleep(150_000)
    XCTAssertEqual(runningCount, 1)
    XCTAssertTrue(FakeSource.lock.withLock { FakeSource.running.first === current })
    f.stop()
  }

  // The chosen microphone wasn't there when Windows started listening (still
  // with Windows after a passthrough, or unplugged): recording starts as soon as
  // macOS reports it connected.
  func testRecordingStartsWhenTheMicrophoneArrives() {
    FakeSource.lock.withLock { FakeSource.failing = ["A"] }
    let f = feeder([FakeChannel([.start])])
    f.start(deviceUID: "A")
    usleep(150_000)
    XCTAssertEqual(runningCount, 0)
    FakeSource.lock.withLock { FakeSource.failing = [] }
    NotificationCenter.default.post(name: MicFeeder.microphoneConnected, object: nil)
    eventually { self.runningUIDs == ["A"] }
    XCTAssertEqual(runningUIDs, ["A"])
    f.stop()
  }

  // A recording whose device went away is dropped, and restarts when it's back.
  func testLostRecordingRestartsWhenTheMicrophoneReturns() {
    let f = feeder([FakeChannel([.start])])
    f.start(deviceUID: "A")
    eventually { self.runningUIDs == ["A"] }
    let first = FakeSource.lock.withLock { FakeSource.running.first }
    first?.onFailure?("Elgato Wave:3 was disconnected")
    eventually { self.runningCount == 0 }
    XCTAssertEqual(runningCount, 0)
    NotificationCenter.default.post(name: MicFeeder.microphoneConnected, object: nil)
    eventually { self.runningUIDs == ["A"] }
    XCTAssertEqual(runningUIDs, ["A"])
    f.stop()
  }

  func testNoRecordingWhenWindowsIsNotListening() {
    let f = feeder([FakeChannel([])])
    f.start(deviceUID: "A")
    usleep(100_000)
    NotificationCenter.default.post(name: MicFeeder.microphoneConnected, object: nil)
    usleep(100_000)
    XCTAssertEqual(runningCount, 0)
    f.stop()
  }
}
