// Copyright 2026 Denis Arnst (Sapd) — https://github.com/Sapd
// Licensed under GPL-3.0-or-later; see LICENSE.
import Foundation

// The app's own texts are English keys, translated from Localization/<language>.lproj
// (packaged into the app by scripts/package-release.sh). The service always sends
// English: its states and messages are translated here only for display, from
// Service.strings, while the app keeps comparing the English originals.
// Keys with %@ match messages that carry a value, such as an app's name.
func serviceText(_ text: String, bundle: Bundle = .main) -> String {
  let exact = bundle.localizedString(forKey: text, value: nil, table: "Service")
  if exact != text { return exact }
  for (key, regex) in serviceTemplates(bundle) {
    let range = NSRange(text.startIndex..., in: text)
    guard let match = regex.firstMatch(in: text, range: range) else { continue }
    let values = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    let format = bundle.localizedString(forKey: key, value: nil, table: "Service")
    guard format != key else { return text }
    return String(format: format, arguments: values)
  }
  return text
}

private var templateCache: [String: [(String, NSRegularExpression)]] = [:]
private let templateLock = NSLock()
private func serviceTemplates(_ bundle: Bundle) -> [(String, NSRegularExpression)] {
  templateLock.withLock {
    if let cached = templateCache[bundle.bundlePath] { return cached }
    var found: [(String, NSRegularExpression)] = []
    if let url = bundle.url(forResource: "Service", withExtension: "strings"),
       let table = NSDictionary(contentsOf: url) as? [String: String] {
      for key in table.keys.sorted() where key.contains("%") {
        // %@ and %1$@ … become capture groups; everything else matches literally.
        let parts = key.components(separatedBy: try! NSRegularExpression(pattern: "%(\\d+\\$)?@"))
        let pattern = "^" + parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.+?)") + "$"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) {
          found.append((key, regex))
        }
      }
    }
    templateCache[bundle.bundlePath] = found
    return found
  }
}

private extension String {
  func components(separatedBy regex: NSRegularExpression) -> [String] {
    var parts: [String] = [], start = startIndex
    for match in regex.matches(in: self, range: NSRange(startIndex..., in: self)) {
      guard let range = Range(match.range, in: self) else { continue }
      parts.append(String(self[start..<range.lowerBound]))
      start = range.upperBound
    }
    parts.append(String(self[start...]))
    return parts
  }
}
