// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import SwiftUI

// Light colouring for the commands Longcable shows (PowerShell, and the Linux
// shell lines, which use the same few shapes). Not a parser: just enough to make
// strings, -parameters and $variables easy to tell apart.
enum PowerShellHighlight {
  enum Kind: String { case string, variable, parameter, command, `operator`, type }
  struct Token { let range: Range<String.Index>; let kind: Kind }

  static let commands: Set<String> = [
    "irm", "iwr", "Invoke-RestMethod", "Invoke-WebRequest", "Set-ExecutionPolicy", "sudo", "modprobe", "usbip",
  ]

  static func tokens(_ s: String) -> [Token] {
    var result = [Token]()
    var i = s.startIndex
    func isWordStart(_ c: Character) -> Bool { c.isLetter }
    func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "-" || c == "_" }
    while i < s.endIndex {
      let c = s[i]
      let previous: Character? = i > s.startIndex ? s[s.index(before: i)] : nil
      let atBoundary = previous == nil || previous!.isWhitespace || "(;".contains(previous!)
      if c == "'" {
        var j = s.index(after: i)
        while j < s.endIndex {
          if s[j] == "'" {
            let next = s.index(after: j)
            if next < s.endIndex && s[next] == "'" { j = s.index(after: next); continue }
            j = next
            break
          }
          j = s.index(after: j)
        }
        result.append(Token(range: i..<j, kind: .string)); i = j; continue
      }
      if c == "$", let next = s.index(i, offsetBy: 1, limitedBy: s.endIndex), next < s.endIndex,
        s[next].isLetter {
        var j = next
        while j < s.endIndex, s[j].isLetter || s[j].isNumber || s[j] == "_" || s[j] == ":" { j = s.index(after: j) }
        result.append(Token(range: i..<j, kind: .variable)); i = j; continue
      }
      if c == "-" && atBoundary {
        var j = s.index(after: i)
        if j < s.endIndex && s[j] == "-" { j = s.index(after: j) }
        if j < s.endIndex && isWordStart(s[j]) {
          while j < s.endIndex, isWord(s[j]) { j = s.index(after: j) }
          result.append(Token(range: i..<j, kind: .parameter)); i = j; continue
        }
      }
      if c == "&" && atBoundary {
        result.append(Token(range: i..<s.index(after: i), kind: .operator)); i = s.index(after: i); continue
      }
      if c == "[", let close = s[i...].firstIndex(of: "]"),
        s[s.index(after: i)..<close].allSatisfy({ $0.isLetter || $0 == "." }), s.index(after: i) < close {
        let j = s.index(after: close)
        result.append(Token(range: i..<j, kind: .type)); i = j; continue
      }
      if isWordStart(c) && atBoundary {
        var j = i
        while j < s.endIndex, isWord(s[j]) { j = s.index(after: j) }
        if commands.contains(String(s[i..<j])) { result.append(Token(range: i..<j, kind: .command)) }
        i = j; continue
      }
      i = s.index(after: i)
    }
    return result
  }

  // Readable on the light command box and in dark mode (GitHub's code colours,
  // which keep at least WCAG AA contrast on their backgrounds).
  private static func color(light: UInt32, dark: UInt32) -> Color {
    func ns(_ hex: UInt32) -> NSColor {
      NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
              blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
    return Color(nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
    })
  }
  static let stringColor = color(light: 0x116329, dark: 0x7EE787)
  static let variableColor = color(light: 0x6639BA, dark: 0xD2A8FF)
  static let parameterColor = color(light: 0x0550AE, dark: 0x79C0FF)
  static let commandColor = color(light: 0x953800, dark: 0xFFA657)
  static let operatorColor = color(light: 0xCF222E, dark: 0xFF7B72)

  static func attributed(_ s: String) -> AttributedString {
    var out = AttributedString(s)
    for token in tokens(s) {
      guard let lower = AttributedString.Index(token.range.lowerBound, within: out),
        let upper = AttributedString.Index(token.range.upperBound, within: out) else { continue }
      switch token.kind {
      case .string: out[lower..<upper].foregroundColor = stringColor
      case .variable: out[lower..<upper].foregroundColor = variableColor
      case .parameter: out[lower..<upper].foregroundColor = parameterColor
      case .command: out[lower..<upper].foregroundColor = commandColor
      case .operator, .type: out[lower..<upper].foregroundColor = operatorColor
      }
    }
    return out
  }
}
