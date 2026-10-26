// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import SwiftUI

struct SetupView: View {
  @ObservedObject var model: SharingModel
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Set up Longcable").font(.title2.bold())
      Text("Install the background service from the source checkout using scripts/install-mac.sh. Choose the Mac listen IPv4 and the allowed peer IPv4 addresses. See README.md for commands.")
      Text("After installation, use Share to remember an external USB device. The service keeps running when this app closes.")
      Text("On Windows, install usbip-win2 and use windows/longcable.ps1. Use Tailscale or a trusted LAN.")
      Button("Refresh service status") { Task { await model.refresh() } }
    }.padding(20).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
  }
}
