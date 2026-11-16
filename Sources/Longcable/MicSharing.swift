// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import AVFoundation
import AppKit
import LongcableCore
import LongcableMicCapture

// How the service answered a request to turn Longcable Mic on or off.
enum MicServiceReply: Equatable {
  case ok
  case refused(String)  // the service answered no
  case unreachable(String)  // no service to ask
}

// Feeds Longcable Mic: keeps a connection to the service while the feature is on
// and records the chosen input only between the service's start and stop.
@MainActor final class MicSharingModel: ObservableObject {
  static let shared = MicSharingModel()
  @Published private(set) var enabled: Bool
  @Published private(set) var inputUID: String?
  @Published private(set) var inputs = MicCapture.inputs()
  @Published private(set) var permissionDenied = false
  @Published private(set) var listening = false
  @Published private(set) var busy = false
  @Published var error: String?
  private let feeder: MicFeeding
  private let defaults: UserDefaults
  private let sendOverride: ((Bool) async -> MicServiceReply)?
  private let permission: () async -> Bool

  init(feeder: MicFeeding = MicFeeder(), defaults: UserDefaults = .standard,
       send: ((Bool) async -> MicServiceReply)? = nil,
       permission: (() async -> Bool)? = nil) {
    self.feeder = feeder
    self.defaults = defaults
    sendOverride = send
    self.permission = permission ?? MicSharingModel.microphoneAllowed
    enabled = defaults.bool(forKey: "virtualMicEnabled")
    inputUID = defaults.string(forKey: "virtualMicInput")
    // DispatchQueue.main keeps callbacks in order (separate Tasks could reorder).
    feeder.onListening = { [weak self] value in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.listening = value } }
    }
    feeder.onError = { [weak self] message in
      DispatchQueue.main.async { MainActor.assumeIsolated { self?.error = message } }
    }
    refreshPermission()
    // The feeder keeps retrying until the service answers, so it starts now.
    // The service's own flag is brought in line by reconcile() on status polls.
    if enabled { feeder.start(deviceUID: inputUID) }
  }

  // Called with each service status. The app's setting wins; never while a
  // toggle is in flight, so a stale sync can't undo the user's choice.
  func reconcile(service: Bool?) async {
    guard let service, service != enabled, !busy else { return }
    busy = true
    defer { busy = false }
    _ = await send(enabled)
  }

  // Asks once if needed; true when Longcable may record.
  func ensurePermission() async -> Bool {
    let allowed = await permission()
    permissionDenied = !allowed
    return allowed
  }

  func refreshPermission() {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    permissionDenied = status == .denied || status == .restricted
  }

  func setEnabled(_ on: Bool) {
    guard !busy, on != enabled else { return }
    busy = true
    Task { await apply(on) }
  }

  func apply(_ on: Bool) async {
    busy = true
    defer { busy = false }
    if on {
      guard await permission() else {
        permissionDenied = true
        return
      }
      permissionDenied = false
      guard await send(true) == .ok else { return }
      feeder.start(deviceUID: inputUID)
    } else {
      // Tell the service first: if it can't be reached, it still offers the mic,
      // so keep feeding it and keep showing "on".
      switch await send(false) {
      case .ok: break
      // No service running: it offers nothing to Windows, so off is safe locally.
      case .unreachable: error = nil
      // The service is there but said no: it still offers the mic, keep feeding.
      case .refused: return
      }
      feeder.stop()
    }
    enabled = on
    defaults.set(on, forKey: "virtualMicEnabled")
  }

  // A service from before Longcable Mic answers the unknown action this way.
  static func message(for reply: String) -> String {
    reply == "Unknown device" || reply == "Unknown action"
      ? String(localized: "Update the Longcable service to use Longcable Mic (run the installer again).") : serviceText(reply)
  }

  func selectInput(_ uid: String?) {
    inputUID = uid
    defaults.set(uid, forKey: "virtualMicInput")
    feeder.change(deviceUID: uid)
  }
  func refreshInputs() {
    inputs = MicCapture.inputs()
    refreshPermission()
  }
  func openPrivacySettings() {
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
  }

  private static func microphoneAllowed() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
    default: return false
    }
  }
  private func send(_ on: Bool) async -> MicServiceReply {
    if let sendOverride { return await sendOverride(on) }
    let result = await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(returning: Result {
          try LocalControl.send(ControlRequest(action: "virtual-mic", enabled: on))
        })
      }
    }
    switch result {
    case .success(let reply) where reply.ok:
      error = nil
      return .ok
    case .success(let reply):
      error = Self.message(for: reply.message)
      return .refused(reply.message)
    case .failure(let failure):
      error = String(describing: failure)
      return .unreachable(String(describing: failure))
    }
  }
}
