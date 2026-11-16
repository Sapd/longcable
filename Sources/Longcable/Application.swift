// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import AppKit
import SwiftUI
import LongcableCore

@MainActor final class SharingModel: ObservableObject {
  @Published var status: ServerStatus?
  @Published var error: String?
  @Published var notice: String?
  @Published var busy: Set<String> = []
  @Published var online = false
  @Published var showInDock = (UserDefaults.standard.object(forKey: "showInDock") as? Bool) ?? true
  @Published var setupIssue: String?
  @Published var showingSetup = false
  // One microphone switch at a time, from the card or the menu.
  @Published var choosingMicrophone = false
  @Published var microphoneError: String?
  private var polling = false
  private var pollTask: Task<Void, Never>?
  init() {
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refresh()
        try? await Task.sleep(nanoseconds: 2_000_000_000)
      }
    }
  }
  deinit { pollTask?.cancel() }
  func refresh() async {
    guard !polling else { return }
    polling = true
    defer { polling = false }
    let result = await request(ControlRequest(action: "status"))
    switch result {
    case .success(let reply):
      status = reply.status
      online = reply.ok
      if reply.ok { error = nil } else { error = serviceText(reply.message) }
      if reply.ok { await MicSharingModel.shared.reconcile(service: reply.status?.virtualMic?.enabled) }
    case .failure(let failure):
      online = false
      error = serviceText(String(describing: failure))
    }
  }
  func request(_ request: ControlRequest) async -> Result<ControlReply, Error> {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(returning: Result { try LocalControl.send(request) })
      }
    }
  }
  func action(_ action: String, _ busID: String) {
    guard !busy.contains(busID) else { return }
    busy.insert(busID)
    Task {
      defer { busy.remove(busID) }
      switch await request(ControlRequest(action: action, busID: busID)) {
      case .success(let reply):
        if reply.ok {
          notice = serviceText(reply.message)
          error = nil
          if let value = reply.status { status = value }
        } else {
          error = serviceText(reply.message)
        }
      case .failure(let failure): error = serviceText(String(describing: failure))
      }
      await refresh()
    }
  }
  func allowPeer(_ address: String) {
    guard !busy.contains(address) else { return }
    busy.insert(address)
    Task {
      defer { busy.remove(address) }
      switch await request(ControlRequest(action: "allow-peer", peer: address)) {
      case .success(let reply):
        if reply.ok { status = reply.status; notice = serviceText(reply.message); error = nil }
        else { error = serviceText(reply.message) }
      case .failure(let failure): error = serviceText(String(describing: failure))
      }
      await refresh()
    }
  }
  func add(_ device: LocalUSBDevice) {
    let key = device.vendor + ":" + device.product
    guard !busy.contains(key) else { return }
    busy.insert(key)
    Task {
      defer { busy.remove(key) }
      switch await request(ControlRequest(action: "add", device: device)) {
      case .success(let reply):
        if reply.ok {
          notice = serviceText(reply.message)
          status = reply.status
        } else {
          error = serviceText(reply.message)
        }
      case .failure(let failure): error = serviceText(String(describing: failure))
      }
      await refresh()
    }
  }
  func changeDock(_ enabled: Bool) {
    showInDock = enabled
    UserDefaults.standard.set(enabled, forKey: "showInDock")
    NSApp.setActivationPolicy(enabled ? .regular : .accessory)
    if enabled { NSApp.activate(ignoringOtherApps: true) }
  }
  func exportDiagnostics() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Longcable Diagnostics.txt"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let state =
        try status.map { String(data: try encoder.encode($0), encoding: .utf8)! }
        ?? "Service unavailable"
      let log = (try? String(contentsOfFile: Paths.log, encoding: .utf8)) ?? "Log unavailable"
      try
        ("Longcable diagnostics\n\(Date())\n\n\(state)\n\nRecent service log\n\(String(log.suffix(131072)))\n")
        .write(to: url, atomically: true, encoding: .utf8)
      notice = String(localized: "Diagnostics saved")
    } catch { self.error = String(localized: "Could not export diagnostics: \(String(describing: error))") }
  }
}
@MainActor func showAbout() {
  let credits = NSMutableAttributedString(string: "Longcable\nDenis Arnst (Sapd)\nhttps://github.com/Sapd\nGPL-3.0-or-later")
  NSApp.orderFrontStandardAboutPanel(options: [.applicationIcon: AppArtwork.appIcon, .credits: credits])
  NSApp.activate(ignoringOtherApps: true)

}

@main struct LongcableApplication: App {
  @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
  @StateObject private var model = SharingModel()
  var body: some Scene {
    Window("Longcable Server", id: "devices") {
      MainApplicationView(model: model).frame(minWidth: 620, minHeight: 560)
    }.defaultSize(width: 700, height: 740).windowResizability(.contentMinSize)
      .commands {
        CommandGroup(replacing: .appInfo) { Button("About Longcable Server") { showAbout() } }
      }
    MenuBarExtra {
      MenuContent(model: model)
    } label: {
      Image(nsImage: AppArtwork.menuBar).accessibilityLabel("Longcable Server")
    }
  }
}
private extension DeviceStatus {
  var displayState: String {
    state == "Waiting for Windows" ? String(localized: "Not attached by a PC yet") : serviceText(state)
  }
}
struct MenuContent: View {
  @ObservedObject var model: SharingModel
  @Environment(\.openWindow) var openWindow
  var body: some View {
    Text(model.online ? "USB sharing is running" : "USB sharing is unavailable")
    if let status = model.status {
      ForEach(status.devices.filter { $0.audio != true }) { device in
        Menu(device.name) {
          Text(device.displayState)
          Button(device.enabled ? "Stop Sharing" : "Share with Windows") {
            model.action(device.enabled ? "unshare" : "share", device.id)
          }
          Button("Reconnect") { model.action("reconnect", device.id) }.disabled(!device.enabled)
        }.disabled(!model.online || model.busy.contains(device.id))
      }
    }
    MicMenuItem(model: model)
    Divider()
    Button("Open Longcable Server…") {
      openWindow(id: "devices")
      NSApp.activate(ignoringOtherApps: true)
    }
    Button("Connect a PC…") {
      model.showingSetup = true
      openWindow(id: "devices")
      NSApp.activate(ignoringOtherApps: true)
    }
    Button("Export Diagnostics…") { model.exportDiagnostics() }
    Button("About Longcable") {
      showAbout()
      NSApp.activate(ignoringOtherApps: true)
    }
    Divider()
    Button("Quit App") { NSApp.terminate(nil) }
    Text("Sharing continues when the app closes")
  }
}
struct SharingView: View {
  @ObservedObject var model: SharingModel
  var connected: Int {
    model.online ? (model.status?.devices.filter { $0.state == "Connected to Windows" }.count ?? 0) : 0
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        Image(nsImage: AppArtwork.appIcon).resizable().interpolation(.high)
          .frame(width: 64, height: 64).accessibilityLabel("Longcable Server icon")
        VStack(alignment: .leading, spacing: 5) {
          Text("Longcable Server").font(.largeTitle.bold())
          Text("Your devices. On your Windows PC.").foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 8) {
          Label(
            model.online ? "Running" : "Offline",
            systemImage: model.online ? "checkmark.circle.fill" : "exclamationmark.circle"
          )
          .font(.callout.weight(.medium)).foregroundStyle(model.online ? .green : .orange)
          Button("About…") { showAbout() }.controlSize(.small)
        }
      }.padding(24)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(connected == 1 ? "1 device connected" : "\(connected) devices connected").font(.headline)
              if let status = model.status {
                Text("Allowed peers · \((status.allowedPeers ?? [status.peer]).joined(separator: ", "))")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
            Spacer()
            Button("Connect a PC") { model.showingSetup = true }.buttonStyle(.borderedProminent)
            Button {
              model.showingSetup = true
            } label: { Image(systemName: "gearshape") }.help("Connection Setup").accessibilityLabel("Connection Setup")
            Button {
              Task { await model.refresh() }
            } label: {
              Image(systemName: "arrow.clockwise")
            }.help("Refresh status")
          }
          if let peer = model.status?.refusedPeers?.first {
            HStack {
              Text("\(peer.address) tried to connect ·")
              Button("Allow") { model.allowPeer(peer.address) }.disabled(!model.online || model.busy.contains(peer.address))
            }.font(.callout).padding(10)
              .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
          }
          if let error = model.error {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout)
              .foregroundStyle(.orange).textSelection(.enabled)
          }
          if let status = model.status {
            // USB microphones are offered in the Microphone card instead.
            ForEach(status.devices.filter { $0.audio != true }) { device in DeviceCard(device: device, model: model) }
            MicCard(model: model)
            if let available = status.availableDevices?.filter({ $0.audio != true }), !available.isEmpty {
              Text("Other USB devices").font(.headline).padding(.top, 8)
              Text(
                "Click Share once. Your choice is remembered when you reconnect the device, even in another port."
              ).font(.caption).foregroundStyle(.secondary)
              ForEach(available.filter { $0.minor != true }, id: \.location) { device in
                AvailableDeviceRow(device: device, model: model)
              }
              let minor = available.filter { $0.minor == true }
              if !minor.isEmpty {
                DisclosureGroup("Dock parts and display adapters (\(minor.count))") {
                  VStack(spacing: 8) {
                    Text("Built into a hub or dock, or only describing display modes. Rarely useful on Windows.")
                      .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(minor, id: \.location) { device in AvailableDeviceRow(device: device, model: model) }
                  }.padding(.top, 6)
                }.font(.callout).foregroundStyle(.secondary)
              }
            }
          } else {
            SetupView(model: model)
          }
          if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
          HStack {
            Toggle("Show in Dock", isOn: Binding(get: { model.showInDock }, set: { model.changeDock($0) })).toggleStyle(.checkbox)
            Spacer()
            Button("Export Diagnostics…") { model.exportDiagnostics() }
          }.padding(.top, 4)
          Text("Sharing runs in the background even when this window or app is closed.")
            .font(.caption).foregroundStyle(.secondary)
        }.padding(24)
      }
    }.background(Color(nsColor: .windowBackgroundColor))
      .sheet(isPresented: $model.showingSetup) {
        VStack(alignment: .trailing) {
          SetupView(model: model)
          Button("Done") { model.showingSetup = false }.padding(.trailing, 20).padding(.bottom, 12)
        }.frame(width: 620).fixedSize(horizontal: false, vertical: true)
      }

  }
}
// SF Symbol for a device kind reported by the service (see deviceKind).
func deviceSymbol(_ kind: String?) -> String {
  switch kind {
  case "storage": return "externaldrive"
  case "keyboard": return "keyboard"
  case "mouse": return "computermouse"
  case "security-key": return "key"
  case "camera": return "web.camera"
  default: return "cable.connector"
  }
}
struct AvailableDeviceRow: View {
  let device: LocalUSBDevice
  @ObservedObject var model: SharingModel
  var body: some View {
    HStack {
      Image(systemName: deviceSymbol(device.kind)).foregroundStyle(.secondary).frame(width: 22)
      VStack(alignment: .leading) {
        Text(device.name.isEmpty ? String(localized: "USB device") : device.name).foregroundStyle(.primary)
        Text(device.vendor + ":" + device.product).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Button("Share") { model.add(device) }.disabled(
        !model.online || model.busy.contains(device.vendor + ":" + device.product))
    }.padding(12).background(
      Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
  }
}
struct DeviceCard: View {
  let device: DeviceStatus
  @ObservedObject var model: SharingModel
  @State private var details = false
  @State private var showingWindowsCommand = false
  var icon: String {
    if device.model.hasPrefix("2104") { return "eye" }
    if device.model.hasPrefix("28de") { return "gamecontroller" }
    if let hand = JoystickHand.detect(in: device.name) { return hand.symbol }
    return device.model.hasPrefix("231d") ? "gamecontroller" : deviceSymbol(device.kind)
  }
  var connected: Bool { device.state == "Connected to Windows" }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 13) {
        Image(systemName: icon).font(.system(size: 24)).foregroundStyle(
          connected ? Color.accentColor : Color.secondary
        ).frame(width: 36)
        VStack(alignment: .leading, spacing: 4) {
          Text(device.name).font(.headline)
          HStack(spacing: 5) {
            Circle().fill(connected ? .green : .secondary).frame(width: 6, height: 6)
            Text(model.online ? device.displayState : String(localized: "Waiting for sharing service")).font(.caption).foregroundStyle(.secondary)
          }
          if model.online && device.state == "Waiting for Windows" {
            Text("Run the Windows command on your PC, or wait if it is reconnecting.")
              .font(.caption).foregroundStyle(.secondary)
          }
          if !connected, let error = device.lastError, error.hasPrefix("In use by") || error.hasPrefix("Another app") {
            Label(serviceText(error), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
          }
        }
        Spacer()
        Toggle(
          "Share",
          isOn: Binding(
            get: { device.enabled }, set: { model.action($0 ? "share" : "unshare", device.id) })
        ).toggleStyle(.switch)
          .disabled(!model.online || model.busy.contains(device.id)).accessibilityLabel(
            "Share \(device.name)")
      }
      HStack {
        Text(
          ByteCountFormatter.string(
            fromByteCount: Int64(clamping: device.bytes), countStyle: .binary) + " " + String(localized: "transferred")
        ).font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button(details ? "Hide Details" : "Details") { details.toggle() }.buttonStyle(.plain).font(
          .caption
        ).foregroundStyle(.tint)
        Button("Windows command") { showingWindowsCommand = true }
          .controlSize(.small)
          .popover(isPresented: $showingWindowsCommand) {
            DeviceWindowsCommandView(device: device)
          }
        Button("Reconnect", systemImage: "arrow.triangle.2.circlepath") {
          model.action("reconnect", device.id)
        }
        .disabled(!device.enabled || !model.online || model.busy.contains(device.id))
      }
      if details {
        Divider()
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
          row("Identity", device.serial)
          row("Device", device.model + " · " + device.id)
          row("Transfers", String(localized: "\(device.completed) completed · \(device.pending) pending"))
          row("Errors", "\(device.errors)")
          if let last = device.lastActivity {
            row("Last USB activity", last.formatted(date: .omitted, time: .standard))
          }
          if let error = device.lastError { row("Recent error", serviceText(error)) }
        }.font(.caption).textSelection(.enabled)
      }
    }.padding(16).background(
      Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14)
    )
    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.07)))
  }
  func row(_ title: LocalizedStringKey, _ value: String) -> some View {
    GridRow {
      Text(title).foregroundStyle(.secondary)
      Text(value)
    }
  }
}
