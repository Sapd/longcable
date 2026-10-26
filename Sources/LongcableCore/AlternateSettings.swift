// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation

struct USBEndpoint: Equatable {
  let address: UInt8
  let type: UInt8
  let maximumPayload: Int
  let isoInterval: UInt32?
}
func interfaceEndpoints(_ bytes: Data, number: UInt8, alternate: UInt8,
  highSpeed: Bool) -> [USBEndpoint]? {
  guard let offset = interfaceOffset(bytes, number: number, alternate: alternate) else { return nil }
  var endpoints = [USBEndpoint]()
  var addresses = Set<UInt8>()
  var i = offset + Int(bytes[offset])
  while i < bytes.count {
    guard bytes.count - i >= 2 else { return nil }
    let length = Int(bytes[i])
    guard length >= 2, length <= bytes.count - i else { return nil }
    if bytes[i + 1] == 4 { break }
    if bytes[i + 1] == 5 {
      guard length >= 7 else { return nil }
      let address = bytes[i + 2], type = bytes[i + 3] & 3
      guard address & 0x0f != 0, address & 0x70 == 0, type != 0,
        addresses.insert(address).inserted else { return nil }
      let rawSize = bytes.u16LE(i + 4)
      var maximumPayload = Int(rawSize & 0x7ff)
      var interval: UInt32?
      if type == 1 {
        guard (1...16).contains(bytes[i + 6]), maximumPayload > 0,
          maximumPayload <= (highSpeed ? 1024 : 1023),
          highSpeed ? (rawSize & 0xe000 == 0 && (rawSize >> 11) & 3 != 3) : rawSize & 0xf800 == 0
        else { return nil }
        interval = UInt32(1) << (bytes[i + 6] - 1)
        if highSpeed { maximumPayload *= 1 + Int((rawSize >> 11) & 3) }
      }
      endpoints.append(USBEndpoint(address: address, type: type,
        maximumPayload: maximumPayload, isoInterval: interval))
    }
    i += length
  }
  return endpoints.count == bytes[offset + 4] ? endpoints : nil
}

// The same transition code opens real IOUSBHost pipes and fake pipes. Publish a
// complete replacement only after opening succeeds. Session recovers a failed
// selection by reselecting the old alternate and reopening its pipes.
final class InterfacePipeMap<Pipe> {
  private(set) var pipes = [UInt8: Pipe]()
  private(set) var descriptors = [UInt8: USBEndpoint]()
  private(set) var alternates = [UInt8: UInt8]()
  private var addresses = [UInt8: Set<UInt8>]()
  func endpoints(_ number: UInt8) -> Set<UInt8>? { addresses[number] }
  func supportsAlternate(number: UInt8, alternate: UInt8, configuration: Data, highSpeed: Bool) -> Bool {
    guard let selected = interfaceEndpoints(configuration, number: number,
      alternate: alternate, highSpeed: highSpeed) else { return false }
    let old = addresses[number] ?? []
    return selected.allSatisfy { pipes[$0.address] == nil || old.contains($0.address) }
  }
  func replace(number: UInt8, alternate: UInt8, configuration: Data, highSpeed: Bool,
    select: () throws -> Void, open: (USBEndpoint) throws -> Pipe) throws {
    guard let selected = interfaceEndpoints(configuration, number: number,
      alternate: alternate, highSpeed: highSpeed) else { throw USBError.message("Invalid interface endpoints") }
    let old = addresses[number] ?? []
    guard selected.allSatisfy({ pipes[$0.address] == nil || old.contains($0.address) }) else {
      throw USBError.message("Endpoint address belongs to another interface")
    }
    try select()
    for address in old { pipes.removeValue(forKey: address); descriptors.removeValue(forKey: address) }
    addresses.removeValue(forKey: number)
    alternates.removeValue(forKey: number)
    var replacement = [UInt8: Pipe]()
    for endpoint in selected { replacement[endpoint.address] = try open(endpoint) }
    for endpoint in selected {
      pipes[endpoint.address] = replacement[endpoint.address]
      descriptors[endpoint.address] = endpoint
    }
    addresses[number] = Set(selected.map(\.address))
    alternates[number] = alternate
  }
  func removeAll() {
    pipes.removeAll(); descriptors.removeAll(); alternates.removeAll(); addresses.removeAll()
  }
}
