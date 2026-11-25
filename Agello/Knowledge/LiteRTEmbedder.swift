import Foundation
import LiteRTLM

/// EmbeddingGemma 2 (text, 270M) through LiteRT-LM, at its full 768 dimensions, normalized.
/// Loads on first use, on the GPU, in the runtime's float16 activations: probe 32 found them
/// within a cosine of 0.9956 of float32 with no overflow, at half the time.
actor LiteRTEmbedder: TextEmbedder {
  /// 256 until 2026-11-16. Google's card puts 768 about a point above 256 on multilingual search
  /// and 2.5 on code; vectors take 1.5 KB a passage in float16.
  static let outputSize = EmbeddingGemmaPrompts.outputSize
  nonisolated let dimensions = EmbeddingGemmaPrompts.outputSize
  nonisolated let identifier = EmbeddingGemmaPrompts.identifier
  /// Calibrated by probe 33 (the chats of KnowledgeScenarioTests.test03 and unrelated queries)
  /// at 768 dimensions: a query's own chat scored 0.645-0.727 and stood 0.094-0.152 above the
  /// median chat; the best other chat scored at most 0.579, and an unrelated query's best stood
  /// at most 0.044 above the median. At 256 the margin was 0.08 (matching chats 0.10-0.20 above
  /// the median, unrelated ones up to 0.07).
  nonisolated let relatedThreshold: Float = 0.60
  nonisolated let relatedMargin: Float = 0.07
  nonisolated let usesGPU = true

  private let modelURL: URL
  private var engine: EmbeddingEngine?
  /// The load in progress: a question asked while files are being indexed waits for it
  /// instead of loading a second engine (the actor is reentrant across `initialize`).
  private var loading: Task<EmbeddingEngine, Error>?
  /// Bumped by each unload: a load that finishes after one closes its engine instead of keeping
  /// it. The native load doesn't see cancellation, so it used to bring back the GPU engine a
  /// memory-pressure release had just let go (an external review, 2026-11-16).
  private var generation = 0
  /// Truncate, never fail: an input longer than the loaded signatures (1,024 tokens) used to
  /// fail its whole batch and the document with it.
  private let options = EmbeddingOptions(
    normalize: true, outputSize: LiteRTEmbedder.outputSize, inputOverflowStrategy: .truncate)
  /// Requests per native batch call.
  private static let batchSize = 8

  init(modelURL: URL) {
    self.modelURL = modelURL
  }

  func embed(documents: [(title: String, text: String)]) async throws -> [[Float]] {
    guard GPUGate.isOpen else { throw GPUGate.closedError }
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
    try await embed(query: query, task: .search)
  }

  func embed(query: String, task: EmbeddingQueryTask) async throws -> [Float] {
    guard GPUGate.isOpen else { throw GPUGate.closedError }
    let engine = try await loaded()
    guard GPUGate.isOpen else { throw GPUGate.closedError }
    return try await engine.computeEmbedding(
      contents: [.text(Self.queryPrompt(query, task: task))], options: options
    ).embedding
  }

  func unload() async {
    generation += 1
    loading?.cancel()
    loading = nil
    await engine?.close()
    engine = nil
  }

  /// EmbeddingGemma's prompt formats for documents and search queries.
  static func documentPrompt(title: String, text: String) -> String {
    EmbeddingGemmaPrompts.documentPrompt(title: title, text: text)
  }

  static func queryPrompt(_ query: String, task: EmbeddingQueryTask = .search) -> String {
    EmbeddingGemmaPrompts.queryPrompt(query, task: task)
  }

  private func loaded() async throws -> EmbeddingEngine {
    if let engine { return engine }
    let started = generation
    if let loading {
      let shared = try await loading.value
      guard generation == started else { throw CancellationError() }
      return shared
    }
    let task = Task { try await self.load() }
    loading = task
    defer { if loading == task { loading = nil } }
    let loaded = try await task.value
    guard generation == started else {
      await loaded.close()
      throw CancellationError()
    }
    engine = loaded
    return loaded
  }

  private func load() async throws -> EmbeddingEngine {
    let cacheDir = try EngineCache.embeddingDirectory()
    var lastError: Error?
    // On the GPU, tried twice: there's no other backend, and search falls back to keywords
    // (BM25) when the embedder can't load.
    for trial in 1...2 {
      // In the background a GPU load fails: stop, and load when the app is back.
      guard GPUGate.isOpen else { throw GPUGate.closedError }
      let candidate = EmbeddingEngine(
        config: EmbeddingEngineConfig(modelPath: modelURL.path, backend: .gpu, cacheDir: cacheDir))
      do {
        try await candidate.initialize()
        Log.engine.info("embedder: loaded (try \(trial))")
        return candidate
      } catch {
        lastError = error
        Log.engine.error("embedder: load failed (try \(trial)): \(LogText.errorKind(error), privacy: .public)")
        if trial == 1 { try? await Task.sleep(for: .milliseconds(750)) }
      }
    }
    throw lastError ?? ChatError.engineNotReady
  }
}
