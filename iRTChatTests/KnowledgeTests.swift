import SwiftData
import XCTest

@testable import iRTChat

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
