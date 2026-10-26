// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import Foundation
import IOKit

final class Target {
  let config: TargetConfig
  private var rememberedConfig: TargetConfig
  private let matchingLock = NSLock()
  private let context: (() -> ([TargetConfig], [LocalUSBDevice]))?
  var matchingConfig: TargetConfig {
    let (catalog, devices) = context?() ?? ([config], discoverUSBDevices(allowedAppleDevices: [config]))
    return matchingLock.withLock {
      rememberedConfig = resolvedTarget(rememberedConfig, configured: catalog, devices: devices)
      return rememberedConfig
    }
  }
  let busID: String
  let wireID: UInt32
  let captureLock = NSLock()
  let stateLock = NSLock()
  var identity: Identity?
  private var identityRegistryID: UInt64?
  private let registryIdentity: (TargetConfig) -> UInt64?
  private let identityLoader: (TargetConfig, String, UInt32) throws -> Identity
  private var enabled = true
  private var sessionConnection: Connection?
  private var state = "Waiting for device"
  private var completed: UInt64 = 0, bytes: UInt64 = 0, errors: UInt64 = 0
  private var pending = 0
  private var lastActivity: Date?, lastError: String?
  private var location: String
  init(_ config: TargetConfig, slot: Int,
       context: (() -> ([TargetConfig], [LocalUSBDevice]))? = nil,
       registryIdentity: @escaping (TargetConfig) -> UInt64? = deviceRegistryIdentity,
       identityLoader: @escaping (TargetConfig, String, UInt32) throws -> Identity = loadIdentity) {
    self.config = config
    rememberedConfig = config
    self.context = context
    self.registryIdentity = registryIdentity
    self.identityLoader = identityLoader
    busID = "1-\(slot+1)"
    wireID = 0x10001 + UInt32(slot)
    location = String(format: "%08x", config.location)
  }
  var isEnabled: Bool { stateLock.withLock { enabled } }
  func setEnabled(_ value: Bool) {
    stateLock.withLock {
      enabled = value
      if !value {
        sessionConnection?.interrupt()
        state = "Available on this Mac"
      }
    }
  }
  func reconnect() { stateLock.withLock { sessionConnection?.interrupt() } }
  func begin(_ c: Connection) -> Bool {
    stateLock.withLock {
      guard enabled else { return false }
      sessionConnection = c
      state = "Connecting"
      return true
    }
  }
  func attached(_ location: UInt32) {
    stateLock.withLock {
      state = "Connected to Windows"
      self.location = String(format: "%08x", location)
      lastError = nil
    }
  }
  func ended() {
    stateLock.withLock {
      sessionConnection = nil
      pending = 0
      state = enabled ? "Waiting for Windows" : "Available on this Mac"
    }
  }
  func failed(_ error: Error) {
    stateLock.withLock {
      lastError = String(describing: error)
      state = "Waiting for device"
    }
  }
  func transfer(_ count: Int, status: Int32, pending: Int, native: IOReturn) {
    stateLock.withLock {
      self.pending = pending
      completed &+= 1
      bytes &+= UInt64(count)
      lastActivity = Date()
      if status != 0 && status != -104 {
        errors &+= 1
        lastError = String(format: "USB status %d (0x%08x)", status, UInt32(bitPattern: native))
      }
    }
  }
  func queued(_ count: Int) { stateLock.withLock { pending = count } }
  func ensureIdentity() -> Bool {
    // A stable USB/IP slot survives port changes, but descriptors belong to one
    // physical registry entry. Never advertise an old entry after unplug/replug.
    let matching = matchingConfig
    guard let registryID = registryIdentity(matching) else {
      stateLock.withLock { identity = nil; identityRegistryID = nil }
      return false
    }
    if stateLock.withLock({ identity != nil && identityRegistryID == registryID }) { return true }
    stateLock.withLock { identity = nil; identityRegistryID = nil }
    do {
      let value = try identityLoader(matching, busID, wireID)
      guard matchingConfig == matching, registryIdentity(matching) == registryID else { return false }
      stateLock.withLock {
        identity = value
        identityRegistryID = registryID
        if enabled { state = "Waiting for Windows" }
      }
      return true
    } catch { return false }
  }
  func snapshot(present: Bool = true) -> DeviceStatus {
    let pinned = matchingConfig.portBound == true
    return stateLock.withLock {
      DeviceStatus(
        id: busID, name: identity?.name ?? config.label,
        model: String(format: "%04x:%04x", config.vendor, config.product),
        serial: identity?.serial ?? config.label, enabled: enabled,
        state: present ? state : "Not plugged in",
        location: location, completed: completed, bytes: bytes, errors: errors, pending: pending,
        lastActivity: lastActivity, lastError: pinned && !present
          ? "Identical device: bound to its USB port. Plug it back into the same port or share it again."
          : lastError)
    }
  }
}

func deviceRegistryIdentity(_ config: TargetConfig) -> UInt64? {
  guard let service = findDevice(config) else { return nil }
  defer { IOObjectRelease(service) }
  var value: UInt64 = 0
  guard IORegistryEntryGetRegistryEntryID(service, &value) == KERN_SUCCESS else { return nil }
  return value
}
