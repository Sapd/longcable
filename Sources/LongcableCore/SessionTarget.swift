// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation
import IOKit

// What a Session needs from the device it serves. CapturedDevice is the physical
// implementation; a virtual device answers from memory instead.
protocol SessionDevice: USBTransferTransport {
  var location: UInt32 { get }
  func release()
}

// What a Session needs from the exported slot: wire identity, status reporting and
// how to open the device behind it.
protocol SessionTarget: AnyObject {
  var busID: String { get }
  var wireID: UInt32 { get }
  var identity: Identity? { get set }
  // Serial reported when the identity overlays a missing serial descriptor.
  var overlayLabel: String { get }
  // disconnected is installed before the device opens, so no unplug is missed.
  func openDevice(_ identity: Identity, disconnected: @escaping () -> Void) throws -> SessionDevice
  func attached(_ location: UInt32)
  func ended()
  func failed(_ error: Error)
  func transfer(_ count: Int, status: Int32, pending: Int, native: IOReturn)
  func queued(_ count: Int)
}
