// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import Foundation
import LongcableCore

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
