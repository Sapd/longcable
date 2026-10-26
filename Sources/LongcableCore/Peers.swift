// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Darwin
import Foundation

struct IPv4Peer {
  let network: UInt32
  let mask: UInt32
  init(_ text: String) throws {
    let parts = text.split(separator: "/", omittingEmptySubsequences: false)
    var address = in_addr()
    guard (1...2).contains(parts.count), inet_pton(AF_INET, String(parts[0]), &address) == 1 else {
      throw USBError.message("Invalid IPv4 peer: \(text)")
    }
    let prefix: Int
    if parts.count == 2 {
      guard !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }),
        let bits = Int(parts[1]), (0...32).contains(bits) else {
        throw USBError.message("Invalid CIDR prefix: \(text)")
      }
      prefix = bits
    } else {
      guard address.s_addr != 0, address.s_addr != UInt32.max else {
        throw USBError.message("Invalid peer address: \(text)")
      }
      prefix = 32
    }
    mask = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
    network = UInt32(bigEndian: address.s_addr) & mask
  }
  func contains(_ address: in_addr) -> Bool { UInt32(bigEndian: address.s_addr) & mask == network }
}
public struct RefusedPeer: Codable, Identifiable, Sendable {
  public var address: String
  public var timestamp: Date
  public var id: String { address }
}
func mergedPeers(startup: String, extra: [String]) -> [String] {
  var seen = Set<String>()
  return (startup.split(separator: ",").map(String.init) + extra).filter { seen.insert($0).inserted }
}
func savedPeers(at store: StorePaths) throws -> [String] {
  // Reject links and unsafe permissions before reading persistent network policy.
  var info = stat()
  if lstat(store.peers, &info) != 0 {
    if errno == ENOENT { return [] }
    throw USBError.message("Could not inspect saved peers")
  }
  guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o600 else {
    throw USBError.message("Unsafe saved peers (requires owner-only permissions and daemon ownership)")
  }
  let peers = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: store.peers)))
  guard peers.count <= 256, Set(peers).count == peers.count else { throw USBError.message("Invalid saved peers") }
  for peer in peers { _ = try IPv4Peer(peer) }
  return peers
}
func savePeers(_ peers: [String], at store: StorePaths) throws {
  // A private temporary file keeps the policy 0600 throughout atomic replacement.
  let path = store.peers + "." + UUID().uuidString
  let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
  guard fd >= 0 else { throw USBError.message("Could not create saved peers") }
  guard fchmod(fd, 0o600) == 0 else {
    Darwin.close(fd); unlink(path)
    throw USBError.message("Could not secure saved peers")
  }
  let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  defer { try? handle.close(); unlink(path) }
  try handle.write(contentsOf: JSONEncoder().encode(peers))
  try handle.synchronize()
  guard rename(path, store.peers) == 0 else { throw USBError.message("Could not replace saved peers") }
}
