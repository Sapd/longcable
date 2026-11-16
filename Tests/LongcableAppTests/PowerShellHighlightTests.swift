// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import XCTest
@testable import Longcable

final class PowerShellHighlightTests: XCTestCase {
  private func kinds(_ s: String) -> [String] {
    PowerShellHighlight.tokens(s).map { "\($0.kind):\(s[$0.range])" }
  }

  func testCommandStringsParametersAndVariables() {
    XCTAssertEqual(kinds("& ([scriptblock]::Create((irm 'https://x/y.ps1'))) -Server 'mac' -BusIds '1-1','2-1'"), [
      "operator:&", "type:[scriptblock]", "command:irm", "string:'https://x/y.ps1'",
      "parameter:-Server", "string:'mac'", "parameter:-BusIds", "string:'1-1'", "string:'2-1'",
    ])
    XCTAssertEqual(kinds("$usbip = 'C:\\Program Files\\USBip\\usbip.exe'"), [
      "variable:$usbip", "string:'C:\\Program Files\\USBip\\usbip.exe'",
    ])
    XCTAssertEqual(kinds("& $usbip attach -r '10.0.0.2' --receive-mode=low-latency"), [
      "operator:&", "variable:$usbip", "parameter:-r", "string:'10.0.0.2'", "parameter:--receive-mode",
    ])
  }

  func testDoubledQuoteStaysInsideString() {
    XCTAssertEqual(kinds("-Server 'a''b'"), ["parameter:-Server", "string:'a''b'"])
  }

  func testBusIDsAndHyphenatedWordsAreNotParameters() {
    XCTAssertEqual(kinds("x-y @()"), [])
  }
}
