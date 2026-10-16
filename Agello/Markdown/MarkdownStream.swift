import Foundation

/// A streaming reply is parsed in two parts: the text up to its last finished block, which
/// doesn't change from one update to the next (parsed once, then cached), and the rest. A long
/// reply re-parsed whole at every update cost 4–8 ms each on a Mac by its end. Pure (unit-tested).
enum MarkdownStream {
  /// Where `text` can be cut so that parsing the two parts gives the blocks of parsing it whole:
  /// after the last blank line outside code fences and display math whose next line can't
  /// continue the block before it (a list item, quote, table row, indented line or setext
  /// underline could). The prefix is empty when there's no such place.
  static func stableSplit(_ text: String) -> (prefix: Substring, tail: Substring) {
    var inFence = false
    var fenceMarker = ""
    var inMath = false
    var cut = text.startIndex
    var pendingCut: String.Index?
    var previousBlank = true
    var index = text.startIndex
    while index < text.endIndex {
      let lineEnd = text[index...].firstIndex(of: "\n") ?? text.endIndex
      let line = text[index..<lineEnd]
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      let blank = trimmed.isEmpty
      if let candidate = pendingCut, !blank {
        // The first non-blank line after a blank one decides whether the cut is safe.
        if !inFence, !inMath, !continuesBlock(line) { cut = candidate }
        pendingCut = nil
      }
      if inFence {
        if trimmed.hasPrefix(fenceMarker) { inFence = false }
      } else if inMath {
        if trimmed.contains("$$") || trimmed.contains("\\]") { inMath = false }
      } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        inFence = true
        fenceMarker = String(trimmed.prefix(3))
      } else if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
        // A single line holding both delimiters opens and closes it.
        let rest = trimmed.dropFirst(2)
        inMath = !(rest.contains("$$") || rest.contains("\\]"))
      } else if blank, !previousBlank, line.endIndex < text.endIndex {
        pendingCut = text.index(after: lineEnd)
      }
      previousBlank = blank
      guard lineEnd < text.endIndex else { break }
      index = text.index(after: lineEnd)
    }
    return (text[..<cut], text[cut...])
  }

  /// Whether `line` can belong to the block before a blank line.
  static func continuesBlock(_ line: Substring) -> Bool {
    if line.hasPrefix("\t") || line.hasPrefix("    ") { return true }
    let trimmed = line.drop { $0 == " " }
    guard let first = trimmed.first else { return false }
    if "-*+>|=".contains(first) { return true }
    if first.isNumber {
      let digits = trimmed.prefix { $0.isNumber }
      let after = trimmed.dropFirst(digits.count).first
      return after == "." || after == ")"
    }
    return false
  }
}
