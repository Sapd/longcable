// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation

// Mono Int16 samples between the Mac's audio clock (writer) and the USB frame
// clock (reader). An asynchronous UAC1 IN endpoint may send 47, 48 or 49 samples
// per 1 ms packet; choosing by fill level keeps the buffer near `target` without
// resampling.
final class MicBuffer {
  static let target = 960, band = 96, maximum = 4800  // 20 ms, ±2 ms, 100 ms
  private let lock = NSLock()
  private var ring = [Int16](repeating: 0, count: MicBuffer.maximum)
  private var head = 0, count = 0
  private var priming = true

  var fill: Int { lock.withLock { count } }

  func write(_ samples: [Int16]) { samples.withUnsafeBufferPointer { write($0) } }
  func write(_ samples: UnsafeBufferPointer<Int16>) {
    lock.withLock {
      for sample in samples.suffix(Self.maximum) {
        if count == Self.maximum { head = (head + 1) % Self.maximum; count -= 1 }
        ring[(head + count) % Self.maximum] = sample
        count += 1
      }
    }
  }

  // Writes one packet of little-endian samples; returns the byte count.
  func readPacket(into destination: UnsafeMutableRawPointer, capacityBytes: Int) -> Int {
    lock.withLock {
      if priming && count >= Self.target { priming = false }
      var size = 48
      if !priming {
        if count > Self.target + Self.band { size = 49 }
        else if count < Self.target - Self.band { size = 47 }
      }
      size = min(size, max(0, capacityBytes / 2))
      let real = priming ? 0 : min(size, count)
      let out = destination.bindMemory(to: UInt8.self, capacity: size * 2)
      for i in 0..<size {
        let sample = i < real ? UInt16(bitPattern: ring[(head + i) % Self.maximum]) : 0
        out[i * 2] = UInt8(sample & 0xff)
        out[i * 2 + 1] = UInt8(sample >> 8)
      }
      head = (head + real) % Self.maximum
      count -= real
      if !priming && count == 0 { priming = true }
      return size * 2
    }
  }

  func reset() { lock.withLock { head = 0; count = 0; priming = true } }
}
