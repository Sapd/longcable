// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import AVFoundation
import Foundation
import LongcableCore

public protocol MicSource: AnyObject {
  func start(_ onSamples: @escaping (UnsafeBufferPointer<Int16>) -> Void) throws
  func stop()
}
extension MicCapture: MicSource {}

public protocol MicChannel: AnyObject {
  func connect() throws
  func receive() -> AudioMessage?
  @discardableResult func send(samples: UnsafeBufferPointer<Int16>) -> Bool
  func close()
}
extension AudioChannelClient: MicChannel {}

// What the app needs from the feeder; lets tests replace it.
public protocol MicFeeding: AnyObject {
  var onListening: ((Bool) -> Void)? { get set }
  // nil clears an earlier error.
  var onError: ((String?) -> Void)? { get set }
  func start(deviceUID: String?)
  func stop()
  func change(deviceUID: String?)
}

// Keeps a connection to the service while Longcable Mic is on, and records
// only while the service says Windows is listening. Every decision about the
// connection and the recording runs on one serial queue, so a switch of input,
// a stop from the service and a reconnect can never interleave.
public final class MicFeeder: MicFeeding, @unchecked Sendable {
  // Posted by macOS when a microphone appears (plugged in, or back from Windows).
  public static let microphoneConnected = AVCaptureDevice.wasConnectedNotification
  public var onListening: ((Bool) -> Void)?
  public var onError: ((String?) -> Void)?
  private let makeSource: (String?, @escaping (String) -> Void) -> MicSource
  private let makeChannel: () -> MicChannel
  private let retryDelay: TimeInterval
  private let ops = DispatchQueue(label: "org.sapd.longcable.mic-feeder")
  // Touched only on `ops`.
  private var running = false
  private var generation = 0
  private var deviceUID: String?
  private var client: MicChannel?
  private var wanted = false  // Windows is listening on the current connection
  private var capture: MicSource?

  public init(makeSource: @escaping (String?, @escaping (String) -> Void) -> MicSource = { uid, failed in
                MicCapture(deviceUID: uid, onFailure: failed) },
              makeChannel: @escaping () -> MicChannel = { AudioChannelClient() },
              retryDelay: TimeInterval = 2) {
    self.makeSource = makeSource
    self.makeChannel = makeChannel
    self.retryDelay = retryDelay
    connectObserver = NotificationCenter.default.addObserver(
      forName: Self.microphoneConnected, object: nil, queue: nil) { [weak self] _ in
        self?.ops.async { self?.retryCapture() }
      }
  }
  deinit { if let connectObserver { NotificationCenter.default.removeObserver(connectObserver) } }
  private var connectObserver: NSObjectProtocol?

  // On `ops`. Windows is listening but nothing records (the microphone was missing
  // or went away): try again now that a microphone has appeared.
  private func retryCapture() {
    if wanted, capture == nil, let client { startCapture(client) }
  }

  public func start(deviceUID: String?) {
    ops.sync {
      self.deviceUID = deviceUID
      guard !running else { return }
      running = true
      generation += 1
      let g = generation
      Thread.detachNewThread { [self] in loop(g) }
    }
  }

  public func stop() {
    ops.sync {
      running = false
      generation += 1
      wanted = false
      client?.close()
      client = nil
      stopCapture(notify: true)
    }
  }

  public func change(deviceUID: String?) {
    ops.sync {
      self.deviceUID = deviceUID
      if wanted, let client { startCapture(client) }
    }
  }

  private func loop(_ g: Int) {
    while ops.sync(execute: { running && generation == g }) {
      let c = makeChannel()
      do {
        try c.connect()
        let current = ops.sync { () -> Bool in
          guard running && generation == g else { return false }
          client = c
          return true
        }
        guard current else { c.close(); return }
        onError?(nil)
        while let message = c.receive() {
          let current = ops.sync { () -> Bool in
            // A late message from a connection that was replaced is ignored.
            guard running && generation == g && client === c else { return false }
            switch message {
            case .start:
              wanted = true
              startCapture(c)
            case .stop:
              wanted = false
              stopCapture(notify: true)
            default: break
            }
            return true
          }
          if !current { break }
        }
      } catch {
        onError?("Longcable Mic: \(error)")
      }
      c.close()
      ops.sync {
        guard client === c else { return }
        client = nil
        wanted = false
        stopCapture(notify: true)
      }
      if ops.sync(execute: { running && generation == g }) { Thread.sleep(forTimeInterval: retryDelay) }
    }
  }

  // On `ops`. Replaces any running capture without an off/on flicker.
  private func startCapture(_ c: MicChannel) {
    let wasListening = capture != nil
    stopCapture(notify: false)
    var made: MicSource?
    let mic = makeSource(deviceUID) { [weak self] message in
      self?.ops.async {
        guard let self else { return }
        // The device went away mid-recording: drop it; retryCapture restarts it.
        if let made, self.capture === made {
          self.capture = nil
          made.stop()
          self.onListening?(false)
        }
        self.onError?("Could not record: \(message)")
      }
    }
    made = mic
    do {
      try mic.start { samples in c.send(samples: samples) }
      capture = mic
      onError?(nil)
      if !wasListening { onListening?(true) }
    } catch {
      onError?("Could not record: \(error)")
      if wasListening { onListening?(false) }
    }
  }
  // On `ops`.
  private func stopCapture(notify: Bool) {
    guard let old = capture else { return }
    capture = nil
    old.stop()
    if notify { onListening?(false) }
  }
}
