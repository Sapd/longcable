// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import AppKit
import SwiftUI
import LongcableCore

struct SetupView: View {
  @ObservedObject var model: SharingModel
  @State private var addresses = ConnectionAddresses()
  @State private var tailscale = false
  @State private var platform = "Windows"
  var busIDs: [String] { ConnectionSetup.sharedBusIDs(model.status) }
  // What the command connects, in words the user recognises.
  var sharedNames: [String] {
    (model.status?.devices.filter(\.enabled).map(\.name) ?? [])
      + (model.status?.virtualMic?.enabled == true ? ["Longcable Mic"] : [])
  }
  @State private var copied = false
  @AppStorage("windowsAutoSync") private var autoSync = false
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Connect a PC").font(.title2.bold())
        Text(platform == "Windows"
          ? "Copy one command and run it on your Windows PC. After you share, stop sharing or add devices on this Mac, run the same command again: the PC then matches this Mac."
          : "Tick devices (and choose a microphone) in the main window, then run these commands on your PC.")
          .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Text("Tailscale: \(addresses.tailscaleIP ?? String(localized: "unavailable"))\(addresses.magicDNS.map { " · " + $0 } ?? "")")
        Text("LAN: \(addresses.lanIP ?? String(localized: "unavailable"))")
        Picker("Network", selection: $tailscale) {
          Text("Tailscale").tag(true)
          Text("LAN").tag(false)
        }.pickerStyle(.segmented)
        Picker("Client", selection: $platform) {
          Text("Windows").tag("Windows")
          Text("Linux").tag("Linux")
        }.pickerStyle(.segmented)
        if let address = addresses.address(tailscale: tailscale) {
          if platform == "Windows" {
            let describe = Bundle.main.object(forInfoDictionaryKey: "LongcableDescribe") as? String
            let scriptURL = ConnectionSetup.scriptURL(
              describe: describe,
              commit: Bundle.main.object(forInfoDictionaryKey: "LongcableCommit") as? String)
            quickSetup(ConnectionSetup.windowsQuick(server: address, scriptURL: scriptURL, autoSync: autoSync))
            Toggle(isOn: $autoSync) {
              VStack(alignment: .leading, spacing: 2) {
                Text("Keep this PC in step automatically")
                Text("Adds a Windows task that checks this Mac every minute, at startup and at login, and follows its changes. It runs as the system account and skips runs when a different Mac answers at this address.")
                  .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              }
            }.toggleStyle(.checkbox)
            DisclosureGroup("Stop automatic syncing on a PC") {
              command("Run on the PC", ConnectionSetup.windowsStopAutoSync(server: address, scriptURL: scriptURL))
                .padding(.top, 6)
            }.font(.callout)
            if ConnectionSetup.isLocalBuild(describe: describe) {
              Text("This is a local build of Longcable: the command uses the newest released Windows script.")
                .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Manual commands (usbip-win2)") {
              command("Attach manually", ConnectionSetup.windowsManual(server: address, busIDs: busIDs))
                .padding(.top, 6)
            }.font(.callout)
          } else {
            command("Linux", ConnectionSetup.linux(server: address, busIDs: busIDs))
          }
          if busIDs.isEmpty && platform != "Windows" { Text("Share a device to include its attach command.").font(.caption) }
        } else { Text("No address detected for this network. Check your connection.").foregroundStyle(.orange) }
        Divider()
        Text("Waiting for connections").font(.headline)
        Text("Only allow PCs you recognise. USB/IP gives them access to shared devices.").font(.caption).foregroundStyle(.secondary)
        if (model.status?.refusedPeers ?? []).isEmpty {
          Text("No refused connections yet.").foregroundStyle(.secondary)
        }
        ForEach(model.status?.refusedPeers ?? []) { peer in
          HStack {
            VStack(alignment: .leading) {
              Text(peer.address)
              Text(peer.timestamp.formatted()).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Allow") { model.allowPeer(peer.address) }.disabled(!model.online || model.busy.contains(peer.address))
          }
        }
        if !model.online { Text("Install the background service using the README Quick start.").foregroundStyle(.orange) }
        if let error = model.error { Text(error).foregroundStyle(.orange) }
      }.padding(20)
    }.frame(height: 600).task {
      let detected = await Task.detached(priority: .utility) { ConnectionSetup.detect() }.value
      addresses = detected
      tailscale = detected.prefersTailscale
    }
  }
  // The one step most people need, made obvious.
  func quickSetup(_ text: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Run this on your Windows PC", systemImage: "pc").font(.headline)
      Text("Paste it into PowerShell or Windows Terminal opened as administrator, then press Enter.")
        .font(.callout).foregroundStyle(.secondary)
      Text(PowerShellHighlight.attributed(text)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
      HStack(alignment: .firstTextBaseline) {
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
          copied = true
          Task { try? await Task.sleep(nanoseconds: 2_000_000_000); copied = false }
        } label: {
          Label(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc")
            .frame(minWidth: 140)
        }.buttonStyle(.borderedProminent).controlSize(.large)
        Text(sharedNames.isEmpty ? String(localized: "Nothing is shared yet.") : String(localized: "Connects: \(sharedNames.joined(separator: ", "))"))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }.padding(14)
      .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.35)))
  }
  func command(_ title: LocalizedStringKey, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }
      }
      Text(PowerShellHighlight.attributed(text)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
  }
}

struct DeviceWindowsCommandView: View {
  let name: String, busID: String
  init(device: DeviceStatus) { name = device.name; busID = device.id }
  init(name: String, busID: String) { self.name = name; self.busID = busID }
  @State private var addresses = ConnectionAddresses()
  @State private var tailscale = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Windows command").font(.headline)
      Text(name + " · " + busID).font(.caption).foregroundStyle(.secondary)
      if addresses.address(tailscale: true) != nil && addresses.lanIP != nil {
        Picker("Network", selection: $tailscale) {
          Text("Tailscale").tag(true)
          Text("LAN").tag(false)
        }.pickerStyle(.segmented).controlSize(.small)
      }
      if let address = addresses.address(tailscale: tailscale) {
        let text = ConnectionSetup.windowsDevice(server: address, busID: busID)
        HStack {
          Text("Run in administrator PowerShell").font(.subheadline)
          Spacer()
          Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
          }.controlSize(.small)
        }
        // Popovers don't propose a height; without fixedSize the block collapses to one line.
        Text(PowerShellHighlight.attributed(text)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading).padding(10)
          .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
      } else {
        Text("No Mac address detected. Check your connection.").foregroundStyle(.secondary)
      }
      Text("[usbip-win2](https://github.com/vadimgrn/usbip-win2/releases) must be installed.")
        .font(.caption).foregroundStyle(.secondary)
      Text("port --stash makes Windows reconnect it automatically after reboots.")
        .font(.caption).foregroundStyle(.secondary)
    }.padding(16).frame(width: 600).fixedSize(horizontal: false, vertical: true)
      .task {
        let detected = await Task.detached(priority: .utility) { ConnectionSetup.detect() }.value
        addresses = detected
        tailscale = detected.prefersTailscale
      }
  }
}
