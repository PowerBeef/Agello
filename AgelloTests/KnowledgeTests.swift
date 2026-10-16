import SwiftData
import XCTest

@testable import Agello

@MainActor
final class KnowledgeTests: XCTestCase {
  private var container: ModelContainer!
  private var knowledge: KnowledgeBase!

  override func setUp() async throws {
    container = try ModelContainer(
      for: ChatStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    knowledge = KnowledgeBase(store: ModelStore(), useHashingEmbedder: true)
    knowledge.modelContext = container.mainContext
  }

  // MARK: - Vectors

  func testFloat16RoundTripAndRanking() {
    let a = VectorIndex.normalized([1, 2, 3, 4])
    let decoded = VectorIndex.decode(VectorIndex.encode(a))
    XCTAssertEqual(decoded.count, 4)
    for (x, y) in zip(a, decoded) { XCTAssertEqual(x, y, accuracy: 0.001) }
    XCTAssertEqual(VectorIndex.encode(a).count, 8, "Float16 = 2 bytes per dimension")

    let query = VectorIndex.normalized([1, 0, 0])
    let top = VectorIndex.top(
      2, query: query,
      candidates: [("b", VectorIndex.normalized([0, 1, 0])), ("a", VectorIndex.normalized([0.9, 0.1, 0])),
        ("c", VectorIndex.normalized([0.5, 0.5, 0]))])
    XCTAssertEqual(top.map(\.item), ["a", "c"])
  }

  func testKeywordScoresPreferMatchingPassages() {
    let scores = KeywordScorer.scores(
      query: "When was the lighthouse built?",
      documents: [
        "The museum opened in 1990.", "The lighthouse was built in 1874 on the cliff.",
        "Lighthouse keepers lived nearby.",
      ])
    XCTAssertEqual(scores.indices.max { scores[$0] < scores[$1] }, 1)
    XCTAssertEqual(scores[0], 0)
    XCTAssertEqual(KeywordScorer.terms("Élan, the CAFÉ!"), ["elan", "cafe"])
  }

  /// Chinese has no spaces between words: its runs become character pairs, so keywords still
  /// match. Other text is unchanged.
  func testKeywordTermsSplitCJKIntoCharacterPairs() {
    XCTAssertEqual(KeywordScorer.terms("The lighthouse keeper"), ["lighthouse", "keeper"])
    let terms = KeywordScorer.terms("北京大学的历史 and history")
    XCTAssertTrue(terms.contains("北京"))
    XCTAssertTrue(terms.contains("大学"))
    XCTAssertTrue(terms.contains("history"))
    let scores = KeywordScorer.scores(
      query: "北京大学", documents: ["上海的天气很好。", "北京大学成立于1898年。"])
    XCTAssertEqual(scores.indices.max { scores[$0] < scores[$1] }, 1)
    XCTAssertEqual(scores[0], 0)
  }

  /// Passages are sized by estimated tokens: digits and ideographs are about a token each, so
  /// their passages hold fewer characters and stay within what the embedder reads.
  func testDenseTextGetsShorterPassages() {
    let chinese = String(repeating: "数据显示北京的人口持续增长", count: 400)
    let digits = String(repeating: "2026 1874 4200 3911 ", count: 400)
    for text in [chinese, digits] {
      let chunks = Chunker.chunks(pages: [text], paged: false)
      XCTAssertGreaterThan(chunks.count, 1)
      for chunk in chunks { XCTAssertLessThanOrEqual(Chunker.weight(of: chunk.text), Chunker.targetCharacters) }
    }
    XCTAssertEqual(Chunker.weight(of: "abc"), 3)
    XCTAssertEqual(Chunker.weight(of: "123"), 12)
    XCTAssertEqual(Chunker.weight(of: "北京"), 8)
  }

  func testInterleavingTakesBothRankingsInTurn() {
    func passage(_ text: String) -> Passage {
      Passage(documentID: UUID(), documentName: "x", pageStart: nil, pageEnd: nil, text: text, score: 0)
    }
    let mixed = KnowledgeBase.interleave(
      [passage("a1"), passage("a2"), passage("a3")], [passage("b1")], limit: 4)
    XCTAssertEqual(mixed.map(\.text), ["a1", "b1", "a2", "a3"])
  }

  func testCitations() {
    var passage = Passage(
      documentID: UUID(), documentName: "report.pdf", pageStart: 3, pageEnd: 3, text: "", score: 1)
    XCTAssertEqual(passage.citation, "report.pdf, p. 3")
    passage.pageEnd = 4
    XCTAssertEqual(passage.citation, "report.pdf, pp. 3–4")
    passage.pageStart = nil
    XCTAssertEqual(passage.citation, "report.pdf")
  }

  // MARK: - Knowledge base

  /// Three pages, each long enough to be its own passage.
  private func report() -> ExtractedDocument {
    let filler = "\n\n" + String(repeating: "Further notes follow in this section. ", count: 45)
    return ExtractedDocument(
      name: "report.pdf", kind: .pdf, byteCount: 1_000,
      pages: [
        "Introduction. This report covers the coastal survey of 2026." + filler,
        "Budget. The survey cost 4.2 million dollars, mostly for boats and divers." + filler,
        "Wildlife. Seals and puffins were counted along the northern cliffs." + filler,
      ])
  }

  func testAddIndexesAndSearchFindsThePageByMeaning() async throws {
    let threadID = UUID()
    let document = try XCTUnwrap(knowledge.add(report(), threadID: threadID))
    XCTAssertEqual(document.pageCount, 3)
    XCTAssertFalse(document.chunks.isEmpty)
    await knowledge.waitForIndexing([document])
    XCTAssertEqual(document.indexedWith, HashingEmbedder().identifier)
    XCTAssertTrue(document.chunks.allSatisfy { $0.embedding != nil })

    let documents = knowledge.documents(threadID: threadID)
    XCTAssertEqual(documents.map(\.id), [document.id])
    XCTAssertGreaterThanOrEqual(document.chunks.count, 3)
    let passages = await knowledge.search(
      "What was the budget and cost in million dollars?", in: documents, limit: 1)
    let top = try XCTUnwrap(passages.first)
    XCTAssertTrue(top.text.contains("4.2 million"), top.citation)
    XCTAssertTrue((top.pageStart!...top.pageEnd!).contains(2), top.citation)
  }

  /// A file the embedder failed on is searched by keywords, beside files searched by meaning,
  /// and isn't retried on every question.
  func testAFailedFileIsSearchedByKeywordsAndNotRetried() async throws {
    let threadID = UUID()
    let good = try XCTUnwrap(knowledge.add(report(), threadID: threadID))
    let notes = ExtractedDocument(
      name: "notes.txt", kind: .text, byteCount: 100,
      pages: ["Puffin colony census: 1,240 nesting pairs on the eastern stacks."])
    let failed = try XCTUnwrap(knowledge.add(notes, threadID: threadID))
    await knowledge.waitForIndexing([good, failed])
    failed.indexedWith = KnowledgeBase.failedMarker(HashingEmbedder().identifier)
    for chunk in failed.chunks { chunk.embedding = nil }
    try container.mainContext.save()

    let documents = knowledge.documents(threadID: threadID)
    let passages = await knowledge.search("puffin census nesting pairs", in: documents, limit: 3)
    XCTAssertTrue(passages.contains { $0.documentName == "notes.txt" })
    XCTAssertTrue(passages.contains { $0.documentName == "report.pdf" })
    XCTAssertTrue(knowledge.searchesByKeywords(failed))
    knowledge.indexPending()
    XCTAssertFalse(knowledge.indexing.contains(failed.id))
  }

  /// A file attached before the embedding model arrived (never indexed).
  private func unindexedDocument() async throws -> ChatDocument {
    let document = try XCTUnwrap(knowledge.add(report(), threadID: UUID()))
    await knowledge.waitForIndexing([document])
    document.indexedWith = nil
    for chunk in document.chunks { chunk.embedding = nil }
    try container.mainContext.save()
    return document
  }

  func testIndexPendingIndexesFilesAttachedBeforeTheEmbedder() async throws {
    let document = try await unindexedDocument()
    knowledge.indexPending()
    await knowledge.waitForIndexing([document])
    XCTAssertEqual(document.indexedWith, HashingEmbedder().identifier)
    XCTAssertTrue(document.chunks.allSatisfy { $0.embedding != nil })
  }

  func testSearchIndexesUnindexedFilesFirst() async throws {
    let document = try await unindexedDocument()
    let passages = await knowledge.search("budget in million dollars", in: [document], limit: 1)
    XCTAssertEqual(document.indexedWith, HashingEmbedder().identifier, "Search must index first")
    XCTAssertTrue(passages.first?.text.contains("4.2 million") == true)
  }

  func testDocumentsAreScopedToTheirChatOrProject() {
    let thread = UUID()
    let project = UUID()
    knowledge.add(report(), threadID: thread)
    knowledge.add(
      ExtractedDocument(name: "notes.md", kind: .text, byteCount: 10, pages: ["Shared notes"]),
      projectID: project)
    XCTAssertEqual(knowledge.documents(threadID: thread).map(\.name), ["report.pdf"])
    XCTAssertEqual(knowledge.documents(projectID: project).map(\.name), ["notes.md"])
    XCTAssertTrue(knowledge.documents(threadID: project).isEmpty)
  }

  func testDeletingADocumentRemovesItsPassages() throws {
    let document = try XCTUnwrap(knowledge.add(report(), threadID: UUID()))
    knowledge.delete(document)
    XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<DocumentChunk>()).count, 0)
  }
}

// MARK: - Chats by meaning

extension KnowledgeTests {
  private func chat(_ title: String, _ user: String, _ reply: String) -> ChatThread {
    let thread = ChatThread(title: title)
    container.mainContext.insert(thread)
    thread.append(ChatTurn(role: .user, text: user))
    thread.append(ChatTurn(role: .model, text: reply))
    return thread
  }

  func testChatsAreIndexedOnceAndFoundByRelatedWords() async {
    let lighthouse = chat(
      "Lighthouse keepers", "How did lighthouse keepers live?", "Keepers lived in small cottages.")
    let tax = chat("Tax return", "When is the tax deadline?", "Usually April 30.")
    XCTAssertTrue(KnowledgeBase.needsSearchEmbedding(lighthouse))
    knowledge.indexChats([lighthouse, tax])
    await knowledge.waitForChatIndexing()
    XCTAssertNotNil(lighthouse.searchEmbedding)
    XCTAssertFalse(KnowledgeBase.needsSearchEmbedding(lighthouse))

    let hits = await knowledge.relatedChats("cottages of keepers", in: [lighthouse, tax], limit: 5)
    XCTAssertEqual(hits.first?.thread.id, lighthouse.id)
    XCTAssertFalse(hits.contains { $0.thread.id == tax.id })
  }

  func testShortChatsAreReindexedAfterNewMessages() async throws {
    let thread = chat("Garden", "Tomatoes?", "Plant in May.")
    knowledge.indexChats([thread])
    await knowledge.waitForChatIndexing()
    try await Task.sleep(for: .milliseconds(20))
    thread.append(ChatTurn(role: .user, text: "And peppers?"))
    XCTAssertTrue(KnowledgeBase.needsSearchEmbedding(thread))
    XCTAssertFalse(KnowledgeBase.needsSearchEmbedding(ChatThread()), "Empty chats are skipped")
  }
}

extension KnowledgeTests {
  /// Device scores from KnowledgeScenarioTests.test03 ("Italian pasta dinner").
  func testRelatedNeedsToStandOutFromTheMedian() {
    let scores: [(thread: String, score: Float)] = [
      ("carbonara", 0.743), ("tax", 0.608), ("kyoto", 0.575), ("car", 0.562),
    ]
    let hits = KnowledgeBase.related(scores, threshold: 0.60, margin: 0.08, limit: 5)
    XCTAssertEqual(hits.map(\.thread), ["carbonara"])
    // Nothing stands out: no related chats (a generic chat scored 0.65).
    let flat: [(thread: String, score: Float)] = [("a", 0.65), ("b", 0.62), ("c", 0.61)]
    XCTAssertTrue(KnowledgeBase.related(flat, threshold: 0.60, margin: 0.08, limit: 5).isEmpty)
    // Too few chats for a median.
    XCTAssertTrue(
      KnowledgeBase.related([("a", 0.9)], threshold: 0.60, margin: 0.08, limit: 5).isEmpty)
  }
}
