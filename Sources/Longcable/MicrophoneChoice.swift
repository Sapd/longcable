// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import LongcableCore

// How Windows gets a microphone: not at all, as Longcable Mic (the Mac keeps the
// real one), or by handing a USB microphone over completely (USB passthrough).
// One at a time: passing a microphone through takes it away from the Mac, which
// would silence Longcable Mic if it records that same microphone.
enum MicrophoneMode: Equatable {
  case off
  case mac
  case handOver(String)  // bus ID of a USB audio device the Mac already knows
  case handOverNew(LocalUSBDevice)  // a USB audio device that still has to be added
}

enum MicrophoneChoice {
  enum Step: Equatable {
    case ensurePermission  // ask for microphone access before giving anything up
    case micOn, micOff
    case share(String), unshare(String)
    case add(LocalUSBDevice)  // adding a device also shares it
  }

  static func current(micEnabled: Bool, devices: [DeviceStatus]) -> MicrophoneMode {
    // If both are on (set up before this choice existed), Longcable Mic is what
    // works; conflicting() names the passed-through mic that should be released.
    if micEnabled { return .mac }
    if let shared = devices.first(where: { $0.audio == true && $0.enabled }) { return .handOver(shared.id) }
    return .off
  }
  static func conflicting(micEnabled: Bool, devices: [DeviceStatus]) -> [String] {
    micEnabled ? devices.filter { $0.audio == true && $0.enabled }.map(\.id) : []
  }

  static func steps(to mode: MicrophoneMode, micEnabled: Bool, devices: [DeviceStatus]) -> [Step] {
    let sharedAudio = devices.filter { $0.audio == true && $0.enabled }.map(\.id)
    switch mode {
    case .off:
      return (micEnabled ? [.micOff] : []) + sharedAudio.map(Step.unshare)
    case .mac:
      // Permission first (a denial gives nothing up), then give a passed-through
      // microphone back so the Mac can record it, then start Longcable Mic.
      return (micEnabled ? [] : [.ensurePermission]) + sharedAudio.map(Step.unshare) + (micEnabled ? [] : [.micOn])
    case .handOver(let id):
      // Share first: if that fails, Longcable Mic keeps running.
      return (sharedAudio.contains(id) ? [] : [.share(id)]) + sharedAudio.filter { $0 != id }.map(Step.unshare)
        + (micEnabled ? [.micOff] : [])
    case .handOverNew(let device):
      return [.add(device)] + sharedAudio.map(Step.unshare) + (micEnabled ? [.micOff] : [])
    }
  }
}
