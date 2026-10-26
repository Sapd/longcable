// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import ExceptionGuard
import Foundation

public enum USBError: Error, CustomStringConvertible {
  case message(String)
  public var description: String {
    if case .message(let s) = self { return s }
    return "USB error"
  }
}
func guarded<T>(_ operation: () throws -> T) throws -> T {
  var outcome: Result<T, Error>?
  // The block runs synchronously; no Swift exception crosses the Objective-C boundary.
  try withoutActuallyEscaping(operation) { block in
    var exception: NSError?
    guard USBGuard({ outcome = Result { try block() } }, &exception) else {
      throw exception ?? USBError.message("USB exception") as NSError
    }
  }
  return try outcome!.get()
}

extension NSLock {
  @discardableResult func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
public struct TargetConfig: Codable, Equatable, Sendable {
  public var vendor: UInt16
  public var product: UInt16
  public var location: UInt32
  public var label: String
  public var hardwareSerial: String?
  public var portBound: Bool?
  public init(vendor: UInt16, product: UInt16, location: UInt32, label: String,
              hardwareSerial: String? = nil, portBound: Bool? = nil) {
    self.vendor = vendor
    self.product = product
    self.location = location
    self.label = label
    self.hardwareSerial = hardwareSerial
    self.portBound = portBound
  }
  public func matches(vendor: UInt32, product: UInt32, location: UInt32, serial: String = "") -> Bool {
    UInt32(self.vendor) == vendor && UInt32(self.product) == product
      && (self.vendor == 0x05ac || label.isEmpty
        ? self.location == location
        : (hardwareSerial.map { $0 == serial } ?? (portBound == true ? self.location == location : true)))
  }
}
public struct DaemonConfig {
  public let listen: String
  public let peer: String
  public let targets: [TargetConfig]
  public var allowsAnyPeer: Bool { peer == "any" }
  public var securityWarning: String? {
    allowsAnyPeer ? "WARNING: ANY PEER CAN CAPTURE SHARED USB DEVICES. USB/IP HAS NO AUTHENTICATION OR ENCRYPTION. Use a trusted LAN or Tailscale." : nil
  }
  public func allowsPeer(_ address: in_addr) -> Bool {
    allowsAnyPeer || peer.split(separator: ",").contains { value in
      var allowed = in_addr()
      return inet_pton(AF_INET, String(value), &allowed) == 1 && allowed.s_addr == address.s_addr
    }
  }
  init(loopbackTest: Void) {
    listen = "127.0.0.1"
    peer = "127.0.0.1"
    targets = []
  }
  public init(arguments: [String]) throws {
    let legacy = arguments.count == 5
    guard
      arguments.count == 2 || legacy
        || (arguments.count >= 6 && (arguments.count - 2) % 4 == 0
          && (arguments.count - 2) / 4 <= 16)
    else { throw USBError.message("Expected LISTEN_IPV4 PEER_IPV4[,PEER_IPV4...]|any [VID PID LOCATION LABEL ...] ") }
    var a = in_addr()
    guard inet_pton(AF_INET, arguments[0], &a) == 1 else {
      throw USBError.message("An IPv4 listen address is required")
    }
    let peers = arguments[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard arguments[1] == "any" || (!peers.isEmpty && Set(peers).count == peers.count && peers.allSatisfy({ value in
      var address = in_addr()
      return inet_pton(AF_INET, value, &address) == 1 && address.s_addr != 0
        && address.s_addr != UInt32.max
    })) else { throw USBError.message("Supply one or more unique peer IPv4s separated by commas, or any") }
    listen = arguments[0]
    peer = arguments[1]
    var items = [TargetConfig]()
    for i in 0..<(legacy ? 1 : (arguments.count - 2) / 4) {
      let n = 2 + i * 4
      guard let v = UInt16(arguments[n], radix: 16), let p = UInt16(arguments[n + 1], radix: 16),
        let l = UInt32(arguments[n + 2], radix: 16)
      else { throw USBError.message("Invalid USB identifiers") }
      let label = legacy ? "" : arguments[n + 3]
      guard
        legacy
          || (!label.isEmpty && label.count <= 32
            && label.utf8.allSatisfy {
              (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            })
      else { throw USBError.message("Invalid identity label") }
      guard
        !items.contains(where: {
          ($0.vendor == v && $0.product == p && $0.location == l)
            || (!legacy && $0.label == label)
        })
      else { throw USBError.message("Ambiguous duplicate target") }
      items.append(TargetConfig(vendor: v, product: p, location: l, label: label))
    }
    targets = items
  }
}
public struct DeviceStatus: Codable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var model: String
  public var serial: String
  public var enabled: Bool
  public var state: String
  public var location: String
  public var completed: UInt64
  public var bytes: UInt64
  public var errors: UInt64
  public var pending: Int
  public var lastActivity: Date?
  public var lastError: String?
}
public struct ServerStatus: Codable, Sendable {
  public var version: String
  public var started: Date
  public var listen: String
  public var peer: String
  public var devices: [DeviceStatus]
  public var availableDevices: [LocalUSBDevice]? = nil
}
public struct ControlRequest: Codable, Sendable {
  public var action: String
  public var busID: String?
  public var device: LocalUSBDevice?
  public init(action: String, busID: String? = nil, device: LocalUSBDevice? = nil) {
    self.action = action
    self.busID = busID
    self.device = device
  }
}
public struct ControlReply: Codable, Sendable {
  public var ok: Bool
  public var message: String
  public var status: ServerStatus?
}
public enum Paths {
  public static let directory = "/var/run/longcable"
  public static let socket = directory + "/control.sock"
  public static let state = "/Library/Application Support/Longcable/sharing.json"
  public static let targets = "/Library/Application Support/Longcable/targets.json"
  public static let log = "/Library/Logs/Longcable/swift-server.log"
}
final class EventLog {
  static let shared = EventLog()
  private let lock = NSLock()
  func write(_ message: String) {
    lock.withLock {
      let line = "\(ISO8601DateFormatter().string(from:Date())) \(message)\n"
      guard geteuid() == 0 else { return }
      if let attrs = try? FileManager.default.attributesOfItem(atPath: Paths.log),
        let size = attrs[.size] as? NSNumber, size.intValue > 2 * 1024 * 1024
      {
        try? FileManager.default.removeItem(atPath: Paths.log + ".1")
        try? FileManager.default.moveItem(atPath: Paths.log, toPath: Paths.log + ".1")
      }
      if !FileManager.default.fileExists(atPath: Paths.log) {
        FileManager.default.createFile(
          atPath: Paths.log, contents: nil, attributes: [.posixPermissions: 0o644])
      }
      if let handle = FileHandle(forWritingAtPath: Paths.log) {
        defer { try? handle.close() }
        do {
          try handle.seekToEnd()
          try handle.write(contentsOf: Data(line.utf8))
        } catch {}
      }
    }
  }
}
