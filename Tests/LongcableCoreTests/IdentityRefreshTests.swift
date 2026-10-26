// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
// Native macOS implementation and support: Denis Arnst (Sapd) — https://github.com/Sapd
import Foundation
import XCTest
@testable import LongcableCore

final class IdentityRefreshTests: XCTestCase {
  func testPhysicalReplugRefreshesDescriptorsWithoutChangingSlot() {
    let config = TargetConfig(vendor: 0x231d, product: 0x201, location: 1, label: "LEFT")
    var registryID: UInt64? = 10
    var loads = 0
    let target = Target(config, slot: 3, registryIdentity: { _ in registryID },
      identityLoader: { _, bus, wire in
        loads += 1
        var record = Data(count: 312)
        record.put32(296, UInt32(loads))
        return Identity(record: record, classes: Data(), configuration: UInt8(loads),
          overlaySerial: true, name: "Revision \(loads)", serial: "LEFT")
      })
    XCTAssertTrue(target.ensureIdentity())
    XCTAssertTrue(target.ensureIdentity())
    XCTAssertEqual(loads, 1)
    registryID = 11
    XCTAssertTrue(target.ensureIdentity())
    XCTAssertEqual(loads, 2)
    XCTAssertEqual(target.identity?.name, "Revision 2")
    registryID = nil
    XCTAssertFalse(target.ensureIdentity())
    XCTAssertNil(target.identity)
    registryID = 12
    XCTAssertTrue(target.ensureIdentity())
    XCTAssertEqual(loads, 3)
    XCTAssertEqual(target.identity?.name, "Revision 3")
    XCTAssertEqual(target.identity?.record.u32(296), 3)
    XCTAssertEqual(target.busID, "1-4")
    XCTAssertEqual(target.wireID, 0x10004)
  }
  func testRemovalDuringDescriptorReadCannotPublishStaleIdentity() {
    let config = TargetConfig(vendor: 0x231d, product: 0x201, location: 1, label: "LEFT")
    var registryID: UInt64? = 10
    let target = Target(config, slot: 0, registryIdentity: { _ in registryID },
      identityLoader: { _, _, _ in
        registryID = 11
        return Identity(record: Data(), classes: Data(), configuration: 1,
          overlaySerial: false, name: "Old", serial: "")
      })
    XCTAssertFalse(target.ensureIdentity())
    XCTAssertNil(target.identity)
  }
}
