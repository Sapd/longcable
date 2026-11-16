// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

public struct MicInput: Identifiable, Hashable, Sendable {
  public let id: String  // Core Audio device UID (AVCaptureDevice.uniqueID)
  public let name: String
}

// Records one Mac input through the shared capture path (never exclusive), and
// delivers mono Int16 samples at 48 kHz. macOS converts from whatever the device
// runs at, including mid-stream changes such as AirPods switching profile.
public final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
  public static func inputs() -> [MicInput] {
    discovery().devices.map { MicInput(id: $0.uniqueID, name: $0.localizedName) }
  }
  public static var defaultInputUID: String? { AVCaptureDevice.default(for: .audio)?.uniqueID }

  private static func discovery() -> AVCaptureDevice.DiscoverySession {
    var types: [AVCaptureDevice.DeviceType] = [.externalUnknown]
    if #available(macOS 14.0, *) { types.append(.microphone) } else { types.append(.builtInMicrophone) }
    return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified)
  }

  private let deviceUID: String?
  private let onFailure: (String) -> Void
  // Starting, stopping and reacting to device changes run here, one at a time,
  // so a stop can never be followed by a session starting behind its back.
  private let lifecycle = DispatchQueue(label: "org.sapd.longcable.mic-capture.lifecycle")
  private let samples = DispatchQueue(label: "org.sapd.longcable.mic-capture.samples")
  private let lock = NSLock()  // guards handler, read on the sample queue
  private var handler: ((UnsafeBufferPointer<Int16>) -> Void)?
  // On `lifecycle` only.
  private var session: AVCaptureSession?
  private var defaultListener: AudioObjectPropertyListenerBlock?
  private var observers = [NSObjectProtocol]()
  private var scratch = [Int16]()  // on `samples` only

  // nil follows the Mac's default input, also when it changes while recording.
  // onFailure reports problems that happen after start (device unplugged, …).
  public init(deviceUID: String?, onFailure: @escaping (String) -> Void = { _ in }) {
    self.deviceUID = deviceUID
    self.onFailure = onFailure
  }
  // No other reference exists any more, so no queue hop: deinit may even run on
  // `lifecycle` itself when a listener held the last reference.
  deinit { stopLocked() }

  public func start(_ onSamples: @escaping (UnsafeBufferPointer<Int16>) -> Void) throws {
    try lifecycle.sync {
      stopLocked()
      lock.withLock { handler = onSamples }
      do { try startSessionLocked() } catch { stopLocked(); throw error }
      if deviceUID == nil { listenForDefaultChanges() }
    }
  }

  public func stop() { lifecycle.sync { stopLocked() } }

  var isRecording: Bool { lifecycle.sync { session != nil } }

  // Test seam: installing a session is refused once stopped.
  func install(_ session: AVCaptureSession) -> Bool { lifecycle.sync { installLocked(session) } }

  private func stopLocked() {
    stopListening()
    lock.withLock { handler = nil }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    session?.stopRunning()
    session = nil
  }

  private func installLocked(_ new: AVCaptureSession) -> Bool {
    // stop() clears the handler first; nobody would own a session stored after it.
    guard lock.withLock({ handler != nil }) else { return false }
    session?.stopRunning()
    session = new
    return true
  }

  private func startSessionLocked() throws {
    let device: AVCaptureDevice
    if let deviceUID {
      guard let chosen = AVCaptureDevice(uniqueID: deviceUID) else { throw MicCaptureError.notConnected }
      device = chosen
    } else {
      guard let fallback = AVCaptureDevice.default(for: .audio) else { throw MicCaptureError.noInput }
      device = fallback
    }
    let input = try AVCaptureDeviceInput(device: device)
    let output = AVCaptureAudioDataOutput()
    output.audioSettings = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 48_000,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    output.setSampleBufferDelegate(self, queue: samples)
    let new = AVCaptureSession()
    new.beginConfiguration()
    guard new.canAddInput(input), new.canAddOutput(output) else {
      throw MicCaptureError.unusable(device.localizedName)
    }
    new.addInput(input)
    new.addOutput(output)
    new.commitConfiguration()
    guard installLocked(new) else { return }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = [
      NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
        object: new, queue: nil) { [weak self] note in
          let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
          self?.onFailure("\(device.localizedName) stopped: \(error.map { "\($0.localizedDescription)" } ?? "unknown error")")
        },
      NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
        object: device, queue: nil) { [weak self] _ in
          // The default input is followed by the listener; a chosen one is reported.
          if self?.deviceUID != nil { self?.onFailure("\(device.localizedName) was disconnected") }
        },
    ]
    new.startRunning()
  }

  private func listenForDefaultChanges() {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    // Runs on `lifecycle`, so it is ordered with start and stop.
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self, self.lock.withLock({ self.handler != nil }) else { return }
      do { try self.startSessionLocked() }
      catch { self.onFailure("Could not switch to the new default input: \(error)") }
    }
    if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, lifecycle, block) == noErr {
      defaultListener = block
    }
  }
  private func stopListening() {
    guard let block = defaultListener else { return }
    defaultListener = nil
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, lifecycle, block)
  }

  public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection) {
    guard let handler = lock.withLock({ handler }),
      let block = CMSampleBufferGetDataBuffer(sampleBuffer),
      let format = CMSampleBufferGetFormatDescription(sampleBuffer),
      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
      asbd.mSampleRate == 48_000, asbd.mChannelsPerFrame == 1, asbd.mBitsPerChannel == 16
    else { return }
    let count = CMBlockBufferGetDataLength(block) / 2
    guard count > 0 else { return }
    if scratch.count < count { scratch = [Int16](repeating: 0, count: count) }
    let status = scratch.withUnsafeMutableBytes { raw in
      CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 2, destination: raw.baseAddress!)
    }
    guard status == kCMBlockBufferNoErr else { return }
    scratch.withUnsafeBufferPointer { handler(UnsafeBufferPointer(rebasing: $0[0..<count])) }
  }
}

public enum MicCaptureError: Error, CustomStringConvertible {
  case noInput
  case notConnected
  case unusable(String)
  public var description: String {
    switch self {
    case .noInput: return "This Mac has no microphone input"
    case .notConnected: return "The chosen microphone is not connected"
    case .unusable(let name): return "\(name) cannot be recorded"
    }
  }
}
