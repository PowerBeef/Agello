import Foundation

/// Pure-Swift SentencePiece BPE tokenizer for Gemma / EmbeddingGemma `tokenizer.model` files.
/// Parses the binary `ModelProto` directly (identity normalizer, `escape_whitespaces`,
/// longest-prefix user-defined symbols, greedy max-score BPE merges, and `<0xXX>` byte fallback)
/// with zero native dependencies.
struct SentencePieceTokenizer: Sendable {
  struct Piece: Sendable {
    let text: String
    let score: Float
    let type: PieceType
  }

  enum PieceType: Int, Sendable {
    case normal = 1
    case unknown = 2
    case control = 3
    case userDefined = 4
    case unused = 5
    case byte = 6
  }

  enum LoadError: Error, LocalizedError {
    case malformedProtobuf
    case emptyVocabulary

    var errorDescription: String? {
      switch self {
      case .malformedProtobuf: return "Malformed SentencePiece model file."
      case .emptyVocabulary: return "SentencePiece model contains no pieces."
      }
    }
  }

  private final class TrieNode: @unchecked Sendable {
    var children: [UInt8: TrieNode] = [:]
    var tokenID: Int32?
  }

  private struct NormalEntry: Sendable {
    let id: Int32
    let score: Float
  }

  let bosID: Int32
  let eosID: Int32
  let unkID: Int32
  let padID: Int32
  let vocabSize: Int
  private let byteFallback: Bool
  private let escapeWhitespaces: Bool
  /// Keyed by exact UTF-8 bytes (not `String`): Swift `String` compares by Unicode canonical
  /// equivalence, which collides CJK Unified (`U+5E74`) and Compatibility (`U+F98E`) ideographs
  /// whereas SentencePiece keys on raw UTF-8 `std::string` bytes.
  private let normalPieces: [Data: NormalEntry]
  private let byteTokenIDs: [Int32]
  private let userDefinedRoot: TrieNode
  private let hasUserDefined: Bool

  init(contentsOf url: URL) throws {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    try self.init(modelProtoData: data)
  }

  init(modelProtoData data: Data) throws {
    var pieces: [Piece] = []
    pieces.reserveCapacity(262_144)
    var spec = ModelSpec()

    try data.withUnsafeBytes { raw in
      var reader = ProtoReader(bytes: raw)
      while !reader.isAtEnd {
        let (field, wire) = try reader.readTag()
        switch (field, wire) {
        case (1, 2):
          let slice = try reader.readBytes()
          pieces.append(try Self.parsePiece(slice))
        case (2, 2):
          let slice = try reader.readBytes()
          try Self.parseTrainerSpec(slice, into: &spec)
        case (3, 2):
          let slice = try reader.readBytes()
          try Self.parseNormalizerSpec(slice, into: &spec)
        default:
          try reader.skip(wireType: wire)
        }
      }
    }

    guard !pieces.isEmpty else { throw LoadError.emptyVocabulary }
    self.init(
      pieces: pieces, bosID: spec.bosID, eosID: spec.eosID, unkID: spec.unkID, padID: spec.padID,
      byteFallback: spec.byteFallback, escapeWhitespaces: spec.escapeWhitespaces)
  }

  init(
    pieces: [Piece],
    bosID: Int32 = 2,
    eosID: Int32 = 1,
    unkID: Int32 = 3,
    padID: Int32 = 0,
    byteFallback: Bool = true,
    escapeWhitespaces: Bool = true
  ) {
    self.bosID = bosID
    self.eosID = eosID
    self.unkID = unkID
    self.padID = padID
    self.vocabSize = pieces.count
    self.byteFallback = byteFallback
    self.escapeWhitespaces = escapeWhitespaces

    var normal: [Data: NormalEntry] = [:]
    normal.reserveCapacity(pieces.count)
    var byteIDs = [Int32](repeating: unkID, count: 256)
    let root = TrieNode()
    var anyUserDefined = false

    for (index, piece) in pieces.enumerated() {
      let id = Int32(index)
      switch piece.type {
      case .normal:
        let key = Data(piece.text.utf8)
        if normal[key] == nil {
          normal[key] = NormalEntry(id: id, score: piece.score)
        }
      case .userDefined:
        guard !piece.text.isEmpty else { continue }
        var node = root
        for byte in piece.text.utf8 {
          if let next = node.children[byte] {
            node = next
          } else {
            let created = TrieNode()
            node.children[byte] = created
            node = created
          }
        }
        node.tokenID = id
        anyUserDefined = true
      case .byte:
        if let value = Self.parseHexBytePiece(piece.text) {
          byteIDs[Int(value)] = id
        }
      case .unknown, .control, .unused:
        break
      }
    }

    self.normalPieces = normal
    self.byteTokenIDs = byteIDs
    self.userDefinedRoot = root
    self.hasUserDefined = anyUserDefined
  }

  /// Encodes `text` into SentencePiece token IDs (without BOS/EOS).
  func encode(_ text: String) -> [Int32] {
    guard !text.isEmpty else { return [] }
    let normalized = escapeWhitespaces ? text.replacingOccurrences(of: " ", with: "\u{2581}") : text
    let utf8 = Array(normalized.utf8)
    var output: [Int32] = []
    output.reserveCapacity(utf8.count / 3 + 8)

    if !hasUserDefined {
      encodeBPESpan(utf8[...], into: &output)
      return output
    }

    var cursor = 0
    var spanStart = 0
    while cursor < utf8.count {
      if let match = matchUserDefined(in: utf8, at: cursor) {
        if spanStart < cursor {
          encodeBPESpan(utf8[spanStart..<cursor], into: &output)
        }
        output.append(match.tokenID)
        cursor = match.end
        spanStart = cursor
      } else {
        cursor += Self.utf8ScalarLength(utf8[cursor])
      }
    }
    if spanStart < utf8.count {
      encodeBPESpan(utf8[spanStart..<utf8.count], into: &output)
    }
    return output
  }

  /// Encodes `text` wrapped with `[BOS, ..., EOS]`, truncating to `maxLength` while preserving
  /// the trailing `EOS` token (matching LiteRT-LM's `.truncate` overflow policy).
  func encodeWithSpecialTokens(_ text: String, maxLength: Int) -> [Int32] {
    guard maxLength > 0 else { return [] }
    let body = encode(text)
    if maxLength == 1 { return [bosID] }
    let bodyLimit = max(0, maxLength - 2)
    var result: [Int32] = []
    result.reserveCapacity(min(body.count + 2, maxLength))
    result.append(bosID)
    result.append(contentsOf: body.prefix(bodyLimit))
    result.append(eosID)
    return result
  }

  // MARK: - BPE merge engine

  private struct Symbol {
    var prev: Int
    var next: Int
    var start: Int
    var end: Int
    var active: Bool
  }

  private struct MergeCandidate {
    let score: Float
    let left: Int
    let right: Int
    let rightEnd: Int

    /// Higher score wins; ties break toward smaller `left` index (SentencePiece BPE contract).
    static func beats(_ lhs: MergeCandidate, _ rhs: MergeCandidate) -> Bool {
      if lhs.score != rhs.score { return lhs.score > rhs.score }
      return lhs.left < rhs.left
    }
  }

  private struct MergeHeap {
    private var storage: [MergeCandidate] = []

    var isEmpty: Bool { storage.isEmpty }

    mutating func reserveCapacity(_ n: Int) { storage.reserveCapacity(n) }

    mutating func push(_ item: MergeCandidate) {
      storage.append(item)
      var i = storage.count - 1
      while i > 0 {
        let parent = (i - 1) >> 1
        if MergeCandidate.beats(storage[i], storage[parent]) {
          storage.swapAt(i, parent)
          i = parent
        } else {
          break
        }
      }
    }

    mutating func pop() -> MergeCandidate? {
      guard !storage.isEmpty else { return nil }
      if storage.count == 1 { return storage.removeLast() }
      let top = storage[0]
      storage[0] = storage.removeLast()
      var i = 0
      let count = storage.count
      while true {
        let left = (i << 1) + 1
        let right = left + 1
        var best = i
        if left < count, MergeCandidate.beats(storage[left], storage[best]) { best = left }
        if right < count, MergeCandidate.beats(storage[right], storage[best]) { best = right }
        if best == i { break }
        storage.swapAt(i, best)
        i = best
      }
      return top
    }
  }

  private func encodeBPESpan(_ bytes: ArraySlice<UInt8>, into output: inout [Int32]) {
    let base = bytes.startIndex
    let end = bytes.endIndex
    guard base < end else { return }

    var symbols: [Symbol] = []
    symbols.reserveCapacity(end - base)
    var pos = base
    while pos < end {
      let nextPos = min(end, pos + Self.utf8ScalarLength(bytes[pos]))
      let idx = symbols.count
      symbols.append(Symbol(prev: idx - 1, next: idx + 1, start: pos, end: nextPos, active: true))
      pos = nextPos
    }
    if !symbols.isEmpty { symbols[symbols.count - 1].next = -1 }

    func lookupBytes(start: Int, end: Int) -> NormalEntry? {
      normalPieces[Data(bytes[start..<end])]
    }

    var heap = MergeHeap()
    heap.reserveCapacity(symbols.count * 2)

    func maybePush(left: Int, right: Int) {
      guard left >= 0, right >= 0, symbols[left].active, symbols[right].active else { return }
      guard let entry = lookupBytes(start: symbols[left].start, end: symbols[right].end) else {
        return
      }
      heap.push(
        MergeCandidate(score: entry.score, left: left, right: right, rightEnd: symbols[right].end))
    }

    if symbols.count > 1 {
      for i in 0..<(symbols.count - 1) {
        maybePush(left: i, right: i + 1)
      }
    }

    while let best = heap.pop() {
      let l = best.left
      let r = best.right
      guard symbols[l].active, symbols[r].active,
        symbols[l].next == r, symbols[r].end == best.rightEnd
      else { continue }

      symbols[l].end = symbols[r].end
      symbols[r].active = false
      let after = symbols[r].next
      symbols[l].next = after
      if after >= 0 { symbols[after].prev = l }

      if symbols[l].prev >= 0 { maybePush(left: symbols[l].prev, right: l) }
      if after >= 0 { maybePush(left: l, right: after) }
    }

    var idx = 0
    while idx >= 0, idx < symbols.count {
      let sym = symbols[idx]
      if sym.active {
        if let entry = lookupBytes(start: sym.start, end: sym.end) {
          output.append(entry.id)
        } else if byteFallback {
          for b in bytes[sym.start..<sym.end] {
            output.append(byteTokenIDs[Int(b)])
          }
        } else {
          output.append(unkID)
        }
      }
      idx = sym.next
    }
  }

  private func matchUserDefined(in bytes: [UInt8], at start: Int) -> (tokenID: Int32, end: Int)? {
    var node = userDefinedRoot
    var best: (Int32, Int)?
    var i = start
    while i < bytes.count, let next = node.children[bytes[i]] {
      node = next
      i += 1
      if let id = node.tokenID { best = (id, i) }
    }
    return best
  }

  private static func utf8ScalarLength(_ lead: UInt8) -> Int {
    if lead < 0x80 { return 1 }
    if lead < 0xE0 { return 2 }
    if lead < 0xF0 { return 3 }
    return 4
  }

  private static func parseHexBytePiece(_ text: String) -> UInt8? {
    guard text.count == 6, text.hasPrefix("<0x"), text.hasSuffix(">") else { return nil }
    let start = text.index(text.startIndex, offsetBy: 3)
    let end = text.index(text.endIndex, offsetBy: -1)
    return UInt8(text[start..<end], radix: 16)
  }
}

// MARK: - Minimal Protobuf wire reader

extension SentencePieceTokenizer {
  private struct ModelSpec {
    var bosID: Int32 = 2
    var eosID: Int32 = 1
    var unkID: Int32 = 3
    var padID: Int32 = 0
    var byteFallback = true
    var escapeWhitespaces = true
  }

  private struct ProtoReader {
    let bytes: UnsafeRawBufferPointer
    var offset = 0

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func readVarint() throws -> UInt64 {
      var result: UInt64 = 0
      var shift: UInt64 = 0
      while offset < bytes.count {
        let b = bytes[offset]
        offset += 1
        result |= UInt64(b & 0x7F) << shift
        if (b & 0x80) == 0 { return result }
        shift += 7
        if shift >= 64 { throw LoadError.malformedProtobuf }
      }
      throw LoadError.malformedProtobuf
    }

    mutating func readTag() throws -> (field: Int, wire: Int) {
      let raw = try readVarint()
      return (Int(raw >> 3), Int(raw & 0x7))
    }

    mutating func readBytes() throws -> UnsafeRawBufferPointer {
      let len = Int(try readVarint())
      guard len >= 0, offset + len <= bytes.count else { throw LoadError.malformedProtobuf }
      let slice = UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + len)])
      offset += len
      return slice
    }

    mutating func readFloat32() throws -> Float {
      guard offset + 4 <= bytes.count else { throw LoadError.malformedProtobuf }
      var bits: UInt32 = 0
      withUnsafeMutableBytes(of: &bits) { dst in
        dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[offset..<(offset + 4)]))
      }
      offset += 4
      return Float(bitPattern: UInt32(littleEndian: bits))
    }

    mutating func skip(wireType: Int) throws {
      switch wireType {
      case 0: _ = try readVarint()
      case 1:
        guard offset + 8 <= bytes.count else { throw LoadError.malformedProtobuf }
        offset += 8
      case 2: _ = try readBytes()
      case 5:
        guard offset + 4 <= bytes.count else { throw LoadError.malformedProtobuf }
        offset += 4
      default:
        throw LoadError.malformedProtobuf
      }
    }
  }

  private static func parsePiece(_ slice: UnsafeRawBufferPointer) throws -> Piece {
    var reader = ProtoReader(bytes: slice)
    var text = ""
    var score: Float = 0
    var type: PieceType = .normal
    while !reader.isAtEnd {
      let (field, wire) = try reader.readTag()
      switch (field, wire) {
      case (1, 2):
        let b = try reader.readBytes()
        text = String(decoding: b, as: UTF8.self)
      case (2, 5):
        score = try reader.readFloat32()
      case (3, 0):
        let raw = Int(try reader.readVarint())
        type = PieceType(rawValue: raw) ?? .normal
      default:
        try reader.skip(wireType: wire)
      }
    }
    return Piece(text: text, score: score, type: type)
  }

  private static func parseTrainerSpec(
    _ slice: UnsafeRawBufferPointer,
    into spec: inout ModelSpec
  ) throws {
    var reader = ProtoReader(bytes: slice)
    while !reader.isAtEnd {
      let (field, wire) = try reader.readTag()
      switch (field, wire) {
      case (35, 0): spec.byteFallback = try reader.readVarint() != 0
      case (40, 0): spec.unkID = Int32(truncatingIfNeeded: try reader.readVarint())
      case (41, 0): spec.bosID = Int32(truncatingIfNeeded: try reader.readVarint())
      case (42, 0): spec.eosID = Int32(truncatingIfNeeded: try reader.readVarint())
      case (43, 0): spec.padID = Int32(truncatingIfNeeded: try reader.readVarint())
      default: try reader.skip(wireType: wire)
      }
    }
  }

  private static func parseNormalizerSpec(
    _ slice: UnsafeRawBufferPointer,
    into spec: inout ModelSpec
  ) throws {
    var reader = ProtoReader(bytes: slice)
    while !reader.isAtEnd {
      let (field, wire) = try reader.readTag()
      switch (field, wire) {
      case (5, 0): spec.escapeWhitespaces = try reader.readVarint() != 0
      default: try reader.skip(wireType: wire)
      }
    }
  }
}
