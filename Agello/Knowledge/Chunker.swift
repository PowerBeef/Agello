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
///
/// Sizes are weights in quarter tokens (``weight(of:)``), not characters: EmbeddingGemma reads
/// at most 1,024 tokens per passage by default, and a passage of digits or Chinese reaches that
/// in far fewer characters than English prose (about one token per digit or ideograph).
enum Chunker {
  /// ~400 tokens: 1,600 characters of English at ~4 characters per token.
  static let targetCharacters = 1_600
  /// Weight repeated at the start of the next passage.
  static let overlapCharacters = 200

  /// Estimated size in quarter tokens: Latin letters, spaces and punctuation 1; digits,
  /// ideographs, kana and hangul 4 (about a token each); other scripts 2; emoji and other
  /// symbols outside the basic planes 8. English text weighs about its character count.
  static func weight<S: StringProtocol>(of text: S) -> Int {
    var total = 0
    for scalar in text.unicodeScalars { total += weight(of: scalar) }
    return total
  }

  static func weight(of scalar: Unicode.Scalar) -> Int {
    let value = scalar.value
    if value < 0x80 { return (0x30...0x39).contains(value) ? 4 : 1 }
    if value < 0x250 { return 1 }  // Latin-1 and Latin Extended
    if isDense(scalar) { return 4 }
    if value > 0xFFFF { return 8 }
    return 2
  }

  /// Ideographs, kana and hangul: about one token per character.
  static func isDense(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF,
      0x1100...0x11FF, 0x3130...0x318F, 0x20000...0x2FA1F:
      return true
    default:
      return false
    }
  }

  private struct Unit {
    var text: String
    var page: Int?
    var weight: Int

    init(text: String, page: Int?) {
      self.text = text
      self.page = page
      weight = Chunker.weight(of: text)
    }
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
        guard carriedLength + unit.weight <= overlapCharacters else { break }
        carried.insert(unit, at: 0)
        carriedLength += unit.weight
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
      let full = length + unit.weight > targetCharacters
      // Break at page boundaries once a passage is substantial, so
      // citations point at one page where possible.
      let newPage = unit.page != nil && current.last?.page != unit.page
        && length - carriedLength(current, carriedCount) >= targetCharacters / 2
      if length > 0, full || newPage {
        flush()
      }
      current.append(unit)
      length += unit.weight
    }
    // A trailing overlap alone isn't a new passage.
    if current.count > carriedCount { flush() }
    return chunks
  }

  private static func carriedLength(_ units: [Unit], _ count: Int) -> Int {
    units.prefix(count).reduce(0) { $0 + $1.weight }
  }

  /// Paragraphs, with paragraphs longer than a passage split into sentences
  /// (and sentences longer than a passage cut by length).
  static func split(_ text: String) -> [String] {
    let paragraphs = text
      .components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return paragraphs.flatMap { paragraph -> [String] in
      guard weight(of: paragraph) > targetCharacters else { return [paragraph] }
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
    guard weight(of: text) > targetCharacters else { return [text] }
    var pieces: [String] = []
    var start = text.startIndex
    while start < text.endIndex {
      // Walk to the piece's weight limit, remembering the last space past its first half.
      var index = start
      var used = 0
      var space: String.Index?
      while index < text.endIndex {
        let character = text[index]
        let next = used + character.unicodeScalars.reduce(0) { $0 + weight(of: $1) }
        if next > targetCharacters, index > start { break }
        if character == " ", used > targetCharacters / 2 { space = index }
        used = next
        index = text.index(after: index)
      }
      let end = index < text.endIndex ? (space ?? index) : index
      let piece = text[start..<end].trimmingCharacters(in: .whitespaces)
      if !piece.isEmpty { pieces.append(piece) }
      start = end
    }
    return pieces
  }
}
