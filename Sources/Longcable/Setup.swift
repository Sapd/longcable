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
  var busIDs: [String] { model.status?.devices.filter(\.enabled).map(\.id) ?? [] }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Connect a PC").font(.title2.bold())
        Text("Tick devices in the main window, then run these commands on your PC.")
          .foregroundStyle(.secondary)
        Text("Tailscale: \(addresses.tailscaleIP ?? "unavailable")\(addresses.magicDNS.map { " · " + $0 } ?? "")")
        Text("LAN: \(addresses.lanIP ?? "unavailable")")
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
            command("Quick setup · administrator PowerShell", ConnectionSetup.windowsQuick(server: address))
            command("Or attach manually · usbip-win2", ConnectionSetup.windowsManual(server: address, busIDs: busIDs))
          } else {
            command("Linux", ConnectionSetup.linux(server: address, busIDs: busIDs))
          }
          if busIDs.isEmpty { Text("Share a device to include its attach command.").font(.caption) }
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
  func command(_ title: String, _ text: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title).font(.headline)
        Spacer()
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }
      }
      Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
  }
}

struct DeviceWindowsCommandView: View {
  let device: DeviceStatus
  @State private var addresses = ConnectionAddresses()
  @State private var tailscale = false
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Windows command").font(.headline)
      Text(device.name + " · " + device.id).font(.caption).foregroundStyle(.secondary)
      if addresses.address(tailscale: true) != nil && addresses.lanIP != nil {
        Picker("Network", selection: $tailscale) {
          Text("Tailscale").tag(true)
          Text("LAN").tag(false)
        }.pickerStyle(.segmented).controlSize(.small)
      }
      if let address = addresses.address(tailscale: tailscale) {
        let text = ConnectionSetup.windowsDevice(server: address, busID: device.id)
        HStack {
          Text("Run in administrator PowerShell").font(.subheadline)
          Spacer()
          Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
          }.controlSize(.small)
        }
        // Popovers don't propose a height; without fixedSize the block collapses to one line.
        Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
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
