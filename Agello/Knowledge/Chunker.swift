import Foundation

/// A passage of a document, ready to embed and cite.
struct ChunkDraft: Equatable, Sendable {
  var index: Int
  var text: String
  /// 1-based page range (nil for unpaged text).
  var pageStart: Int?
  var pageEnd: Int?
}

/// Splits document text into ~400-token passages at paragraph and sentence
/// boundaries, with a small overlap so an answer spanning two passages is
/// still found. Tracks the pages each passage covers. Pure (unit-tested).
enum Chunker {
  /// ~400 tokens of English at ~4 characters per token.
  static let targetCharacters = 1_600
  /// Characters repeated at the start of the next passage.
  static let overlapCharacters = 200

  private struct Unit {
    var text: String
    var page: Int?
  }

  static func chunks(pages: [String], paged: Bool) -> [ChunkDraft] {
    var units: [Unit] = []
    for (offset, page) in pages.enumerated() {
      for piece in split(page) {
        units.append(Unit(text: piece, page: paged ? offset + 1 : nil))
      }
    }

    var chunks: [ChunkDraft] = []
    var current: [Unit] = []
    var length = 0
    /// Leading units of `current` repeated from the previous passage.
    var carriedCount = 0

    func flush() {
      guard !current.isEmpty else { return }
      let text = current.map(\.text).joined(separator: "\n\n")
      let pages = current.compactMap(\.page)
      chunks.append(
        ChunkDraft(index: chunks.count, text: text, pageStart: pages.min(), pageEnd: pages.max()))
      // Carry the tail of this passage into the next one.
      var carried: [Unit] = []
      var carriedLength = 0
      for unit in current.reversed() {
        guard carriedLength + unit.text.count <= overlapCharacters else { break }
        carried.insert(unit, at: 0)
        carriedLength += unit.text.count
      }
      // Never carry the whole passage (it would repeat forever).
      if carried.count == current.count {
        carried.removeAll()
        carriedLength = 0
      }
      current = carried
      length = carriedLength
      carriedCount = carried.count
    }

    for unit in units {
      let full = length + unit.text.count > targetCharacters
      // Break at page boundaries once a passage is substantial, so
      // citations point at one page where possible.
      let newPage = unit.page != nil && current.last?.page != unit.page
        && length - carriedLength(current, carriedCount) >= targetCharacters / 2
      if length > 0, full || newPage {
        flush()
      }
      current.append(unit)
      length += unit.text.count
    }
    // A trailing overlap alone isn't a new passage.
    if current.count > carriedCount { flush() }
    return chunks
  }

  private static func carriedLength(_ units: [Unit], _ count: Int) -> Int {
    units.prefix(count).reduce(0) { $0 + $1.text.count }
  }

  /// Paragraphs, with paragraphs longer than a passage split into sentences
  /// (and sentences longer than a passage cut by length).
  static func split(_ text: String) -> [String] {
    let paragraphs = text
      .components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return paragraphs.flatMap { paragraph -> [String] in
      guard paragraph.count > targetCharacters else { return [paragraph] }
      return sentences(paragraph).flatMap { hardWrap($0) }
    }
  }

  private static func sentences(_ text: String) -> [String] {
    var result: [String] = []
    text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
      if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
        result.append(sentence)
      }
    }
    return result.isEmpty ? [text] : result
  }

  /// Cuts text with no usable sentence breaks into passage-sized pieces, in one pass: long
  /// single-line files (minified JSON, logs) reach this, and recounting the rest of the text
  /// for every piece made it quadratic.
  private static func hardWrap(_ text: String) -> [String] {
    guard text.count > targetCharacters else { return [text] }
    var pieces: [String] = []
    var start = text.startIndex
    while let limit = text.index(start, offsetBy: targetCharacters, limitedBy: text.endIndex),
      limit < text.endIndex
    {
      var end = limit
      // Prefer breaking at a space in the piece's second half.
      let half = text.index(start, offsetBy: targetCharacters / 2 + 1)
      if let space = text[half..<limit].lastIndex(of: " ") { end = space }
      pieces.append(String(text[start..<end]).trimmingCharacters(in: .whitespaces))
      start = end
    }
    let tail = text[start...].trimmingCharacters(in: .whitespaces)
    if !tail.isEmpty { pieces.append(tail) }
    return pieces
  }
}
