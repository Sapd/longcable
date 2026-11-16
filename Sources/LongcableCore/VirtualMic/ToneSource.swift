// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation

// Development source for the virtual microphone: a sine tone written in real
// time (by the Mac's clock), so Windows recordings can be checked for pitch and gaps.
final class ToneSource {
  private let frequency: Double
  private let buffer: MicBuffer
  private let clock: () -> Int64
  private let lock = NSLock()
  private var phase = 0.0
  private var running = false
  private var startedAt: Int64 = 0, produced: Int64 = 0
  private var timer: DispatchSourceTimer?

  init(frequency: Double, buffer: MicBuffer, clock: @escaping () -> Int64 = monotonicMS,
       startTimer: Bool = true) {
    self.frequency = frequency
    self.buffer = buffer
    self.clock = clock
    if startTimer {
      let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "org.sapd.longcable.tone"))
      source.schedule(deadline: .now(), repeating: .milliseconds(10))
      source.setEventHandler { [weak self] in self?.tick() }
      timer = source
      source.resume()
    }
  }
  deinit { timer?.cancel() }

  func generate(count: Int) -> [Int16] {
    lock.withLock {
      let step = 2 * Double.pi * frequency / Double(VirtualMic.sampleRate)
      return (0..<count).map { _ in
        defer { phase = (phase + step).truncatingRemainder(dividingBy: 2 * Double.pi) }
        return Int16(sin(phase) * Double(Int16.max) * 0.25)
      }
    }
  }

  func start() { lock.withLock { running = true; startedAt = clock(); produced = 0 } }
  func stop() { lock.withLock { running = false } }

  func tick() {
    let count: Int = lock.withLock {
      guard running else { return 0 }
      let due = (clock() - startedAt) * Int64(VirtualMic.sampleRate / 1000)
      defer { produced = due }
      return Int(due - produced)
    }
    if count > 0 { buffer.write(generate(count: count)) }
  }
}
