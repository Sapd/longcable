// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation
import IOKit

public struct VirtualMicStatus: Codable, Sendable {
  public var enabled: Bool
  // "Off" | "Waiting for Windows" | "Attached, idle" | "Windows is listening"
  public var state: String
  public var sourceConnected: Bool
  public var bytes: UInt64
  public var errors: UInt64
  public var lastError: String?
}

typealias MicDeviceFactory = (MicBuffer, String, @escaping (Bool) -> Void) -> SessionDevice

// The exported slot 2-1. Unlike a physical Target it never touches IOKit: the
// device behind it is a VirtualMicTransport fed from `buffer`.
final class VirtualMicTarget: SessionTarget {
  let busID = VirtualMic.busID, wireID = VirtualMic.wireID
  let overlayLabel = ""
  let buffer: MicBuffer
  let captureLock = NSLock()
  // Told when Windows starts or stops streaming, i.e. when the Mac should record.
  var onStreaming: ((Bool) -> Void)? {
    get { stateLock.withLock { streamingHandler } }
    set { stateLock.withLock { streamingHandler = newValue } }
  }
  let serial: String
  private let makeDevice: MicDeviceFactory
  private let stateLock = NSLock()
  private var streamingHandler: ((Bool) -> Void)?
  private var storedIdentity: Identity?
  private var enabled = false
  private var connection: Connection?
  private var attachedNow = false, streaming = false, source = false
  private var bytes: UInt64 = 0, errors: UInt64 = 0
  private var lastError: String?

  init(buffer: MicBuffer, serial: String, makeDevice: MicDeviceFactory? = nil) {
    self.buffer = buffer
    self.serial = serial
    self.makeDevice = makeDevice ?? { buffer, serial, onStreaming in
      VirtualMicTransport(buffer: buffer, serial: serial, onStreaming: onStreaming)
    }
    storedIdentity = VirtualMic.identity(serial: serial)
  }

  var identity: Identity? {
    get { stateLock.withLock { storedIdentity } }
    set { stateLock.withLock { storedIdentity = newValue } }
  }
  var isEnabled: Bool { stateLock.withLock { enabled } }
  var sourceConnected: Bool {
    get { stateLock.withLock { source } }
    set { stateLock.withLock { source = newValue } }
  }

  func setEnabled(_ value: Bool) {
    stateLock.withLock {
      enabled = value
      if !value { connection?.interrupt() }
    }
  }
  func reconnect() { stateLock.withLock { connection?.interrupt() } }

  // Called by the server before running a Session on this slot.
  func begin(_ c: Connection) -> Bool {
    stateLock.withLock {
      guard enabled else { return false }
      connection = c
      return true
    }
  }

  func openDevice(_ identity: Identity, disconnected: @escaping () -> Void) throws -> SessionDevice {
    guard isEnabled else { throw USBError.message("The virtual microphone is off") }
    return makeDevice(buffer, serial) { [weak self] value in self?.streamingChanged(value) }
  }
  private func streamingChanged(_ value: Bool) {
    let handler = stateLock.withLock { () -> ((Bool) -> Void)? in
      streaming = value
      return streamingHandler
    }
    handler?(value)
  }

  func attached(_ location: UInt32) { stateLock.withLock { attachedNow = true; lastError = nil } }
  func ended() {
    stateLock.withLock { attachedNow = false; streaming = false; connection = nil }
  }
  func failed(_ error: Error) { stateLock.withLock { lastError = String(describing: error) } }
  func transfer(_ count: Int, status: Int32, pending: Int, native: IOReturn) {
    stateLock.withLock {
      bytes &+= UInt64(count)
      if status != 0 && status != -104 {
        errors &+= 1
        lastError = String(format: "USB status %d", status)
      }
    }
  }
  func queued(_ count: Int) {}

  func snapshot() -> VirtualMicStatus {
    stateLock.withLock {
      let state = !enabled ? "Off" : streaming ? "Windows is listening"
        : attachedNow ? "Attached, idle" : "Waiting for Windows"
      return VirtualMicStatus(enabled: enabled, state: state, sourceConnected: source,
        bytes: bytes, errors: errors, lastError: lastError)
    }
  }
}

func savedVirtualMic(at store: StorePaths, log: (String) -> Void) -> Bool {
  guard let data = try? readStoredFile(store.virtualMic, description: "virtual microphone setting") else {
    return false
  }
  struct Saved: Decodable { var enabled: Bool }
  do { return try JSONDecoder().decode(Saved.self, from: data).enabled }
  catch {
    log("Ignoring unreadable virtual microphone setting: \(error)")
    return false
  }
}

func saveVirtualMic(_ enabled: Bool, at store: StorePaths) throws {
  try JSONEncoder().encode(["enabled": enabled]).write(
    to: URL(fileURLWithPath: store.virtualMic), options: .atomic)
  chmod(store.virtualMic, 0o600)
}
