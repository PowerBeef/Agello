import Accelerate
import Foundation
import LiteRTLM

/// Turns text into unit-length vectors for search by meaning.
protocol TextEmbedder: Sendable {
  /// Stored with indexed data; a different identifier means "re-index".
  var identifier: String { get }
  /// Cosine similarity above which a chat can count as related to a search…
  var relatedThreshold: Float { get }
  /// …when it also beats the median chat by this much (0: threshold only).
  /// Short, generic chats score fairly high against any query, so a raw
  /// threshold alone shows unrelated chats.
  var relatedMargin: Float { get }
  func embed(documents: [(title: String, text: String)]) async throws -> [[Float]]
  func embed(query: String) async throws -> [Float]
  func unload() async
}

/// EmbeddingGemma 2 (text, 270M) through LiteRT-LM, truncated to 256
/// dimensions (Matryoshka) and normalized. Loads on first use: GPU, then CPU.
actor LiteRTEmbedder: TextEmbedder {
  static let dimensions = 256
  nonisolated let identifier = "embeddinggemma-2-text-270m@\(LiteRTEmbedder.dimensions)"
  /// Calibrated on device (KnowledgeScenarioTests.test03): matching chats
  /// scored 0.67-0.78 and stood 0.09-0.15 above the median chat; unrelated
  /// ones scored up to 0.61 but only 0.02 above it.
  nonisolated let relatedThreshold: Float = 0.60
  nonisolated let relatedMargin: Float = 0.08

  private let modelURL: URL
  private var engine: EmbeddingEngine?
  /// The load in progress: a question asked while files are being indexed waits for it
  /// instead of loading a second engine (the actor is reentrant across `initialize`).
  private var loading: Task<EmbeddingEngine, Error>?
  /// Truncate, never fail: an input longer than the loaded signatures (1,024 tokens) used to
  /// fail its whole batch and the document with it.
  private let options = EmbeddingOptions(
    normalize: true, outputSize: LiteRTEmbedder.dimensions, inputOverflowStrategy: .truncate)
  /// Requests per native batch call.
  private static let batchSize = 8

  init(modelURL: URL) {
    self.modelURL = modelURL
  }

  func embed(documents: [(title: String, text: String)]) async throws -> [[Float]] {
    let engine = try await loaded()
    var vectors: [[Float]] = []
    vectors.reserveCapacity(documents.count)
    for start in stride(from: 0, to: documents.count, by: Self.batchSize) {
      // A deleted document or a move to the background stops the work between batches.
      try Task.checkCancellation()
      guard GPUGate.isOpen else { throw GPUGate.closedError }
      let batch = documents[start..<min(start + Self.batchSize, documents.count)]
      let inputs = batch.map { [Content.text(Self.documentPrompt(title: $0.title, text: $0.text))] }
      let responses = try await engine.computeEmbeddingBatch(contentsBatch: inputs, options: options)
      vectors += responses.map(\.embedding)
      await Task.yield()
    }
    return vectors
  }

  func embed(query: String) async throws -> [Float] {
    let engine = try await loaded()
    return try await engine.computeEmbedding(
      contents: [.text(Self.queryPrompt(query))], options: options
    ).embedding
  }

  func unload() async {
    loading?.cancel()
    loading = nil
    await engine?.close()
    engine = nil
  }

  /// EmbeddingGemma's prompt formats for documents and search queries.
  static func documentPrompt(title: String, text: String) -> String {
    "title: \(title.isEmpty ? "none" : String(title.prefix(80))) | text: \(text)"
  }

  static func queryPrompt(_ query: String) -> String {
    "task: search result | query: \(query)"
  }

  private func loaded() async throws -> EmbeddingEngine {
    if let engine { return engine }
    if let loading { return try await loading.value }
    let task = Task { try await self.load() }
    loading = task
    defer { loading = nil }
    let loaded = try await task.value
    engine = loaded
    return loaded
  }

  private func load() async throws -> EmbeddingEngine {
    let cacheDir = try EngineCache.embeddingDirectory()
    var lastError: Error?
    for backend: Backend in [.gpu, .cpu()] {
      // In the background a GPU load fails: don't settle for the CPU for good.
      guard GPUGate.isOpen else { throw GPUGate.closedError }
      let candidate = EmbeddingEngine(
        config: EmbeddingEngineConfig(modelPath: modelURL.path, backend: backend, cacheDir: cacheDir))
      do {
        try await candidate.initialize()
        Log.engine.info("embedder: loaded on \(String(describing: backend), privacy: .public)")
        return candidate
      } catch {
        lastError = error
        Log.engine.error("embedder: \(String(describing: backend), privacy: .public) failed: \(String(describing: error), privacy: .public)")
      }
    }
    throw lastError ?? ChatError.engineNotReady
  }
}

/// Deterministic bag-of-words vectors (hashed words and word pairs): keeps
/// retrieval working with the mock engine and in unit tests, no model needed.
struct HashingEmbedder: TextEmbedder {
  /// v2: keyword terms split CJK runs into character pairs.
  let identifier = "hashing@256v2"
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
  ]

  /// Lowercased, accent-folded words of 3+ characters, minus stopwords. Chinese, Japanese and
  /// Korean aren't written with spaces between words: their runs become overlapping character
  /// pairs, which carry most of a CJK word's meaning.
  static func terms(_ text: String) -> [String] {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .flatMap { word -> [String] in
        guard word.unicodeScalars.contains(where: Chunker.isDense) else {
          return word.count >= 3 && !stopwords.contains(word) ? [word] : []
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
      if plain.count >= 3, !stopwords.contains(plain) { terms.append(plain) }
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
