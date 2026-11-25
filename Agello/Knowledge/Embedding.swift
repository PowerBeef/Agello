import Accelerate
import Foundation

/// Turns text into unit-length vectors for search by meaning.
protocol TextEmbedder: Sendable {
  /// Stored with indexed data; a different identifier means "re-index".
  var identifier: String { get }
  /// Components per vector: a stored vector of another length is indexed again.
  var dimensions: Int { get }
  /// Cosine similarity above which a chat can count as related to a search…
  var relatedThreshold: Float { get }
  /// …when it also beats the median chat by this much (0: threshold only).
  /// Short, generic chats score fairly high against any query, so a raw
  /// threshold alone shows unrelated chats.
  var relatedMargin: Float { get }
  /// Whether this embedder submits Metal GPU work (must honor ``GPUGate`` in the background).
  var usesGPU: Bool { get }
  func embed(documents: [(title: String, text: String)]) async throws -> [[Float]]
  func embed(query: String) async throws -> [Float]
  /// A query for one of EmbeddingGemma's tasks; the others embed every query alike.
  func embed(query: String, task: EmbeddingQueryTask) async throws -> [Float]
  func unload() async
}

extension TextEmbedder {
  var usesGPU: Bool { false }

  func embed(query: String, task: EmbeddingQueryTask) async throws -> [Float] {
    try await embed(query: query)
  }
}

/// EmbeddingGemma's query tasks (its model card's prompts): a search over documents, or a search
/// for code. Probe 39 (2026-11-17) found the code task no better on code questions (the same ranks
/// over 14 code passages), so search uses the search task.
enum EmbeddingQueryTask: String, Sendable {
  case search = "search result"
  case code = "code retrieval"
}

/// EmbeddingGemma 2 shared prompt formatting and vector constants (used by CoreAIEmbedder,
/// LiteRTEmbedder, and RemoteEmbedder without coupling to LiteRTLM).
enum EmbeddingGemmaPrompts {
  static let outputSize = 768
  static let identifier = "embeddinggemma-2-text-270m@\(outputSize)"

  static func documentPrompt(title: String, text: String) -> String {
    "title: \(title.isEmpty ? "none" : String(title.prefix(80))) | text: \(text)"
  }

  static func queryPrompt(_ query: String, task: EmbeddingQueryTask = .search) -> String {
    "task: \(task.rawValue) | query: \(query)"
  }
}

/// On-disk layout checks for the unpacked Core AI ANE EmbeddingGemma 2 bundle (pure Foundation,
/// shared with `ModelCatalog`, `ModelStore`, and `AgelloSim` without importing `CoreAI`).
enum EmbeddingBundleLayout {
  static let directoryName = "embeddinggemma-2-text-270m-ane"

  static func isAvailable(at directory: URL) -> Bool {
    let fm = FileManager.default
    let model = directory.appendingPathComponent("text_encoder.aimodel/main.mlirb").path
    let table = directory.appendingPathComponent("embed_tokens.bin").path
    let tokenizer = directory.appendingPathComponent("tokenizer.model").path
    return fm.fileExists(atPath: model)
      && fm.fileExists(atPath: table)
      && fm.fileExists(atPath: tokenizer)
  }
}

/// Deterministic bag-of-words vectors (hashed words and word pairs): keeps
/// retrieval working with the mock engine and in unit tests, no model needed.
struct HashingEmbedder: TextEmbedder {
  /// v2: keyword terms split CJK runs into character pairs.
  let identifier = "hashing@256v2"
  var dimensions: Int { Self.dimensions }
  let relatedThreshold: Float = 0.15
  let relatedMargin: Float = 0
  static let dimensions = 256

  func embed(documents: [(title: String, text: String)]) async throws -> [[Float]] {
    documents.map { Self.vector($0.title + " " + $0.text) }
  }

  func embed(query: String) async throws -> [Float] { Self.vector(query) }

  func unload() async {}

  static func vector(_ text: String) -> [Float] {
    var vector = [Float](repeating: 0, count: dimensions)
    let words = KeywordScorer.terms(text)
    for word in words {
      vector[Int(stableHash(word) % UInt64(dimensions))] += 1
    }
    return VectorIndex.normalized(vector)
  }

  /// FNV-1a: stable across launches (Swift's `hashValue` is seeded).
  static func stableHash(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in string.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01B3
    }
    return hash
  }
}

// MARK: - Vectors

/// Compact storage (Float16) and brute-force similarity search with
/// Accelerate: plenty for tens of thousands of passages on one phone.
enum VectorIndex {
  static func encode(_ vector: [Float]) -> Data {
    let halves = vector.map { Float16($0) }
    return halves.withUnsafeBufferPointer { Data(buffer: $0) }
  }

  static func decode(_ data: Data) -> [Float] {
    let count = data.count / MemoryLayout<Float16>.size
    return data.withUnsafeBytes { raw in
      let halves = raw.bindMemory(to: Float16.self)
      return (0..<count).map { Float(halves[$0]) }
    }
  }

  static func dot(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var result: Float = 0
    vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
    return result
  }

  static func normalized(_ vector: [Float]) -> [Float] {
    let norm = sqrt(dot(vector, vector))
    guard norm > 0 else { return vector }
    return vector.map { $0 / norm }
  }

  /// A document's passage vectors decoded once into one row-major matrix, so a question costs
  /// one matrix-vector product instead of decoding every vector again.
  struct Matrix: Sendable, Equatable {
    let rows: Int
    let dimension: Int
    let values: [Float]

    init(_ vectors: [[Float]]) {
      let size = vectors.first?.count ?? 0
      let usable = vectors.filter { $0.count == size && size > 0 }
      dimension = size
      rows = usable.count
      values = usable.flatMap { $0 }
    }

    init(encoded: [Data]) {
      self.init(encoded.map(VectorIndex.decode))
    }

    /// Each row's dot product with `query` (cosine similarity for unit vectors).
    func scores(_ query: [Float]) -> [Float] {
      guard rows > 0, query.count == dimension else { return Array(repeating: 0, count: rows) }
      var result = [Float](repeating: 0, count: rows)
      vDSP_mmul(values, 1, query, 1, &result, 1, vDSP_Length(rows), 1, vDSP_Length(dimension))
      return result
    }
  }

  /// Indices of the `limit` largest `scores`, best first.
  static func topIndices(_ scores: [Float], limit: Int) -> [Int] {
    guard limit > 0 else { return [] }
    if scores.count <= limit { return scores.indices.sorted { scores[$0] > scores[$1] } }
    var best: [Int] = []
    best.reserveCapacity(limit + 1)
    for index in scores.indices {
      guard best.count < limit || scores[index] > scores[best[best.count - 1]] else { continue }
      let position = best.firstIndex { scores[index] > scores[$0] } ?? best.count
      best.insert(index, at: position)
      if best.count > limit { best.removeLast() }
    }
    return best
  }

  /// The `limit` best candidates by cosine similarity (vectors are unit length).
  static func top<Item>(_ limit: Int, query: [Float], candidates: [(Item, [Float])])
    -> [(item: Item, score: Float)]
  {
    candidates
      .map { (item: $0.0, score: dot(query, $0.1)) }
      .sorted { $0.score > $1.score }
      .prefix(limit)
      .map { $0 }
  }
}

// MARK: - Keywords

/// Keyword relevance (BM25-style term weighting), used when no embedding
/// model is available yet and to break ties.
enum KeywordScorer {
  private static let stopwords: Set<String> = [
    "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "her", "was", "one",
    "our", "out", "has", "his", "how", "its", "who", "what", "when", "where", "which", "why",
    "with", "this", "that", "from", "they", "them", "have", "will", "your", "about", "into",
    "les", "des", "une", "est", "que", "qui", "pour", "dans", "par", "sur", "avec", "pas",
    // Two-letter function words of the languages the app reads (English, French, Spanish,
    // German, Italian, Portuguese, Dutch, Polish). Words that are also common acronyms (AI, US,
    // EU, UN) stay terms.
    "an", "as", "at", "be", "by", "do", "if", "in", "is", "it", "me", "my", "no", "of", "on", "or",
    "so", "to", "up", "we", "au", "ce", "de", "du", "en", "et", "il", "je", "la", "le", "ma", "ne",
    "sa", "se", "si", "ta", "te", "tu", "ou", "al", "el", "es", "lo", "mi", "su", "ya", "yo", "am",
    "da", "er", "im", "ja", "ob", "um", "wo", "zu", "di", "ti", "ao", "em", "na", "os", "ik", "om",
    "op", "ze", "go", "od", "po", "ty", "za",
  ]

  /// Words that count: 2+ characters (3+ dropped "AI", "UK" and "NY" until 2026-11-16, and a
  /// question made only of them matched nothing), minus stopwords.
  private static func isTerm(_ word: String) -> Bool { word.count >= 2 && !stopwords.contains(word) }

  /// Lowercased, accent-folded words of 2+ characters, minus stopwords. Chinese, Japanese and
  /// Korean aren't written with spaces between words: their runs become overlapping character
  /// pairs, which carry most of a CJK word's meaning.
  static func terms(_ text: String) -> [String] {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .flatMap { word -> [String] in
        guard word.unicodeScalars.contains(where: Chunker.isDense) else {
          return isTerm(word) ? [word] : []
        }
        return denseTerms(word)
      }
  }

  /// Character pairs of the dense (CJK) runs of `word`; other runs as ordinary words.
  private static func denseTerms(_ word: String) -> [String] {
    var terms: [String] = []
    var run: [Character] = []
    var plain = ""
    func flushRun() {
      if run.count == 1 { terms.append(String(run)) }
      if run.count > 1 { for i in 0..<(run.count - 1) { terms.append(String(run[i...i + 1])) } }
      run = []
    }
    func flushPlain() {
      if isTerm(plain) { terms.append(plain) }
      plain = ""
    }
    for character in word {
      if character.unicodeScalars.contains(where: Chunker.isDense) {
        flushPlain()
        run.append(character)
      } else {
        flushRun()
        plain.append(character)
      }
    }
    flushRun()
    flushPlain()
    return terms
  }

  /// Scores each document for `query`; higher is better, 0 = no shared terms.
  static func scores(query: String, documents: [String]) -> [Double] {
    let queryTerms = Set(terms(query))
    guard !queryTerms.isEmpty, !documents.isEmpty else { return documents.map { _ in 0 } }
    let documentTerms = documents.map(terms)
    let averageLength = Double(documentTerms.reduce(0) { $0 + $1.count }) / Double(documents.count)
    var documentFrequency: [String: Int] = [:]
    for terms in documentTerms {
      for term in Set(terms) where queryTerms.contains(term) { documentFrequency[term, default: 0] += 1 }
    }
    let count = Double(documents.count)
    return documentTerms.map { terms in
      var frequency: [String: Int] = [:]
      for term in terms where queryTerms.contains(term) { frequency[term, default: 0] += 1 }
      let length = Double(terms.count)
      return frequency.reduce(0.0) { score, entry in
        let df = Double(documentFrequency[entry.key] ?? 0)
        let idf = log(1 + (count - df + 0.5) / (df + 0.5))
        let tf = Double(entry.value)
        return score + idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * length / max(1, averageLength)))
      }
    }
  }
}
