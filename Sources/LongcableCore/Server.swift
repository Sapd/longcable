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
  private let peerLock = NSLock()
  private var extraPeers = [String]()
  private var refused = [RefusedPeer]()
  private var targetStorage: [Target]
  private let targetLock = NSLock()
  var targets: [Target] { targetLock.withLock { targetStorage } }
  private let protocolTest: Bool
  // Development: serve only the virtual mic, in memory, without root or local sockets.
  private var virtualMicOnly = false
  private var tone: ToneSource?
  let started = Date()
  let clients = DispatchGroup()
  let slots = DispatchSemaphore(value: 16)
  let lifecycle = NSLock(), settings = NSLock()
  var connections = [Int32: Connection]()
  var listener: Int32 = -1
  var stopped = false
  var control: ControlServer?
  var signals = [DispatchSourceSignal]()
  let virtualMic: VirtualMicTarget
  // Devices once seen as microphones (by label, or bus ID), kept across restarts
  // so an unplugged or handed-over microphone stays in the Microphone card.
  private var knownMicrophones = Set<String>()
  private let microphonesLock = NSLock()
  private(set) var audioHub: AudioChannelHub!
  private var audioServer: AudioChannelServer?
  public convenience init(config: DaemonConfig) {
    self.init(config: config, store: .live, consoleUID: currentConsoleUID, inventory: { discoverUSBDevices(allowedAppleDevices: config.targets) })
  }
  init(config: DaemonConfig, store: StorePaths, consoleUID: @escaping () -> uid_t?,
       inventory: @escaping () -> [LocalUSBDevice] = { discoverUSBDevices() },
       log: @escaping (String) -> Void = { EventLog.shared.write($0) },
       makeMicDevice: ((MicBuffer, String, @escaping (Bool) -> Void) -> SessionDevice)? = nil) {
    virtualMic = VirtualMicTarget(buffer: MicBuffer(), serial: VirtualMic.macSerial(), makeDevice: makeMicDevice)
    self.config = config
    self.store = store
    self.consoleUID = consoleUID
    self.inventory = inventory
    self.log = log
    protocolTest = false
    targetStorage = []
    targetStorage = config.targets.enumerated().map { makeTarget($0.element, slot: $0.offset) }
    wireAudio()
  }
  // The hub accepts only root or the signed-in user, like local controls.
  private func wireAudio() {
    let mic = virtualMic, consoleUID = consoleUID
    let hub = AudioChannelHub(
      allowed: { uid in uid == 0 || (consoleUID().map { $0 > 0 && $0 != UInt32.max && uid == $0 } ?? false) },
      onSamples: { mic.buffer.write($0) },
      onConnected: { mic.sourceConnected = $0 })
    audioHub = hub
    mic.onStreaming = { hub.setStreaming($0) }
  }
  private func makeTarget(_ config: TargetConfig, slot: Int) -> Target {
    Target(config, slot: slot, context: { [weak self] in
      guard let self else { return ([config], []) }
      return (self.targets.map { $0.config }, self.inventory())
    })
  }
  private init(testConfig: DaemonConfig, micSerial: String = VirtualMic.macSerial()) {
    config = testConfig
    store = .live
    consoleUID = currentConsoleUID
    inventory = { discoverUSBDevices() }
    log = { EventLog.shared.write($0) }
    protocolTest = true
    targetStorage = []
    virtualMic = VirtualMicTarget(buffer: MicBuffer(), serial: micSerial)
    wireAudio()
  }
  // Complete validation before exposing a listener or replacing the in-memory catalog.
  func loadPersistentState() throws {
    let peers = try savedPeers(at: store)
    let saved = try savedTargets(at: store)
    let catalog = try reconciledTargets(saved: saved ?? [], startup: config.targets)
    let enabled = try savedSharing(at: store)
    if saved != catalog {
      try JSONEncoder().encode(catalog).write(to: URL(fileURLWithPath: store.targets), options: .atomic)
      chmod(store.targets, 0o600)
    }
    let restored = catalog.enumerated().map { makeTarget($0.element, slot: $0.offset) }
    for target in restored {
      if let value = enabled[target.config.label.isEmpty ? target.busID : target.config.label] {
        target.setEnabled(value)
      }
    }
    peerLock.withLock { extraPeers = peers }
    targetLock.withLock { targetStorage = restored }
    virtualMic.setEnabled(savedVirtualMic(at: store, log: log))
    if let data = try? readStoredFile(store.microphones, description: "microphone list"),
      let keys = try? JSONDecoder().decode([String].self, from: data) {
      microphonesLock.withLock { knownMicrophones = Set(keys) }
    }
  }
  func status() -> ServerStatus {
    let snapshot = targets
    let detected = visibleDevices(inventory(), configured: snapshot.map { $0.config })
    let matching = snapshot.map { $0.matchingConfig }
    var devices = zip(snapshot, matching).map { target, match in
      let seen = detected.first { match.matches($0) }
      return target.snapshot(present: seen != nil, seen: seen)
    }
    rememberMicrophones(&devices, targets: snapshot)
    return ServerStatus(
      version: "Swift 1.0", started: started, listen: config.listen, peer: config.peer,
      devices: devices,
      refusedPeers: peerLock.withLock { refused },
      allowedPeers: peerLock.withLock { mergedPeers(startup: config.peer, extra: extraPeers) },
      availableDevices: detected.filter { device in !matching.contains { $0.matches(device) } },
      virtualMic: virtualMic.snapshot()
    )
  }

  private func rememberMicrophones(_ devices: inout [DeviceStatus], targets: [Target]) {
    var changed = false
    let known: Set<String> = microphonesLock.withLock {
      for (index, target) in targets.enumerated() where index < devices.count {
        let key = target.config.label.isEmpty ? target.busID : target.config.label
        if devices[index].audio == true {
          if knownMicrophones.insert(key).inserted { changed = true }
        } else if knownMicrophones.contains(key) {
          devices[index].audio = true
        }
      }
      return knownMicrophones
    }
    if changed && !protocolTest && !virtualMicOnly {
      do {
        try JSONEncoder().encode(known.sorted()).write(to: URL(fileURLWithPath: store.microphones), options: .atomic)
        chmod(store.microphones, 0o600)
      } catch { log("Could not save the microphone list: \(error)") }
    }
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
  // A server that offers only Longcable Mic, for testing against Windows without
  // touching the installed service (run it on another port).
  public static func virtualMicDevelopment(config: DaemonConfig) -> USBServer {
    // Its own serial, so Windows keeps it apart from the installed service's mic.
    let server = USBServer(testConfig: config, micSerial: VirtualMic.macSerial() + "-test")
    server.virtualMicOnly = true
    server.virtualMic.setEnabled(true)
    return server
  }
  public func useTestTone(_ frequency: Double) {
    let source = ToneSource(frequency: frequency, buffer: virtualMic.buffer)
    tone = source
    virtualMic.onStreaming = { $0 ? source.start() : source.stop() }
  }
  // Called with true when Windows starts streaming and false when it stops.
  public func onMicStreaming(_ handler: @escaping (Bool) -> Void) { virtualMic.onStreaming = handler }
  public func feedMic(_ samples: UnsafeBufferPointer<Int16>) { virtualMic.buffer.write(samples) }
  public static func loopbackTest() throws {
    try USBServer(testConfig: DaemonConfig(loopbackTest: ())).run()
  }
  public func run() throws {
    guard protocolTest || virtualMicOnly || geteuid() == 0 else {
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
    if !protocolTest && !virtualMicOnly {
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
    address.sin_port = config.port.bigEndian
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
        "Could not bind \(config.listen):\(config.port): \(String(cString:strerror(errno)))")
    }
    lifecycle.withLock { listener = fd }
    defer {
      stop()
      control?.stop()
      audioServer?.stop()
      _ = clients.wait(timeout: .now() + 10)
      for source in signals { source.cancel() }
    }
    if virtualMicOnly {
      print("Longcable Mic development server on \(config.listen):\(config.port), peers \(config.peer)")
    }
    if !protocolTest && !virtualMicOnly {
      control = try ControlServer { [weak self] request, uid in
        guard let self = self else {
          return ControlReply(ok: false, message: "Server stopping", status: nil)
        }
        return self.handleControl(request, uid: uid)
      }
      control?.start()
      do {
        audioServer = try AudioChannelServer(hub: audioHub)
        audioServer?.start()
      } catch { log("Microphone socket unavailable: \(error)") }
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
      guard acceptPeer(peer.sin_addr) else {
        c.closeSocket()
        continue
      }
      guard slots.wait(timeout: .now()) == .success else {
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
  // Admission and refused history share one lock with allow/forget updates.
  func acceptPeer(_ address: in_addr, now: Date = Date()) -> Bool {
    peerLock.withLock {
      if config.allowsPeer(address) || extraPeers.contains(where: {
        (try? IPv4Peer($0))?.contains(address) == true
      }) { return true }
      let value = address
      let ip = String(cString: inet_ntoa(value))
      refused.removeAll { $0.address == ip }
      refused.insert(RefusedPeer(address: ip, timestamp: now), at: 0)
      refused = Array(refused.prefix(10))
      return false
    }
  }
  func handleClient(_ c: Connection) {
    // USB/IP requests start with 01 11; the setup script's list request with "GET ".
    guard let start = c.read(4) else { return }
    if start == Data("GET ".utf8) {
      if sharedListAvailable { serveSharedList(c) }
      return
    }
    guard let rest = c.read(4) else { return }
    let header = start + rest
    guard header[0] == 1, header[1] == 0x11, header.u32(4) == 0 else { return }
    let opcode = UInt16(header[2]) << 8 | UInt16(header[3])
    if opcode == 0x8005 {
      var present = [Target]()
      for t in targets where t.isEnabled {
        if t.captureLock.try() {
          _ = t.ensureIdentity()
          t.captureLock.unlock()
        }
        if let service = findDevice(t.matchingConfig) {
          IOObjectRelease(service)
          if t.stateLock.withLock({ t.identity != nil }) { present.append(t) }
        }
      }
      var identities = present.compactMap { target in target.stateLock.withLock { target.identity } }
      if virtualMic.isEnabled, let identity = virtualMic.identity { identities.append(identity) }
      guard c.operation(5, 0) else { return }
      var count = Data(count: 4)
      count.put32(0, UInt32(identities.count))
      guard c.write(count) else { return }
      for identity in identities {
        guard c.write(identity.record), c.write(identity.classes) else { return }
      }
    } else if opcode == 0x8003 {
      guard let bus = c.read(32) else { return }
      var virtualBus = Data(count: 32)
      virtualBus.putString(0, 32, virtualMic.busID)
      if bus == virtualBus {
        guard virtualMic.captureLock.try() else { _ = c.operation(3, 1); return }
        defer { virtualMic.captureLock.unlock() }
        guard virtualMic.begin(c) else { _ = c.operation(3, 1); return }
        Session(virtualMic, c).run()
        return
      }
      guard
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
  // Bus IDs this Mac shares, whether plugged in or not, plus Longcable Mic when on.
  // USB/IP's own device list only has what is plugged in, so the Windows setup
  // script can't tell "unplugged" from "no longer shared" without this.
  var sharedBusIDs: [String] {
    targets.filter(\.isEnabled).map(\.busID) + (virtualMic.isEnabled ? [virtualMic.busID] : [])
      + extraSharedForTesting
  }
  // Development server only: pretend these are shared but unplugged, or behave
  // like a service from before the shared list.
  var extraSharedForTesting = [String]()
  var sharedListAvailable = true
  var sharedListCutForTesting = false
  var sharedListIDForTesting: String?
  public func developmentOptions(alsoShared: [String], noSharedList: Bool, brokenSharedList: Bool = false,
                                 sharedListID: String? = nil) {
    extraSharedForTesting = alsoShared
    sharedListAvailable = !noSharedList
    sharedListCutForTesting = brokenSharedList
    sharedListIDForTesting = sharedListID
  }

  // Answers exactly GET /longcable/v1/shared, read with a size and time limit;
  // nothing else is served. Peers were already checked when the connection was
  // accepted. The body ends with "end" so a cut-off reply can't look like an
  // empty list. X-Longcable-Id names this Mac (the same stable, non-reversible id
  // the microphone uses as its serial), so a PC syncing automatically can tell
  // when something else answers at the address.
  func serveSharedList(_ c: Connection) {
    var request = Data("GET ".utf8)
    let deadline = monotonicMS() + 2000
    while request.count < 1024 && monotonicMS() < deadline {
      guard let byte = c.read(1, timeoutMS: 2000) else { return }
      request.append(byte)
      if request.suffix(4) == Data("\r\n\r\n".utf8) || request.suffix(2) == Data("\n\n".utf8) { break }
    }
    guard request.suffix(2) == Data("\n\n".utf8) || request.suffix(4) == Data("\r\n\r\n".utf8) else { return }
    let line = String(decoding: request.prefix { $0 != 0x0d && $0 != 0x0a }, as: UTF8.self)
    let found = line == "GET /longcable/v1/shared HTTP/1.0" || line == "GET /longcable/v1/shared HTTP/1.1"
    let lines = ["longcable 1"] + sharedBusIDs + (sharedListCutForTesting ? [] : ["end"])
    let body = found ? lines.joined(separator: "\n") + "\n" : "not found\n"
    let head = (found ? "HTTP/1.0 200 OK" : "HTTP/1.0 404 Not Found") +
      "\r\nContent-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\n" +
      "X-Longcable-Id: \(sharedListIDForTesting ?? virtualMic.serial)\r\nConnection: close\r\n\r\n"
    _ = c.write(Data((head + body).utf8))
  }

  func handleControl(_ request: ControlRequest, uid: uid_t) -> ControlReply {
    if request.action == "status" { return ControlReply(ok: true, message: "", status: status()) }
    let signedIn = consoleUID()
    guard uid == 0 || (signedIn.map { $0 > 0 && $0 != UInt32.max && uid == $0 } ?? false) else {
      return ControlReply(
        ok: false, message: "Only the signed-in Mac user can change sharing", status: nil)
    }
    return settings.withLock {
      if request.action == "allow-peer" || request.action == "forget-peer" {
        do {
          guard let peer = request.peer else { throw USBError.message("Choose an IPv4 or CIDR peer") }
          _ = try IPv4Peer(peer)
          try peerLock.withLock {
            var updated = extraPeers
            updated.removeAll { $0 == peer }
            if request.action == "allow-peer" {
              guard updated.count < 256 else { throw USBError.message("The 256 extra-peer limit was reached") }
              updated.append(peer)
            }
            try savePeers(updated, at: store)
            extraPeers = updated
            refused.removeAll { item in
              var address = in_addr()
              return inet_pton(AF_INET, item.address, &address) == 1
                && (config.allowsPeer(address) || updated.contains { (try? IPv4Peer($0))?.contains(address) == true })
            }
          }
          return ControlReply(ok: true,
            message: "Allowed peers updated. Clients can retry now. Startup peers remain allowed.", status: status())
        } catch { return ControlReply(ok: false, message: String(describing: error), status: nil) }
      }
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
            targetStorage.append(makeTarget(newConfig.last!, slot: targetStorage.count))
          }
          log("Added device \(newConfig.last!.label)")
          return ControlReply(
            ok: true, message: "Device remembered. Windows will connect automatically.",
            status: status())
        } catch { return ControlReply(ok: false, message: String(describing: error), status: nil) }
      }
      if request.action == "virtual-mic" {
        guard let enabled = request.enabled else {
          return ControlReply(ok: false, message: "Say whether to turn the virtual microphone on or off", status: nil)
        }
        do { try saveVirtualMic(enabled, at: store) }
        catch {
          return ControlReply(ok: false, message: "Could not save the microphone setting: \(error)", status: nil)
        }
        virtualMic.setEnabled(enabled)
        log("Virtual microphone \(enabled ? "on" : "off")")
        return ControlReply(ok: true, message: enabled ? "Longcable Mic is on" : "Longcable Mic is off",
          status: status())
      }
      if request.action == "reconnect" && request.busID == virtualMic.busID {
        guard virtualMic.isEnabled else {
          return ControlReply(ok: false, message: "Longcable Mic is off", status: nil)
        }
        virtualMic.reconnect()
        return ControlReply(ok: true, message: "Reconnect requested. Windows will retry automatically.",
          status: status())
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
