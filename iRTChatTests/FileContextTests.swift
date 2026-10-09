import SwiftData
import XCTest

@testable import iRTChat

final class FileContextTests: XCTestCase {
  func testSummaryIntent() {
    for question in [
      "Summarize this", "Can you give me an overview?", "TL;DR please", "What are the key points?",
      "Résume ce document", "De quoi parle ce PDF ?", "",
    ] {
      XCTAssertTrue(FileContext.wantsSummary(question), question)
    }
    for question in ["What was the budget in 2024?", "Who signed the contract on page 3?"] {
      XCTAssertFalse(FileContext.wantsSummary(question), question)
    }
  }

  func testSectionsGroupConsecutivePassagesWithPageRanges() {
    let chunk = String(repeating: "x", count: 1_500)  // ~508 tokens each
    let chunks = (0..<10).map {
      ChunkDraft(index: $0, text: chunk, pageStart: $0 + 1, pageEnd: $0 + 1)
    }
    let sections = FileContext.sections(chunks)
    XCTAssertGreaterThan(sections.count, 1)
    XCTAssertEqual(sections.first?.pageStart, 1)
    XCTAssertEqual(sections.last?.pageEnd, 10)
    XCTAssertEqual(sections.first?.label, "Pages 1–4")
    // Every passage is in exactly one section.
    XCTAssertEqual(sections.map { $0.text.components(separatedBy: "\n\n").count }.reduce(0, +), 10)
    XCTAssertTrue(FileContext.sectionPrompt(sections[0], of: "a.pdf").contains("(pages 1–4)"))
  }

  func testPromptLayout() {
    let prompt = FileContext.prompt(
      question: "What's the budget?",
      materials: [
        .full(name: "notes.md", pageCount: 0, text: "Buy boats."),
        .excerpts([(label: "report.pdf, p. 2", text: "Budget: 4.2M.")]),
      ])
    XCTAssertTrue(prompt.contains("<file name=\"notes.md\">\nBuy boats.\n</file>"))
    XCTAssertTrue(prompt.contains("[report.pdf, p. 2]\nBudget: 4.2M."))
    XCTAssertTrue(prompt.hasSuffix("Question: What's the budget?"))
    XCTAssertTrue(prompt.contains("cite"))
  }

  func testFitKeepsRankOrderWithinBudget() {
    let passages = (0..<10).map {
      Passage(
        documentID: UUID(), documentName: "a", pageStart: $0, pageEnd: $0,
        text: String(repeating: "y", count: 900), score: Double(10 - $0))
    }
    let kept = FileContext.fit(passages, budget: 1_000)
    XCTAssertEqual(kept.map(\.pageStart), [0, 1, 2])
    XCTAssertEqual(FileContext.fit(passages, budget: 1).count, 1, "Always at least one passage")
  }

  func testTruncate() {
    let text = (1...200).map { "Line \($0)" }.joined(separator: "\n")
    let cut = FileContext.truncate(text, tokens: 100)
    XCTAssertLessThan(cut.utf8.count, 310)
    XCTAssertTrue(cut.hasSuffix("\n…"))
    XCTAssertEqual(FileContext.truncate("short", tokens: 100), "short")
  }
}

/// The whole flow through the mock engine: attach, assemble, cite, cache.
@MainActor
final class FileChatTests: XCTestCase {
  private var container: ModelContainer!
  private var appState: AppState!
  private var mock: MockChatEngine { appState.engine as! MockChatEngine }
  private var context: ModelContext { container.mainContext }
  private var savedSelection: Any?

  override func setUp() async throws {
    savedSelection = UserDefaults.standard.object(forKey: "selectedThreadID")
    container = try ModelContainer(
      for: ChatStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    appState = AppState(useMockEngine: true)
    appState.modelContext = container.mainContext
  }

  override func tearDown() async throws {
    appState = nil
    container = nil
    UserDefaults.standard.set(savedSelection, forKey: "selectedThreadID")
  }

  private func attach(_ document: ExtractedDocument, to thread: ChatThread) -> FileRecord {
    let stored = appState.knowledge.add(document, threadID: thread.id)!
    return FileRecord(
      id: stored.id, name: stored.name, kind: stored.kindRaw, pageCount: stored.pageCount)
  }

  private func longReport(pages: Int = 40) -> ExtractedDocument {
    let pageTexts = (1...pages).map { page -> String in
      let fact =
        page == 23
        ? "The harbour renovation budget was 4.2 million dollars, approved in March."
        : "Section \(page) describes routine coastal maintenance and inspections."
      return fact + "\n\n" + String(repeating: "Details of the inspection schedule follow. ", count: 30)
    }
    return ExtractedDocument(name: "report.pdf", kind: .pdf, byteCount: 100_000, pages: pageTexts)
  }

  func testSmallFileIsSentWholeAndCited() async throws {
    let thread = appState.newThread(in: context)
    let file = attach(
      ExtractedDocument(name: "notes.md", kind: .text, byteCount: 20, pages: ["Buy boats and rope."]),
      to: thread)
    let accepted = await appState.send(
      text: "What should I buy?", imageData: nil, audioFileURL: nil, files: [file], in: thread)
    XCTAssertTrue(accepted)
    let log = await mock.sendLog
    let sent = try XCTUnwrap(log.last)
    XCTAssertTrue(sent.contains("<file name=\"notes.md\">\nBuy boats and rope."), sent)
    XCTAssertTrue(sent.hasSuffix("Question: What should I buy?"))
    // The saved message is what the user typed, with the file attached.
    let user = try XCTUnwrap(thread.orderedTurns.first)
    XCTAssertEqual(user.text, "What should I buy?")
    XCTAssertEqual(user.parts.files.map(\.name), ["notes.md"])
    XCTAssertEqual(thread.orderedTurns.last?.parts.sources.map(\.title), ["notes.md"])
  }

  func testSpecificQuestionOnALongFileUsesCitedExcerpts() async throws {
    let thread = appState.newThread(in: context)
    let file = attach(longReport(), to: thread)
    await appState.send(
      text: "What was the harbour renovation budget?", imageData: nil, audioFileURL: nil,
      files: [file], in: thread)
    let log = await mock.sendLog
    let sent = try XCTUnwrap(log.last)
    XCTAssertTrue(sent.contains("<excerpts>"), String(sent.prefix(400)))
    XCTAssertFalse(sent.contains("<file name"), "A 40-page file must not be sent whole")
    XCTAssertTrue(sent.contains("4.2 million"), "The relevant passage wasn't retrieved")
    let sources = try XCTUnwrap(thread.orderedTurns.last?.parts.sources)
    XCTAssertTrue(sources.contains { $0.title.contains("p. 23") }, "\(sources.map(\.title))")
    let helperPrompts = await mock.helperTextPrompts
    XCTAssertTrue(helperPrompts.isEmpty, "No summary needed for a specific question")
  }

  func testSummarizingALongFileWritesSectionSummariesOnce() async throws {
    let thread = appState.newThread(in: context)
    let file = attach(longReport(), to: thread)
    await appState.send(
      text: "Summarize this report", imageData: nil, audioFileURL: nil, files: [file], in: thread)
    let sections = await mock.helperTextPrompts.count
    XCTAssertGreaterThan(sections, 3)
    let log = await mock.sendLog
    let sent = try XCTUnwrap(log.last)
    XCTAssertTrue(sent.contains("<summary of=\"report.pdf\" pages=\"40\">"), String(sent.prefix(300)))
    XCTAssertTrue(sent.contains("Pages 1–"))
    XCTAssertNotNil(appState.knowledge.documents(threadID: thread.id).first?.summary)
    XCTAssertNil(appState.preparingStatus)

    // Asked again: the cached summary is reused.
    await appState.send(
      text: "Give me the key points again", imageData: nil, audioFileURL: nil, in: thread)
    let after = await mock.helperTextPrompts.count
    XCTAssertEqual(after, sections)
  }

  func testFileOnlyMessageIsTitledAfterTheFile() async throws {
    let thread = appState.newThread(in: context)
    let file = attach(
      ExtractedDocument(name: "lease.pdf", kind: .pdf, byteCount: 10, pages: ["Rent is due monthly."]),
      to: thread)
    await mock.setHelperResponse(#"{"title":"   "}"#)  // keep the provisional title
    let accepted = await appState.send(
      text: "", imageData: nil, audioFileURL: nil, files: [file], in: thread)
    XCTAssertTrue(accepted)
    XCTAssertEqual(thread.title, "lease.pdf")
    let log = await mock.sendLog
    let sent = try XCTUnwrap(log.last)
    XCTAssertTrue(sent.hasSuffix("Question: Describe the attached files."))
  }

  func testDeletingAChatDeletesItsFiles() throws {
    let thread = appState.newThread(in: context)
    _ = attach(longReport(pages: 3), to: thread)
    appState.deleteThread(thread, in: context)
    XCTAssertEqual(try context.fetch(FetchDescriptor<ChatDocument>()).count, 0)
    XCTAssertEqual(try context.fetch(FetchDescriptor<DocumentChunk>()).count, 0)
  }
}
