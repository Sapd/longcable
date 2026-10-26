// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import Foundation

// Validate stored records directly: a legacy location-bound target has no label,
// and must retain that identity when named targets are appended later.
private func validateTargetCatalog(_ items: [TargetConfig]) throws {
  guard items.count <= 16 else { throw USBError.message("The 16-device limit was reached") }
  var identities = Set<String>(), labels = Set<String>()
  for (index, item) in items.enumerated() {
    let validLabel = !item.label.isEmpty && item.label.count <= 32
      && item.label.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
      }
    guard validLabel || (index == 0 && item.label.isEmpty) else {
      throw USBError.message("Invalid identity label in saved device setup")
    }
    let identity = "\(item.vendor):\(item.product):\(item.location)"
    guard identities.insert(identity).inserted,
      item.label.isEmpty || labels.insert(item.label).inserted
    else { throw USBError.message("Ambiguous duplicate target in saved device setup") }
  }
}
func validateSavedTargets(_ saved: [TargetConfig], base: [TargetConfig]) throws {
  try validateTargetCatalog(saved)
  guard saved.count >= base.count, Array(saved.prefix(base.count)) == base else {
    throw USBError.message("Saved device setup conflicts with startup configuration. Existing devices cannot be reordered or changed.")
  }
}
// Either source may contain an appended suffix. Existing slots must agree.
func reconciledTargets(saved: [TargetConfig], startup: [TargetConfig]) throws -> [TargetConfig] {
  try validateTargetCatalog(saved)
  try validateTargetCatalog(startup)
  let sharedCount = min(saved.count, startup.count)
  guard Array(saved.prefix(sharedCount)) == Array(startup.prefix(sharedCount)) else {
    throw USBError.message("Saved device setup conflicts with startup configuration. Existing devices cannot be reordered or changed.")
  }
  return saved.count >= startup.count ? saved : startup
}
struct StorePaths {
  let targets: String
  let state: String
  let launchDaemon: String
  static let live = StorePaths(targets: Paths.targets, state: Paths.state,
    launchDaemon: "/Library/LaunchDaemons/org.sapd.longcable.plist")
}
// fileExists masks permission failures. Only a genuinely absent path uses defaults.
func readStoredFile(_ path: String, description: String) throws -> Data? {
  var info = stat()
  if lstat(path, &info) != 0 {
    if errno == ENOENT { return nil }
    throw USBError.message("Could not read saved \(description): \(String(cString: strerror(errno)))")
  }
  do { return try Data(contentsOf: URL(fileURLWithPath: path)) }
  catch { throw USBError.message("Could not read saved \(description): \(error)") }
}
func savedTargets(at store: StorePaths) throws -> [TargetConfig]? {
  guard let data = try readStoredFile(store.targets, description: "device setup") else { return nil }
  do {
    let saved = try JSONDecoder().decode([TargetConfig].self, from: data)
    try validateTargetCatalog(saved)
    return saved
  } catch { throw USBError.message("Could not load saved device setup: \(error)") }
}
func savedSharing(at store: StorePaths) throws -> [String: Bool] {
  guard let data = try readStoredFile(store.state, description: "sharing settings") else { return [:] }
  do { return try JSONDecoder().decode([String: Bool].self, from: data) }
  catch { throw USBError.message("Could not load saved sharing settings: \(error)") }
}
private func startupTargets(at store: StorePaths) throws -> [TargetConfig] {
  guard let data = try readStoredFile(store.launchDaemon, description: "service configuration") else { return [] }
  guard let dictionary = try PropertyListSerialization.propertyList(from: data, format: nil)
    as? [String: Any], let arguments = dictionary["ProgramArguments"] as? [String], !arguments.isEmpty
  else { throw USBError.message("Existing service configuration is invalid") }
  return try DaemonConfig(arguments: Array(arguments.dropFirst())).targets
}
func preflightInstall(config: DaemonConfig, store: StorePaths) throws -> [TargetConfig] {
  let oldStartup = try startupTargets(at: store)
  let existing = try reconciledTargets(saved: savedTargets(at: store) ?? [], startup: oldStartup)
  _ = try savedSharing(at: store)
  return try reconciledTargets(saved: existing, startup: config.targets)
}
public func preflightInstall(arguments: [String]) throws {
  _ = try preflightInstall(config: DaemonConfig(arguments: arguments), store: .live)
}
func appendedDevice(_ device: LocalUSBDevice, to existing: [TargetConfig]) throws -> [TargetConfig]
{
  guard let vendor = UInt16(device.vendor, radix: 16),
    let product = UInt16(device.product, radix: 16),
    let location = UInt32(device.location, radix: 16), existing.count < 16
  else {
    throw USBError.message("Invalid device or the 16-device limit was reached")
  }
  guard vendor != 0x05ac else {
    throw USBError.message("Apple devices require an explicit VID/PID/LOCATION startup configuration")
  }
  guard !existing.contains(where: {
    $0.vendor == vendor && $0.product == product && $0.location == location
      || (!device.serial.isEmpty && $0.vendor == vendor && $0.product == product
          && $0.hardwareSerial == device.serial)
  }) else {
    throw USBError.message("This device is already remembered. Use its existing sharing switch.")
  }
  let baseLabel = String(format: "USB%04X%04X", vendor, product)
  var label = baseLabel
  var suffix = 2
  while existing.contains(where: { $0.label == label }) {
    label = baseLabel + String(suffix)
    suffix += 1
  }
  let result = existing + [TargetConfig(vendor: vendor, product: product,
    location: location, label: label,
    hardwareSerial: device.serial.isEmpty ? nil : device.serial)]
  try validateSavedTargets(result, base: existing)
  return result
}

public func preserveStartupDevices() throws {
  guard geteuid() == 0 else { throw USBError.message("Administrator privileges required") }
  try preserveStartupDevices(store: .live)
}
func preserveStartupDevices(store: StorePaths) throws {
  let existing = try savedTargets(at: store)
  let catalog = try reconciledTargets(saved: existing ?? [], startup: startupTargets(at: store))
  _ = try savedSharing(at: store)
  if existing != catalog {
    try JSONEncoder().encode(catalog).write(to: URL(fileURLWithPath: store.targets), options: .atomic)
    chmod(store.targets, 0o600)
  }
}

func addingConnectedDevice(
  _ selected: LocalUSBDevice, inventory: [LocalUSBDevice], to existing: [TargetConfig]
) throws -> [TargetConfig] {
  guard let connected = inventory.first(where: {
    $0.vendor == selected.vendor && $0.product == selected.product
      && $0.location == selected.location
  }) else {
    throw USBError.message("Device disconnected. Plug it in before sharing it.")
  }
  guard !existing.contains(where: {
    resolvedTarget($0, configured: existing, devices: inventory).matches(connected)
  }) else {
    throw USBError.message("This device is already remembered. Use its existing sharing switch.")
  }
  return try appendedDevice(connected, to: existing)
}
