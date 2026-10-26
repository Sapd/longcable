// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import Foundation
import IOKit

public final class USBServer {
  let config: DaemonConfig
  let store: StorePaths
  let consoleUID: () -> uid_t?
  let inventory: () -> [LocalUSBDevice]
  let log: (String) -> Void
  private var targetStorage: [Target]
  private let targetLock = NSLock()
  var targets: [Target] { targetLock.withLock { targetStorage } }
  private let protocolTest: Bool
  let started = Date()
  let clients = DispatchGroup()
  let slots = DispatchSemaphore(value: 16)
  let lifecycle = NSLock(), settings = NSLock()
  var connections = [Int32: Connection]()
  var listener: Int32 = -1
  var stopped = false
  var control: ControlServer?
  var signals = [DispatchSourceSignal]()
  public convenience init(config: DaemonConfig) {
    self.init(config: config, store: .live, consoleUID: currentConsoleUID, inventory: { discoverUSBDevices(allowedAppleDevices: config.targets) })
  }
  init(config: DaemonConfig, store: StorePaths, consoleUID: @escaping () -> uid_t?,
       inventory: @escaping () -> [LocalUSBDevice] = { discoverUSBDevices() },
       log: @escaping (String) -> Void = { EventLog.shared.write($0) }) {
    self.config = config
    self.store = store
    self.consoleUID = consoleUID
    self.inventory = inventory
    self.log = log
    protocolTest = false
    targetStorage = config.targets.enumerated().map { Target($0.element, slot: $0.offset) }
  }
  private init(testConfig: DaemonConfig) {
    config = testConfig
    store = .live
    consoleUID = currentConsoleUID
    inventory = { discoverUSBDevices() }
    log = { EventLog.shared.write($0) }
    protocolTest = true
    targetStorage = []
  }
  // Complete validation before exposing a listener or replacing the in-memory catalog.
  func loadPersistentState() throws {
    let saved = try savedTargets(at: store)
    let catalog = try reconciledTargets(saved: saved ?? [], startup: config.targets)
    let enabled = try savedSharing(at: store)
    if saved != catalog {
      try JSONEncoder().encode(catalog).write(to: URL(fileURLWithPath: store.targets), options: .atomic)
      chmod(store.targets, 0o600)
    }
    let restored = catalog.enumerated().map { Target($0.element, slot: $0.offset) }
    for target in restored {
      if let value = enabled[target.config.label.isEmpty ? target.busID : target.config.label] {
        target.setEnabled(value)
      }
    }
    targetLock.withLock { targetStorage = restored }
  }
  func status() -> ServerStatus {
    let snapshot = targets
    let detected = visibleDevices(inventory(), configured: snapshot.map { $0.config })
    let configuredModels = Set(
      snapshot.map { String(format: "%04x:%04x", $0.config.vendor, $0.config.product) })
    return ServerStatus(
      version: "Swift 1.0", started: started, listen: config.listen, peer: config.peer,
      devices: snapshot.map { target in
        target.snapshot(
          present: detected.contains { device in
            guard let vendor = UInt32(device.vendor, radix: 16),
              let product = UInt32(device.product, radix: 16),
              let location = UInt32(device.location, radix: 16)
            else { return false }
            return target.config.matches(vendor: vendor, product: product, location: location)
          })
      },
      availableDevices: detected.filter { !configuredModels.contains($0.vendor + ":" + $0.product) }
    )
  }
  func stop() {
    lifecycle.withLock {
      if stopped { return }
      stopped = true
      if listener >= 0 {
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        listener = -1
      }
      for c in connections.values { c.interrupt() }
    }
  }
  public static func loopbackTest() throws {
    try USBServer(testConfig: DaemonConfig(loopbackTest: ())).run()
  }
  public func run() throws {
    guard protocolTest || geteuid() == 0 else {
      throw USBError.message("Administrator privileges required for USB capture")
    }
    if let warning = config.securityWarning {
      fputs(warning + "\n", stderr)
      log(warning)
    }
    signal(SIGPIPE, SIG_IGN)
    var mask = sigset_t()
    sigemptyset(&mask)
    pthread_sigmask(SIG_SETMASK, &mask, nil)
    for sig in [SIGINT, SIGTERM] {
      signal(sig, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
      source.setEventHandler { [weak self] in self?.stop() }
      source.resume()
      signals.append(source)
    }
    if !protocolTest {
      try FileManager.default.createDirectory(
        atPath: "/Library/Logs/Longcable", withIntermediateDirectories: true)
      try FileManager.default.createDirectory(
        atPath: (store.state as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
      try loadPersistentState()
      for target in targets { _ = target.ensureIdentity() }
    }
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw USBError.message("Could not create listener") }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(3240).bigEndian
    _ = inet_pton(AF_INET, config.listen, &address.sin_addr)
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, 4)
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(fd, 8) == 0 else {
      Darwin.close(fd)
      throw USBError.message(
        "Could not bind \(config.listen):3240: \(String(cString:strerror(errno)))")
    }
    lifecycle.withLock { listener = fd }
    defer {
      stop()
      control?.stop()
      _ = clients.wait(timeout: .now() + 10)
      for source in signals { source.cancel() }
    }
    if !protocolTest {
      control = try ControlServer { [weak self] request, uid in
        guard let self = self else {
          return ControlReply(ok: false, message: "Server stopping", status: nil)
        }
        return self.handleControl(request, uid: uid)
      }
      control?.start()
      log(
        "Swift server listening \(config.listen):3240; peer \(config.peer); \(targets.count) targets"
      )
    }
    while !lifecycle.withLock({ stopped }) {
      var peer = sockaddr_in()
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      let client = withUnsafeMutablePointer(to: &peer) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &length) }
      }
      if client < 0 {
        if lifecycle.withLock({ stopped }) { break }
        if errno == EBADF || errno == EINVAL { throw USBError.message("Listener failed") }
        if errno != EINTR { usleep(100_000) }
        continue
      }
      let c = Connection(client)
      guard config.allowsPeer(peer.sin_addr), slots.wait(timeout: .now()) == .success else {
        c.closeSocket()
        continue
      }
      guard c.configureTCP() else {
        c.closeSocket()
        slots.signal()
        continue
      }
      let accepted = lifecycle.withLock { () -> Bool in
        guard !stopped else { return false }
        connections[client] = c
        return true
      }
      guard accepted else {
        c.closeSocket()
        slots.signal()
        continue
      }
      clients.enter()
      DispatchQueue.global(qos: .userInitiated).async { [self, c] in
        defer {
          lifecycle.withLock { connections.removeValue(forKey: client) }
          c.closeSocket()
          slots.signal()
          clients.leave()
        }
        autoreleasepool { handleClient(c) }
      }
    }
  }
  func handleClient(_ c: Connection) {
    guard let header = c.read(8), header[0] == 1, header[1] == 0x11, header.u32(4) == 0 else {
      return
    }
    let opcode = UInt16(header[2]) << 8 | UInt16(header[3])
    if opcode == 0x8005 {
      var present = [Target]()
      for t in targets where t.isEnabled {
        if t.captureLock.try() {
          _ = t.ensureIdentity()
          t.captureLock.unlock()
        }
        if let service = findDevice(t.config) {
          IOObjectRelease(service)
          if t.stateLock.withLock({ t.identity != nil }) { present.append(t) }
        }
      }
      guard c.operation(5, 0) else { return }
      var count = Data(count: 4)
      count.put32(0, UInt32(present.count))
      guard c.write(count) else { return }
      for target in present {
        guard let identity = target.stateLock.withLock({ target.identity }),
          c.write(identity.record), c.write(identity.classes)
        else { return }
      }
    } else if opcode == 0x8003 {
      guard let bus = c.read(32),
        let t = targets.first(where: {
          var expected = Data(count: 32)
          expected.putString(0, 32, $0.busID)
          return bus == expected
        }), t.captureLock.try()
      else {
        _ = c.operation(3, 1)
        return
      }
      defer { t.captureLock.unlock() }
      guard t.begin(c) else {
        _ = c.operation(3, 1)
        return
      }
      guard t.ensureIdentity() else {
        t.ended()
        _ = c.operation(3, 1)
        return
      }
      Session(t, c).run()
    }
  }
  func handleControl(_ request: ControlRequest, uid: uid_t) -> ControlReply {
    if request.action == "status" { return ControlReply(ok: true, message: "", status: status()) }
    let signedIn = consoleUID()
    guard uid == 0 || (signedIn.map { $0 > 0 && $0 != UInt32.max && uid == $0 } ?? false) else {
      return ControlReply(
        ok: false, message: "Only the signed-in Mac user can change sharing", status: nil)
    }
    return settings.withLock {
      if request.action == "add" {
        do {
          guard let selected = request.device else {
            throw USBError.message("Choose a connected device")
          }
          let newConfig = try addingConnectedDevice(
            selected, inventory: inventory(), to: targets.map { $0.config })
          try JSONEncoder().encode(newConfig).write(
            to: URL(fileURLWithPath: store.targets), options: .atomic)
          chmod(store.targets, 0o600)
          targetLock.withLock {
            targetStorage.append(Target(newConfig.last!, slot: targetStorage.count))
          }
          log("Added device \(newConfig.last!.label)")
          return ControlReply(
            ok: true, message: "Device remembered. Windows will connect automatically.",
            status: status())
        } catch { return ControlReply(ok: false, message: String(describing: error), status: nil) }
      }
      guard let target = targets.first(where: { $0.busID == request.busID }) else {
        return ControlReply(ok: false, message: "Unknown device", status: nil)
      }
      switch request.action {
      case "reconnect":
        target.reconnect()
        log("Reconnect requested for \(target.busID)")
      case "share", "unshare":
        // Commit settings before changing the running session; disk failure must be visible.
        var saved = [String: Bool]()
        for t in targets {
          saved[t.config.label.isEmpty ? t.busID : t.config.label] =
            t === target ? request.action == "share" : t.isEnabled
        }
        do {
          try JSONEncoder().encode(saved).write(
            to: URL(fileURLWithPath: store.state), options: .atomic)
          chmod(store.state, 0o600)
        } catch {
          return ControlReply(
            ok: false, message: "Could not save sharing settings: \(error)", status: nil)
        }
        target.setEnabled(request.action == "share")
        log("\(request.action) \(target.busID)")
      default: return ControlReply(ok: false, message: "Unknown action", status: nil)
      }
      return ControlReply(
        ok: true,
        message: request.action == "reconnect"
          ? "Reconnect requested. Windows will retry automatically." : "Sharing updated",
        status: status())
    }
  }
}
