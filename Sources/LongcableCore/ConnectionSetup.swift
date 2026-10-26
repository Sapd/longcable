// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import Foundation
import SystemConfiguration

public struct ConnectionAddresses: Sendable {
  public var tailscaleIP: String?
  public var magicDNS: String?
  public var lanIP: String?
  public init(tailscaleIP: String? = nil, magicDNS: String? = nil, lanIP: String? = nil) {
    self.tailscaleIP = tailscaleIP
    self.magicDNS = magicDNS?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    self.lanIP = lanIP
  }
  public var prefersTailscale: Bool { tailscaleIP != nil }
  public func address(tailscale: Bool) -> String? {
    tailscale ? ((magicDNS?.isEmpty == false ? magicDNS : nil) ?? tailscaleIP) : lanIP
  }
}
public enum ConnectionSetup {
  public static func windowsQuick(server: String) -> String {
    "irm https://github.com/Sapd/longcable/releases/latest/download/setup-windows.ps1 -OutFile $env:TEMP\\longcable-setup.ps1; & $env:TEMP\\longcable-setup.ps1 -Server \(psQuote(server))"
  }
  private static func psQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }
  private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
  public static func windowsManual(server: String, busIDs: [String]) -> String {
    (["$usbip = 'C:\\Program Files\\USBip\\usbip.exe'", "& $usbip list -r \(psQuote(server))"]
      + busIDs.map { "& $usbip attach -r \(psQuote(server)) -b \(psQuote($0)) --receive-mode=low-latency" }
      + ["& $usbip port --stash"]).joined(separator: "\n")
  }
  public static func windowsDevice(server: String, busID: String) -> String {
    ["$usbip = 'C:\\Program Files\\USBip\\usbip.exe'",
      "& $usbip attach -r \(psQuote(server)) -b \(psQuote(busID)) --receive-mode=low-latency",
      "& $usbip port --stash"].joined(separator: "\n")
  }
  public static func linux(server: String, busIDs: [String]) -> String {
    (["sudo modprobe vhci-hcd", "usbip list -r \(shellQuote(server))"]
      + busIDs.map { "sudo usbip attach -r \(shellQuote(server)) -b \(shellQuote($0))" }).joined(separator: "\n")
  }
  // Called on a utility queue. Each external probe has a deadline; missing/offline Tailscale is normal.
  public static func detect() -> ConnectionAddresses {
    let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map {
      String($0) + "/tailscale"
    } + ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
      "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
    var ip: String?, dns: String?
    for executable in candidates where FileManager.default.isExecutableFile(atPath: executable) {
      if let output = run(executable, ["ip", "-4"]), let first = output.split(whereSeparator: \.isNewline).first,
        (try? IPv4Peer(String(first))) != nil {
        ip = String(first)
        if let json = run(executable, ["status", "--json"]), let data = json.data(using: .utf8),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let own = value["Self"] as? [String: Any] { dns = own["DNSName"] as? String }
        break
      }
    }
    let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
    let primary = global?["PrimaryInterface"] as? String
    var list: UnsafeMutablePointer<ifaddrs>?
    var lan: String?
    if getifaddrs(&list) == 0 {
      defer { freeifaddrs(list) }
      var cursor = list
      while let entry = cursor {
        let item = entry.pointee
        if let address = item.ifa_addr, address.pointee.sa_family == AF_INET,
          String(cString: item.ifa_name) == primary {
          lan = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            String(cString: inet_ntoa($0.pointee.sin_addr))
          }
          break
        }
        cursor = item.ifa_next
      }
    }
    return ConnectionAddresses(tailscaleIP: ip, magicDNS: dns, lanIP: lan)
  }
  private static func run(_ executable: String, _ arguments: [String]) -> String? {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    var output = Data()
    let lock = NSLock(), readDone = DispatchGroup()
    do { try process.run() } catch { return nil }
    readDone.enter()
    DispatchQueue.global(qos: .utility).async {
      defer { readDone.leave() }
      while true {
        let chunk = pipe.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        lock.withLock { if output.count < 4_194_304 { output.append(chunk) } }
      }
    }
    let deadline = Date().addingTimeInterval(3)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      return nil
    }
    process.waitUntilExit()
    guard readDone.wait(timeout: .now() + 1) == .success else { return nil }
    return lock.withLock {
      return process.terminationStatus == 0 ? String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
  }
}
