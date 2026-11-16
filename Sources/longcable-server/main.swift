// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import Foundation
import LongcableCore
import LongcableMicCapture

let args = Array(CommandLine.arguments.dropFirst())
do {
  if args.first == "--preflight-install" {
    try preflightInstall(arguments: Array(args.dropFirst()))
    print("Installation configuration and saved state are compatible")
    exit(0)
  }
  if args.first == "--preserve-startup-devices" {
    try preserveStartupDevices()
    exit(0)
  }
  if args.first == "--protocol-test" {
    try USBServer.loopbackTest()
    exit(0)
  }
  if args.first == "--virtual-mic-dev" {
    // --virtual-mic-dev LISTEN PEERS [--port N] [--tone HZ | --capture UID|default]
    var rest = Array(args.dropFirst())
    guard rest.count >= 2 else {
      throw USBError.message("--virtual-mic-dev LISTEN_IPV4 PEERS [--port N] [--tone HZ | --capture UID|default]")
    }
    var config = try DaemonConfig(arguments: Array(rest.prefix(2)))
    rest.removeFirst(2)
    config.port = 3241
    var frequency = 440.0
    var capture: String?
    var alsoShared = [String]()
    var noSharedList = false
    var brokenSharedList = false
    while let option = rest.first {
      rest.removeFirst()
      if option == "--no-shared-list" { noSharedList = true; continue }
      if option == "--broken-shared-list" { brokenSharedList = true; continue }
      guard let value = rest.first else { throw USBError.message("\(option) needs a value") }
      rest.removeFirst()
      switch option {
      case "--port":
        guard let port = UInt16(value), port >= 1024 else { throw USBError.message("Invalid port") }
        config.port = port
      case "--tone":
        guard let hz = Double(value), hz > 0, hz < 20_000 else { throw USBError.message("Invalid tone") }
        frequency = hz
      case "--capture": capture = value
      case "--also-shared": alsoShared = value.split(separator: ",").map(String.init)
      default: throw USBError.message("Unknown option \(option)")
      }
    }
    let server = USBServer.virtualMicDevelopment(config: config)
    server.developmentOptions(alsoShared: alsoShared, noSharedList: noSharedList, brokenSharedList: brokenSharedList)
    if let capture {
      // Records like the app does: only while Windows is listening.
      let mic = MicCapture(deviceUID: capture == "default" ? nil : capture)
      server.onMicStreaming { streaming in
        if streaming {
          do { try mic.start { server.feedMic($0) } } catch { fputs("Longcable: \(error)\n", stderr) }
        } else { mic.stop() }
      }
    } else {
      server.useTestTone(frequency)
    }
    try server.run()
    exit(0)
  }
  if args.first == "--list-inputs" {
    for input in MicCapture.inputs() { print("\(input.id)\t\(input.name)") }
    print("default\t\(MicCapture.defaultInputUID ?? "none")")
    exit(0)
  }
  if args.first == "list" {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try encoder.encode(discoverUSBDevices()), encoding: .utf8)!)
    exit(0)
  }
  if args.first == "--control" {
    guard args.count >= 2 else {
      throw USBError.message("--control status|share|unshare|reconnect [BUSID] or allow-peer|forget-peer IPV4_OR_CIDR")
    }
    let reply = try LocalControl.send(
      ControlRequest(action: args[1], busID: args.count > 2 ? args[2] : nil,
        peer: args.count > 2 ? args[2] : nil))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(data: try encoder.encode(reply), encoding: .utf8)!)
    exit(reply.ok ? 0 : 1)
  }
  if args.first == "--validate" {
    let config = try DaemonConfig(arguments: Array(args.dropFirst()))
    if let warning = config.securityWarning { fputs(warning + "\n", stderr) }
    print("Configuration valid")
    exit(0)
  }
  if args.first == "--help" || args.first == "help" || args.isEmpty {
    print(
      "Longcable native Swift USB/IP server\nUsage: sudo longcable-server LISTEN_IPV4 PEERS (IPv4, CIDR, comma list, or any) [VID PID LOCATION LABEL ...]\nLocal controls: --control status|share|unshare|reconnect [BUSID] or allow-peer|forget-peer IPV4_OR_CIDR\nGUI: org.sapd.longcable.app (independent of the background service)"
    )
    exit(0)
  }
  let config = try DaemonConfig(arguments: args)
  try USBServer(config: config).run()
} catch {
  fputs("Longcable: \(error)\n", stderr)
  exit(1)
}
