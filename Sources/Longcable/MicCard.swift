// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import LongcableCore
import LongcableMicCapture
import SwiftUI

extension SharingModel {
  // One control request, awaited, with the same error/notice handling as action().
  func perform(_ request: ControlRequest) async -> Bool {
    switch await self.request(request) {
    case .success(let reply) where reply.ok:
      if let value = reply.status { status = value }
      error = nil
      return true
    case .success(let reply): error = reply.message
    case .failure(let failure): error = String(describing: failure)
    }
    return false
  }

  var microphoneMode: MicrophoneMode {
    MicrophoneChoice.current(micEnabled: MicSharingModel.shared.enabled, devices: status?.devices ?? [])
  }
  // USB microphones (audio devices) the Mac knows, then ones it could add.
  var usbMicrophones: [DeviceStatus] { status?.devices.filter { $0.audio == true } ?? [] }
  var newUSBMicrophones: [LocalUSBDevice] { status?.availableDevices?.filter { $0.audio == true } ?? [] }

  // Applies a choice step by step, one switch at a time, planned from a fresh
  // status. Stops at the first failure and says which change didn't happen.
  func chooseMicrophone(_ mode: MicrophoneMode) async {
    guard !choosingMicrophone else { return }
    choosingMicrophone = true
    defer { choosingMicrophone = false }
    microphoneError = nil
    if case .success(let reply) = await request(ControlRequest(action: "status")), reply.ok, let fresh = reply.status {
      status = fresh
    }
    let mic = MicSharingModel.shared
    for step in MicrophoneChoice.steps(to: mode, micEnabled: mic.enabled, devices: status?.devices ?? []) {
      var failure: String?
      switch step {
      case .ensurePermission:
        if !(await mic.ensurePermission()) { failure = "Longcable may not use the microphone. Allow it in System Settings, then try again." }
      case .micOn:
        await mic.apply(true)
        if !mic.enabled { failure = mic.error ?? "Couldn't turn on Longcable Mic." }
      case .micOff:
        await mic.apply(false)
        if mic.enabled { failure = mic.error ?? "Couldn't turn off Longcable Mic." }
      case .share(let id):
        if !(await perform(ControlRequest(action: "share", busID: id))) { failure = error ?? "Couldn't share the microphone." }
      case .unshare(let id):
        if !(await perform(ControlRequest(action: "unshare", busID: id))) { failure = error ?? "Couldn't stop sharing the microphone." }
      case .add(let device):
        if !(await perform(ControlRequest(action: "add", device: device))) { failure = error ?? "Couldn't add the microphone." }
      }
      if let failure {
        microphoneError = failure
        break
      }
    }
    await refresh()
  }
}

// One card for the microphone: off, keep it on the Mac (Longcable Mic), or hand a
// USB microphone over completely (USB passthrough). One at a time.
struct MicCard: View {
  @ObservedObject var mic = MicSharingModel.shared
  @ObservedObject var model: SharingModel
  @State private var pickedDevice: String?

  var mode: MicrophoneMode { model.microphoneMode }
  var micStatus: VirtualMicStatus? { model.status?.virtualMic }
  var handedOver: DeviceStatus? {
    if case .handOver(let id) = mode { return model.usbMicrophones.first { $0.id == id } }
    return nil
  }
  var isHandOver: Bool { handedOver != nil }
  var listening: Bool { mode == .mac && micStatus?.state == "Windows is listening" }
  // Passthrough choices: "bus:<id>" for known devices, "new:<location>" for others.
  var deviceOptions: [(tag: String, name: String)] {
    model.usbMicrophones.map { ("bus:" + $0.id, $0.name) }
      + model.newUSBMicrophones.map { ("new:" + $0.location, $0.name.isEmpty ? "USB microphone" : $0.name) }
  }
  var selectedDeviceTag: String? {
    if let handedOver { return "bus:" + handedOver.id }
    // A picked device that has gone (unplugged, or added since) falls back.
    if let pickedDevice, deviceOptions.contains(where: { $0.tag == pickedDevice }) { return pickedDevice }
    return deviceOptions.first?.tag
  }
  func handOverMode(_ tag: String?) -> MicrophoneMode? {
    guard let tag else { return nil }
    if tag.hasPrefix("bus:") { return .handOver(String(tag.dropFirst(4))) }
    let location = String(tag.dropFirst(4))
    return model.newUSBMicrophones.first { $0.location == location }.map { .handOverNew($0) }
  }
  var working: Bool { model.choosingMicrophone }
  func choose(_ target: MicrophoneMode?) {
    guard let target, !working else { return }
    Task { await model.chooseMicrophone(target) }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 13) {
        Image(systemName: listening ? "mic.fill" : "mic").font(.system(size: 24))
          .foregroundStyle(mode == .off ? Color.secondary : Color.accentColor).frame(width: 36)
        VStack(alignment: .leading, spacing: 4) {
          Text("Microphone on Windows").font(.headline)
          Text("Choose how your Windows PC gets a microphone.").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        if working { ProgressView().controlSize(.small) }
      }

      if let failure = model.microphoneError {
        Label(failure, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      if mic.permissionDenied {
        HStack {
          Label("Longcable may not use the microphone.", systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
          Button("Open Privacy Settings") { mic.openPrivacySettings() }.controlSize(.small)
        }
      }

      option(selected: mode == .off, title: "Off", detail: nil) { choose(.off) }

      option(selected: mode == .mac, title: "Share the Mac's microphone (recommended)",
             detail: "Windows gets “Longcable Mic”; the Mac keeps using the microphone too.") {
        choose(.mac)
      }
      if mode == .mac { macDetails.padding(.leading, 26) }
      let conflicts = MicrophoneChoice.conflicting(micEnabled: mic.enabled, devices: model.status?.devices ?? [])
      if !conflicts.isEmpty {
        HStack {
          let names = model.usbMicrophones.filter { conflicts.contains($0.id) }.map(\.name).joined(separator: ", ")
          Label("\(names) is also still shared with Windows as a whole device. As soon as no app on the Mac uses it, Windows would take it, and Longcable Mic would go silent.",
                systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
          Button("Stop sharing \(names)") { choose(.mac) }.controlSize(.small)
        }.padding(.leading, 26)
      }

      option(selected: isHandOver, title: "Hand over a USB microphone",
             detail: deviceOptions.isEmpty
               ? "Plug in a USB microphone to use this."
               : "Windows gets the whole device, with its own drivers and features. The Mac can't use it until you switch back.") {
        choose(handOverMode(selectedDeviceTag))
      }.disabled(deviceOptions.isEmpty)
      if !deviceOptions.isEmpty {
        HStack {
          Picker("Device", selection: Binding(get: { selectedDeviceTag ?? "" }, set: { tag in
            pickedDevice = tag
            if isHandOver { choose(handOverMode(tag)) }
          })) {
            ForEach(deviceOptions, id: \.tag) { Text($0.name).tag($0.tag) }
          }.frame(maxWidth: 320)
          Spacer()
          if let handedOver {
            Button("Reconnect", systemImage: "arrow.triangle.2.circlepath") {
              model.action("reconnect", handedOver.id)
            }.disabled(!model.online || model.busy.contains(handedOver.id))
          }
        }.padding(.leading, 26)
        if let handedOver { passthroughDetails(handedOver).padding(.leading, 26) }
      }

      if let error = mic.error {
        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
          .textSelection(.enabled)
      }
    }.padding(16).background(
      Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14)
    )
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.07)))
    .disabled(!model.online || working || mic.busy)
  }

  func option(selected: Bool, title: String, detail: String?, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(selected ? Color.accentColor : Color.secondary)
        VStack(alignment: .leading, spacing: 2) {
          Text(title).fontWeight(selected ? .semibold : .regular)
          if let detail {
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer()
      }.contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
  }

  @ViewBuilder var macDetails: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 5) {
        Circle().fill(listening ? .green : .secondary).frame(width: 6, height: 6)
        Text(macState).font(.caption).foregroundStyle(.secondary)
      }
      if let uid = mic.inputUID, !mic.inputs.contains(where: { $0.id == uid }) {
        Label("The chosen microphone is not connected.", systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
      }
      if listening, micStatus?.sourceConnected == false {
        Label("Windows is listening, but this app isn't sending audio yet.", systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
      }
      HStack {
        Picker("Input", selection: Binding(
          get: { mic.inputUID.flatMap { uid in mic.inputs.contains { $0.id == uid } ? uid : nil } ?? "" },
          set: { mic.selectInput($0.isEmpty ? nil : $0) })) {
          Text("System default").tag("")
          ForEach(mic.inputs) { input in Text(input.name).tag(input.id) }
        }.frame(maxWidth: 320)
        .onAppear { mic.refreshInputs() }
        Spacer()
        Button("Reconnect", systemImage: "arrow.triangle.2.circlepath") {
          model.action("reconnect", LongcableMic.busID)
        }.disabled(!model.online || model.busy.contains(LongcableMic.busID))
      }
    }
  }
  var macState: String {
    guard model.online else { return "Waiting for sharing service" }
    switch micStatus?.state {
    case "Waiting for Windows": return "Not attached by a PC yet"
    case let state?: return state
    case nil: return "Waiting for sharing service"
    }
  }

  @ViewBuilder func passthroughDetails(_ device: DeviceStatus) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 5) {
        Circle().fill(device.state == "Connected to Windows" ? .green : .secondary).frame(width: 6, height: 6)
        Text(device.state == "Waiting for Windows" ? "Not attached by a PC yet" : device.state)
          .font(.caption).foregroundStyle(.secondary)
      }
      if device.state != "Connected to Windows", let error = device.lastError,
        error.hasPrefix("In use by") || error.hasPrefix("Another app") {
        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
      }
    }
  }
}

struct MicMenuItem: View {
  @ObservedObject var mic = MicSharingModel.shared
  @ObservedObject var model: SharingModel
  var body: some View {
    let mode = model.microphoneMode
    Menu("Microphone on Windows") {
      Button((mode == .off ? "✓ " : "") + "Off") { Task { await model.chooseMicrophone(.off) } }
      Button((mode == .mac ? "✓ " : "") + "Share the Mac's microphone") { Task { await model.chooseMicrophone(.mac) } }
      ForEach(model.usbMicrophones) { device in
        Button((mode == .handOver(device.id) ? "✓ " : "") + "Hand over \(device.name)") {
          Task { await model.chooseMicrophone(.handOver(device.id)) }
        }
      }
    }.disabled(!model.online || mic.busy || model.choosingMicrophone)
  }
}
