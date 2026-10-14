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

  init(store: ModelStore, useHashingEmbedder: Bool) {
    self.store = store
    self.useHashingEmbedder = useHashingEmbedder
  }

  /// The embedder, once its model is on the device; otherwise starts (or
  /// queues) the model download and returns nil.
  func currentEmbedder() -> (any TextEmbedder)? {
    if let embedder { return embedder }
    if useHashingEmbedder {
      embedder = HashingEmbedder()
      return embedder
    }
    let spec = ModelCatalog.embeddingGemma
    guard store.isDownloaded(spec), let url = store.localURL(for: spec) else {
      store.ensureDownloaded(spec)
      return nil
    }
    embedder = LiteRTEmbedder(modelURL: url)
    return embedder
  }

  /// Release the embedding model's memory (it reloads on next use).
  func unloadEmbedder() async {
    await embedder?.unload()
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
    for draft in Chunker.chunks(pages: extracted.pages, paged: extracted.isPaged) {
      document.chunks.append(
        DocumentChunk(
          index: draft.index, text: draft.text, pageStart: draft.pageStart, pageEnd: draft.pageEnd))
    }
    context.insert(document)
    try? context.save()
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
    indexTasks[document.id]?.cancel()
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
      document.indexedWith != embedder.identifier
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
        let vectors = try await embedder.embed(documents: inputs)
        guard !Task.isCancelled, vectors.count == chunks.count, document.modelContext != nil else {
          return
        }
        for (chunk, vector) in zip(chunks, vectors) { chunk.embedding = VectorIndex.encode(vector) }
        document.indexedWith = embedder.identifier
        try? modelContext?.save()
        Log.engine.info(
          "knowledge: indexed \(chunks.count) passages in \(String(describing: ContinuousClock.now - started), privacy: .public)")
      } catch {
        Log.engine.error("knowledge: indexing failed: \(String(describing: error), privacy: .public)")
      }
    }
  }

  /// Index every document not yet indexed with the current embedder (e.g.
  /// once the embedding model has downloaded).
  func indexPending() {
    guard let context = modelContext, let embedder = currentEmbedder() else { return }
    let identifier = embedder.identifier
    // `nil` (never indexed) must match explicitly: SQL comparisons skip NULL.
    let descriptor = FetchDescriptor<ChatDocument>(
      predicate: #Predicate { $0.indexedWith == nil || $0.indexedWith != identifier })
    for document in (try? context.fetch(descriptor)) ?? [] { index(document) }
  }

  /// ``indexPending()`` when the embedding model is already on the device,
  /// so a launch never starts its download.
  func indexPendingIfAvailable() {
    guard useHashingEmbedder || store.isDownloaded(ModelCatalog.embeddingGemma) else { return }
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
  static func needsSearchEmbedding(_ thread: ChatThread) -> Bool {
    guard !thread.turns.isEmpty else { return false }
    guard let embeddedAt = thread.searchEmbeddedAt, thread.searchEmbedding != nil else { return true }
    return thread.updatedAt > embeddedAt && thread.turns.count <= searchTurns + 1
  }

  /// Chats being indexed for search right now.
  @ObservationIgnored private var chatIndexTask: Task<Void, Never>?

  /// Embed chats that need it, in the background (drawer opening).
  func indexChats(_ threads: [ChatThread]) {
    guard chatIndexTask == nil, let embedder = currentEmbedder() else { return }
    let pending = threads.filter(Self.needsSearchEmbedding)
    guard !pending.isEmpty else { return }
    let inputs = pending.map { (title: "none", text: Self.searchText(for: $0)) }
    chatIndexTask = Task {
      defer { chatIndexTask = nil }
      guard let vectors = try? await embedder.embed(documents: inputs), vectors.count == pending.count
      else { return }
      let now = Date()
      for (thread, vector) in zip(pending, vectors) where thread.modelContext != nil {
        thread.searchEmbedding = VectorIndex.encode(vector)
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
    let candidates = threads.compactMap { thread in
      thread.searchEmbedding.map { (thread, VectorIndex.decode($0)) }
    }
    return VectorIndex.top(candidates.count, query: queryVector, candidates: candidates)
      .map { (thread: $0.item, score: $0.score) }
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
    let chunks = documents.flatMap { document in document.chunks.map { (document, $0) } }
    guard !chunks.isEmpty else { return [] }

    func passage(_ pair: (ChatDocument, DocumentChunk), score: Double) -> Passage {
      Passage(
        documentID: pair.0.id, documentName: pair.0.name, pageStart: pair.1.pageStart,
        pageEnd: pair.1.pageEnd, text: pair.1.text, score: score)
    }

    if let embedder = currentEmbedder(),
      documents.allSatisfy({ $0.indexedWith == embedder.identifier }),
      let queryVector = try? await embedder.embed(query: query)
    {
      let candidates = chunks.compactMap { pair in
        pair.1.embedding.map { (pair, VectorIndex.decode($0)) }
      }
      return VectorIndex.top(limit, query: queryVector, candidates: candidates)
        .map { passage($0.item, score: Double($0.score)) }
    }

    // No embeddings yet: rank by keywords, falling back to document order.
    let scores = KeywordScorer.scores(query: query, documents: chunks.map(\.1.text))
    return zip(chunks, scores)
      .enumerated()
      .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
      .prefix(limit)
      .map { passage($0.element.0, score: $0.element.1) }
  }
}
