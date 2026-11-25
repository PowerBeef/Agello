import Foundation
import Observation
import SwiftData

/// A retrieved passage, with what's needed to cite it.
struct Passage: Equatable, Sendable {
  var documentID: UUID
  var documentName: String
  var pageStart: Int?
  var pageEnd: Int?
  var text: String
  var score: Double

  /// "report.pdf, p. 3" / "report.pdf, pp. 3–4" / "notes.md".
  var citation: String {
    guard let start = pageStart else { return documentName }
    if let end = pageEnd, end != start { return "\(documentName), pp. \(start)–\(end)" }
    return "\(documentName), p. \(start)"
  }
}

/// Attached files: stores them with their passages, indexes passages with
/// the embedding model in the background, and finds the passages relevant
/// to a question (by meaning, or by keywords until the model is available).
@MainActor
@Observable
final class KnowledgeBase {
  /// Documents being indexed right now (shown as "Reading…").
  private(set) var indexing: Set<UUID> = []

  var modelContext: ModelContext?
  @ObservationIgnored private let store: ModelStore
  @ObservationIgnored private let useHashingEmbedder: Bool
  @ObservationIgnored private var embedder: (any TextEmbedder)?
  @ObservationIgnored private var indexTasks: [UUID: Task<Void, Never>] = [:]
  /// Short texts' vectors (memories) for the session, by embedder and text.
  @ObservationIgnored private var textVectors: [String: [Float]] = [:]
  /// Each indexed document's passages and their vectors, decoded once (with every vector decoded
  /// again, a question over 1,800 passages cost 27 ms on a Mac before any searching).
  @ObservationIgnored private var vectorCache:
    [UUID: (indexedWith: String, chunks: [DocumentChunk], matrix: VectorIndex.Matrix)] = [:]

  init(store: ModelStore, useHashingEmbedder: Bool) {
    self.store = store
    self.useHashingEmbedder = useHashingEmbedder
  }

  /// Path to the Core AI Neural Engine EmbeddingGemma 2 bundle when present beside model files.
  nonisolated static func aneBundleURL() -> URL? {
    EngineFactory.aneBundleURL()
  }

  /// Whether an embedding model (Core AI ANE bundle, LiteRT-LM fallback, or Simulator bridge) is ready.
  var hasLocalEmbedder: Bool {
    useHashingEmbedder || EngineFactory.hasLocalEmbedder(store: store)
  }

  /// Whether the active embedder uses the Metal GPU (needs cancellation when leaving foreground).
  var usesGPUEmbedder: Bool {
    if let embedder { return embedder.usesGPU }
    guard !useHashingEmbedder else { return false }
    return EngineFactory.usesGPUEmbedderWithoutInstance()
  }

  /// The embedder, once its model is on the device; otherwise starts (or
  /// queues) the model download and returns nil. Uses the Core AI Neural Engine bundle so
  /// retrieval never contends with E4B on the Metal GPU.
  func currentEmbedder() -> (any TextEmbedder)? {
    if let embedder { return embedder }
    if useHashingEmbedder {
      embedder = HashingEmbedder()
      return embedder
    }
    embedder = EngineFactory.makeLocalEmbedder(store: store)
    return embedder
  }

  /// Release the embedding model's memory (it reloads on next use).
  func unloadEmbedder() async {
    await embedder?.unload()
  }

  /// A memory warning: unload EmbeddingGemma unless it's indexing (it reloads on its next use).
  func releaseMemory() async {
    guard indexing.isEmpty else { return }
    await unloadEmbedder()
  }

  /// Forget the embedder (its model was deleted): the next use downloads it again.
  func resetEmbedder() async {
    cancelIndexing()
    await embedder?.unload()
    embedder = nil
  }

  /// `indexedWith` of a document the embedder failed on: searched by keywords, and not retried
  /// with that embedder (it failed on every question and at every launch).
  static func failedMarker(_ identifier: String) -> String { "failed:" + identifier }

  /// Whether `document` is searched by keywords because embedding it failed.
  func searchesByKeywords(_ document: ChatDocument) -> Bool {
    document.indexedWith?.hasPrefix("failed:") ?? false
  }

  // MARK: - Documents

  /// Save `extracted` as a document of a chat or a project, then index it.
  @discardableResult
  func add(_ extracted: ExtractedDocument, threadID: UUID? = nil, projectID: UUID? = nil)
    -> ChatDocument?
  {
    guard let context = modelContext else { return nil }
    let document = ChatDocument(
      name: extracted.name, kindRaw: extracted.kind.rawValue, byteCount: extracted.byteCount,
      pageCount: extracted.isPaged ? extracted.pages.count : 0, text: extracted.fullText,
      threadID: threadID, projectID: projectID)
    // Extraction already split files into passages off the main thread; small texts made here
    // (shared text, a web page) are split now.
    for draft in extracted.chunks ?? Chunker.chunks(pages: extracted.pages, paged: extracted.isPaged) {
      document.chunks.append(
        DocumentChunk(
          index: draft.index, text: draft.text, pageStart: draft.pageStart, pageEnd: draft.pageEnd))
    }
    context.insert(document)
    try? context.save()
    SpotlightIndex.indexDocuments([document])
    index(document)
    return document
  }

  func documents(threadID: UUID) -> [ChatDocument] {
    let descriptor = FetchDescriptor<ChatDocument>(
      predicate: #Predicate { $0.threadID == threadID }, sortBy: [SortDescriptor(\.createdAt)])
    return (try? modelContext?.fetch(descriptor)) ?? []
  }

  func documents(projectID: UUID) -> [ChatDocument] {
    let descriptor = FetchDescriptor<ChatDocument>(
      predicate: #Predicate { $0.projectID == projectID }, sortBy: [SortDescriptor(\.createdAt)])
    return (try? modelContext?.fetch(descriptor)) ?? []
  }

  func delete(_ document: ChatDocument) {
    let id = document.id
    indexTasks[id]?.cancel()
    vectorCache[id] = nil
    SpotlightIndex.removeDocuments([id])
    modelContext?.delete(document)
    try? modelContext?.save()
  }

  /// Delete a chat's own documents (with the chat).
  func deleteDocuments(threadID: UUID) {
    for document in documents(threadID: threadID) { delete(document) }
  }

  // MARK: - Indexing

  /// Embed `document`'s passages in the background (no-op when already
  /// indexed with the current embedder, or no embedder is available yet).
  func index(_ document: ChatDocument) {
    guard indexTasks[document.id] == nil, let embedder = currentEmbedder(),
      document.indexedWith != embedder.identifier,
      document.indexedWith != Self.failedMarker(embedder.identifier)
    else { return }
    let id = document.id
    let chunks = document.chunks.sorted { $0.index < $1.index }
    let inputs = chunks.map { (title: document.name, text: $0.text) }
    indexing.insert(id)
    indexTasks[id] = Task {
      defer {
        indexing.remove(id)
        indexTasks[id] = nil
      }
      let started = ContinuousClock.now
      do {
        if ThermalPolicy.current.pauseBackgroundANE, !embedder.usesGPU {
          return
        }
        // Run embedding + binary encoding at `.utility` QoS so A19 Pro schedules background ANE
        // indexing onto E-cores without contending with P-core UI or foreground E4B decode.
        let encoded: (vectors: [[Float]], blobs: [Data]) = try await Task.detached(priority: .utility) {
          let vectors = try await embedder.embed(documents: inputs)
          let blobs = vectors.map { VectorIndex.encode($0) }
          return (vectors, blobs)
        }.value
        guard !Task.isCancelled, encoded.vectors.count == chunks.count, document.modelContext != nil else {
          return
        }
        for (chunk, blob) in zip(chunks, encoded.blobs) { chunk.embedding = blob }
        document.indexedWith = embedder.identifier
        vectorCache[id] = (embedder.identifier, chunks, VectorIndex.Matrix(encoded.vectors))
        try? modelContext?.save()
        Log.engine.info(
          "knowledge: indexed \(chunks.count) passages in \(String(describing: ContinuousClock.now - started), privacy: .public)")
      } catch is CancellationError {
        // Stopped (deleted, backgrounded): indexed again later.
      } catch {
        Log.engine.error("knowledge: indexing failed: \(LogText.errorKind(error), privacy: .public)")
        // In the background the GPU is off limits: that's not this document's fault.
        guard !Task.isCancelled, !embedder.usesGPU || GPUGate.isOpen, document.modelContext != nil
        else { return }
        document.indexedWith = Self.failedMarker(embedder.identifier)
        try? modelContext?.save()
      }
    }
  }

  /// Embed `document` again after embedding it failed: its "Keyword search" row offers it. If no
  /// embedder is ready yet, ``indexPending()`` picks it up.
  func reindex(_ document: ChatDocument) {
    guard searchesByKeywords(document) else { return }
    document.indexedWith = nil
    try? modelContext?.save()
    index(document)
  }

  /// Stop indexing (the app moved to the background); ``indexPending()`` resumes it.
  func cancelIndexing() {
    for task in indexTasks.values { task.cancel() }
  }

  /// Index every document not yet indexed with the current embedder (e.g.
  /// once the embedding model has downloaded). Waits for the foreground when the embedder uses
  /// the GPU; ANE embedders can run without touching the Metal queue.
  func indexPending() {
    guard let context = modelContext, let embedder = currentEmbedder(),
      !embedder.usesGPU || GPUGate.isOpen
    else { return }
    let identifier = embedder.identifier
    let failed = Self.failedMarker(identifier)
    // `nil` (never indexed) must match explicitly: SQL comparisons skip NULL.
    let descriptor = FetchDescriptor<ChatDocument>(
      predicate: #Predicate {
        $0.indexedWith == nil || ($0.indexedWith != identifier && $0.indexedWith != failed)
      })
    for document in (try? context.fetch(descriptor)) ?? [] { index(document) }
  }

  /// ``indexPending()`` when the embedding model is already on the device,
  /// so a launch never starts its download.
  func indexPendingIfAvailable() {
    guard hasLocalEmbedder else { return }
    indexPending()
  }

  /// Wait for running indexing of `documents` to finish.
  func waitForIndexing(_ documents: [ChatDocument]) async {
    for document in documents {
      await indexTasks[document.id]?.value
    }
  }

  // MARK: - Chats by meaning

  /// What represents a chat in search: its title and opening turns.
  static func searchText(for thread: ChatThread) -> String {
    let opening = thread.orderedTurns.prefix(Self.searchTurns)
      .map { $0.text }
      .filter { !$0.isEmpty && !$0.hasPrefix(ChatTurn.errorPrefix) }
      .joined(separator: "\n")
    return String((thread.title + "\n" + opening).prefix(1_500))
  }

  /// Turns that make up a chat's search text.
  static let searchTurns = 6

  /// Whether a chat's search vector is missing or out of date (it changes
  /// only while the chat is short; later turns don't affect it).
  /// A vector of another length than `dimensions` (when given) is out of date too: it scores
  /// 0 against the current embedder's queries (vectors went from 256 to 768 on 2026-11-16).
  static func needsSearchEmbedding(_ thread: ChatThread, dimensions: Int? = nil) -> Bool {
    guard !thread.turns.isEmpty else { return false }
    guard let embeddedAt = thread.searchEmbeddedAt, let stored = thread.searchEmbedding else { return true }
    // Stored as float16: two bytes a component.
    if let dimensions, stored.count / 2 != dimensions { return true }
    return thread.updatedAt > embeddedAt && thread.turns.count <= searchTurns + 1
  }

  /// Chats being indexed for search right now.
  @ObservationIgnored private var chatIndexTask: Task<Void, Never>?

  /// Embed chats that need it, in the background (drawer opening). Defers under elevated
  /// thermal state or Low Power Mode and executes at `.utility` QoS on E-cores + ANE.
  func indexChats(_ threads: [ChatThread]) {
    let thermal = ThermalPolicy.current
    guard !thermal.deferBackgroundChatIndexing, !thermal.pauseBackgroundANE else { return }
    guard chatIndexTask == nil, let embedder = currentEmbedder() else { return }
    let pending = threads.filter { Self.needsSearchEmbedding($0, dimensions: embedder.dimensions) }
    guard !pending.isEmpty else { return }
    let inputs = pending.map { (title: "none", text: Self.searchText(for: $0)) }
    chatIndexTask = Task {
      defer { chatIndexTask = nil }
      let blobs: [Data]? = await Task.detached(priority: .utility) {
        guard let vectors = try? await embedder.embed(documents: inputs) else { return nil }
        return vectors.map { VectorIndex.encode($0) }
      }.value
      guard let blobs, blobs.count == pending.count else { return }
      let now = Date()
      for (thread, blob) in zip(pending, blobs) where thread.modelContext != nil {
        thread.searchEmbedding = blob
        thread.searchEmbeddedAt = now
      }
      try? modelContext?.save()
      Log.engine.info("knowledge: indexed \(pending.count) chats for search")
    }
  }

  /// Chats related in meaning to `query`, best first (indexed ones only).
  func relatedChats(_ query: String, in threads: [ChatThread], limit: Int) async -> [(
    thread: ChatThread, score: Float
  )] {
    guard let embedder = currentEmbedder() else { return [] }
    let scores = await chatScores(query, in: threads)
    return Self.related(
      scores, threshold: embedder.relatedThreshold, margin: embedder.relatedMargin, limit: limit)
  }

  /// Scores (best first) that pass the threshold and, with a margin, beat
  /// the median by it (needs 3+ chats to have a meaningful median).
  static func related<Item>(
    _ scores: [(thread: Item, score: Float)], threshold: Float, margin: Float, limit: Int
  ) -> [(thread: Item, score: Float)] {
    var floor = threshold
    if margin > 0 {
      guard scores.count >= 3 else { return [] }
      let sorted = scores.map(\.score).sorted()
      floor = max(threshold, sorted[sorted.count / 2] + margin)
    }
    return Array(scores.filter { $0.score >= floor }.prefix(limit))
  }

  /// Similarity of every indexed chat to `query`, best first.
  func chatScores(_ query: String, in threads: [ChatThread]) async -> [(
    thread: ChatThread, score: Float
  )] {
    await chatIndexTask?.value
    guard let embedder = currentEmbedder(),
      let queryVector = try? await embedder.embed(query: query)
    else { return [] }
    let candidates = threads.compactMap { thread -> (ChatThread, [Float])? in
      guard !thread.isDeleted, thread.modelContext != nil else { return nil }
      return thread.searchEmbedding.map { (thread, VectorIndex.decode($0)) }
    }
    return VectorIndex.top(candidates.count, query: queryVector, candidates: candidates)
      .map { (thread: $0.item, score: $0.score) }
  }

  /// `texts` by meaning against `query`, closest first; nil without an embedder or when embedding
  /// fails. For short texts such as memories: their vectors are kept for the session.
  func rank(
    _ texts: [String], against query: String, task: EmbeddingQueryTask = .search
  ) async -> [String]? {
    guard let embedder = currentEmbedder(), !texts.isEmpty, !query.isEmpty else { return nil }
    let key = { (text: String) in embedder.identifier + "\u{0}" + text }
    guard await textVectorsCached(texts, embedder: embedder) else { return nil }
    guard let queryVector = try? await embedder.embed(query: query, task: task) else { return nil }
    let scores = texts.map { VectorIndex.dot(textVectors[key($0)] ?? [], queryVector) }
    return texts.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }.map { texts[$0] }
  }

  /// The highest similarity of `text` to any of `texts`, both embedded as documents (cosines of
  /// the normalized vectors); nil without an embedder or when embedding fails. Probe 39 measured it
  /// for memories (2026-11-17): reworded facts (0.87–0.98) and different ones (0.83–0.96) overlap,
  /// so memories aren't deduplicated by meaning.
  func nearestSimilarity(of text: String, among texts: [String]) async -> Float? {
    guard let embedder = currentEmbedder(), !text.isEmpty, !texts.isEmpty else { return nil }
    let key = { (text: String) in embedder.identifier + "\u{0}" + text }
    guard await textVectorsCached(texts + [text], embedder: embedder), let vector = textVectors[key(text)]
    else { return nil }
    return texts.map { VectorIndex.dot(textVectors[key($0)] ?? [], vector) }.max()
  }

  /// Embeds the texts not embedded yet (as documents) into the session's cache.
  private func textVectorsCached(_ texts: [String], embedder: TextEmbedder) async -> Bool {
    let key = { (text: String) in embedder.identifier + "\u{0}" + text }
    let missing = Array(Set(texts.filter { textVectors[key($0)] == nil }))
    guard !missing.isEmpty else { return true }
    guard let vectors = try? await embedder.embed(documents: missing.map { (title: "none", text: $0) }),
      vectors.count == missing.count
    else { return false }
    for (text, vector) in zip(missing, vectors) { textVectors[key(text)] = vector }
    return true
  }

  /// Semantically recalls the most relevant earlier exchanges from `evicted` turns for `query`
  /// within `budget` tokens (falling back to BM25 keyword matches when no embedder is ready).
  func recallEvictedTurns(
    _ evicted: [(role: ChatRole, text: String)], for query: String, budget: Int, limit: Int = 4
  ) async -> String? {
    let exchanges = ContextBudget.evictedExchanges(evicted)
    guard !exchanges.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      budget >= ContextBudget.minTruncatedTokens, limit > 0
    else { return nil }

    var ranked: [String] = []
    if let embedder = currentEmbedder(),
      await textVectorsCached(exchanges, embedder: embedder),
      let queryVector = try? await embedder.embed(query: query, task: .search)
    {
      let key = { (text: String) in embedder.identifier + "\u{0}" + text }
      let scored = exchanges.enumerated().map { index, text in
        (index: index, text: text, score: VectorIndex.dot(textVectors[key(text)] ?? [], queryVector))
      }
      // Require either semantic similarity above the embedder's threshold or positive keyword overlap
      // so unrelated earlier turns aren't injected as noise.
      let keywords = KeywordScorer.scores(query: query, documents: exchanges)
      ranked = scored
        .filter { $0.score >= embedder.relatedThreshold || keywords[$0.index] > 0 }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index > $1.index }
        .prefix(limit)
        .map(\.text)
    } else {
      let scores = KeywordScorer.scores(query: query, documents: exchanges)
      ranked = zip(exchanges, scores).enumerated()
        .filter { $0.element.1 > 0 }
        .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset > $1.offset }
        .prefix(limit)
        .map(\.element.0)
    }
    return ContextBudget.recalledContext(exchanges: ranked, budget: budget)
  }

  /// Wait for chat indexing started by ``indexChats(_:)``.
  func waitForChatIndexing() async {
    await chatIndexTask?.value
  }

  // MARK: - Search

  /// The `limit` most relevant passages of `documents` for `query`.
  func search(_ query: String, in documents: [ChatDocument], limit: Int) async -> [Passage] {
    guard !documents.isEmpty, limit > 0 else { return [] }
    // Files attached before the embedding model was ready are indexed now.
    for document in documents { index(document) }
    await waitForIndexing(documents)

    func passage(_ pair: (ChatDocument, DocumentChunk), score: Double) -> Passage {
      Passage(
        documentID: pair.0.id, documentName: pair.0.name, pageStart: pair.1.pageStart,
        pageEnd: pair.1.pageEnd, text: pair.1.text, score: score)
    }

    // Each document by meaning when it's indexed, by keywords when it isn't (yet): one file
    // that failed to index used to send every file in the chat to keyword search.
    let embedder = currentEmbedder()
    let byMeaning = documents.filter { document in
      embedder.map { document.indexedWith == $0.identifier } ?? false
    }
    var meaning: [Passage] = []
    if let embedder, !byMeaning.isEmpty, let queryVector = try? await embedder.embed(query: query) {
      var scored: [(document: ChatDocument, chunk: DocumentChunk, score: Float)] = []
      for document in byMeaning {
        let entry = vectors(of: document, indexedWith: embedder.identifier)
        let scores = entry.matrix.scores(queryVector)
        for row in VectorIndex.topIndices(scores, limit: limit) {
          scored.append((document, entry.chunks[row], scores[row]))
        }
      }
      meaning = scored.sorted { $0.score > $1.score }.prefix(limit)
        .map { passage(($0.document, $0.chunk), score: Double($0.score)) }
    }
    let keywordDocuments =
      meaning.isEmpty && !byMeaning.isEmpty
      ? documents : documents.filter { document in !byMeaning.contains { $0 === document } }
    let keywordChunks = keywordDocuments.flatMap { document in document.chunks.map { (document, $0) } }
    var keywords: [Passage] = []
    if !keywordChunks.isEmpty {
      // Keyword ranking, falling back to document order.
      let scores = KeywordScorer.scores(query: query, documents: keywordChunks.map(\.1.text))
      keywords = zip(keywordChunks, scores)
        .enumerated()
        .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
        .prefix(limit)
        .map { passage($0.element.0, score: $0.element.1) }
    }
    return Self.interleave(meaning, keywords, limit: limit)
  }

  /// `document`'s passages with vectors and their matrix, decoded on first use (or kept from
  /// indexing) and reused until the document is indexed again.
  private func vectors(of document: ChatDocument, indexedWith identifier: String)
    -> (indexedWith: String, chunks: [DocumentChunk], matrix: VectorIndex.Matrix)
  {
    if let cached = vectorCache[document.id], cached.indexedWith == identifier { return cached }
    let decoded = document.chunks.sorted { $0.index < $1.index }
      .compactMap { chunk in chunk.embedding.map { (chunk, VectorIndex.decode($0)) } }
    // Rows and passages stay aligned: a vector of another size (none expected) is left out.
    let dimension = decoded.first?.1.count ?? 0
    let usable = decoded.filter { $0.1.count == dimension }
    let entry = (identifier, usable.map(\.0), VectorIndex.Matrix(usable.map(\.1)))
    vectorCache[document.id] = entry
    return entry
  }

  /// The best of two rankings whose scores can't be compared, taken in turn.
  static func interleave(_ first: [Passage], _ second: [Passage], limit: Int) -> [Passage] {
    var result: [Passage] = []
    var a = first[...]
    var b = second[...]
    while result.count < limit, !a.isEmpty || !b.isEmpty {
      if let next = a.popFirst() { result.append(next) }
      if result.count < limit, let next = b.popFirst() { result.append(next) }
    }
    return result
  }
}
