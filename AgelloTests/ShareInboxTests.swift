import SwiftData
import XCTest

@testable import Agello

final class ShareInboxTests: XCTestCase {
  private var base: URL!

  override func setUpWithError() throws {
    base = FileManager.default.temporaryDirectory.appendingPathComponent("ShareInbox-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: base)
  }

  func testSaveListAndRemove() throws {
    let first = ShareInbox.Item(kind: .text, question: "Translate", text: "Bonjour")
    var second = ShareInbox.Item(kind: .image, question: "", fileName: "image.jpg")
    second.createdAt = first.createdAt.addingTimeInterval(1)
    try ShareInbox.save(first, base: base)
    try ShareInbox.save(second, fileData: Data([0xFF, 0xD8]), base: base)
    let pending = ShareInbox.pending(base: base)
    XCTAssertEqual(pending.map(\.item.id), [first.id, second.id])
    XCTAssertNil(pending[0].file)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(pending[1].file)), Data([0xFF, 0xD8]))
    ShareInbox.remove(first.id, base: base)
    XCTAssertEqual(ShareInbox.pending(base: base).map(\.item.id), [second.id])
  }

  /// The app group is provisioned: the share extension and the app see
  /// the same inbox on this device.
  func testAppGroupContainerIsAvailable() {
    XCTAssertNotNil(ShareInbox.directory(), "App group container missing (entitlement/provisioning)")
  }

  func testDefaultQuestions() {
    XCTAssertEqual(ShareInbox.question(for: .init(kind: .image, question: "  ")), "What's in this image?")
    XCTAssertEqual(ShareInbox.question(for: .init(kind: .url, question: "")), "Summarize this.")
    XCTAssertEqual(ShareInbox.question(for: .init(kind: .text, question: "", text: "Short note")), "Short note")
    XCTAssertEqual(
      ShareInbox.question(for: .init(kind: .text, question: "", text: String(repeating: "x", count: 900))),
      "Summarize this.")
    XCTAssertEqual(ShareInbox.question(for: .init(kind: .file, question: "Key dates?")), "Key dates?")
  }
}

@MainActor
final class SharedItemFlowTests: XCTestCase {
  private var base: URL!
  private var container: ModelContainer!
  private var appState: AppState!
  private var mock: MockChatEngine { appState.engine as! MockChatEngine }
  private var saved: Any?

  override func setUp() async throws {
    saved = UserDefaults.standard.object(forKey: "selectedThreadID")
    base = FileManager.default.temporaryDirectory.appendingPathComponent("ShareFlow-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    container = try ModelContainer(
      for: ChatStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    appState = AppState(useMockEngine: true)
    appState.modelContext = container.mainContext
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: base)
    appState = nil
    container = nil
    UserDefaults.standard.set(saved, forKey: "selectedThreadID")
  }

  func testSharedFileIsAttachedAndAnswered() async throws {
    let file = base.appendingPathComponent("notes.md")
    try "The meeting moved to Thursday at 3 pm.".write(to: file, atomically: true, encoding: .utf8)
    try ShareInbox.save(
      .init(kind: .file, question: "When is the meeting?", fileName: "notes.md"), file: file, base: base)

    let answered = await appState.answerNextSharedItem(inbox: base)
    XCTAssertTrue(answered)
    let thread = try XCTUnwrap(
      try container.mainContext.fetch(FetchDescriptor<ChatThread>()).first { $0.id == appState.selectedThreadID })
    XCTAssertEqual(thread.orderedTurns.first?.text, "When is the meeting?")
    XCTAssertEqual(thread.orderedTurns.first?.parts.files.map(\.name), ["notes.md"])
    let log = await mock.sendLog
    XCTAssertTrue(log.last?.contains("Thursday at 3 pm") ?? false)
    XCTAssertTrue(ShareInbox.pending(base: base).isEmpty, "Item removed once answered")
    let again = await appState.answerNextSharedItem(inbox: base)
    XCTAssertFalse(again)
  }

  /// A shared item whose send fails stays in the inbox (for the next launch) and isn't retried
  /// on every activation; its file doesn't stay behind in the empty chat.
  func testAFailedSendKeepsTheSharedItem() async throws {
    let file = base.appendingPathComponent("notes.md")
    try "Bring the tent.".write(to: file, atomically: true, encoding: .utf8)
    try ShareInbox.save(.init(kind: .file, question: "Summarize", fileName: "notes.md"), file: file, base: base)
    await mock.setFitResult(.failure(.messageTooLong))
    let answered = await appState.answerNextSharedItem(inbox: base)
    XCTAssertFalse(answered)
    XCTAssertEqual(ShareInbox.pending(base: base).count, 1, "The item was lost with the failed send")
    XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<ChatDocument>()).isEmpty)
    let retried = await appState.answerNextSharedItem(inbox: base)
    XCTAssertFalse(retried, "Retried in the same session")
  }

  /// Launch and activation both ask for shared items: one pass answers each item once.
  func testOnePassAtATime() async throws {
    try ShareInbox.save(.init(kind: .text, question: "", text: "Only once"), base: base)
    let sendsBefore = await mock.sendLog.count
    let appState = try XCTUnwrap(appState)
    let base = try XCTUnwrap(base)
    let first = Task { await appState.answerSharedItems(inbox: base) }
    let second = Task { await appState.answerSharedItems(inbox: base) }
    await first.value
    await second.value
    let sends = await mock.sendLog.count - sendsBefore
    XCTAssertEqual(sends, 1)
    XCTAssertTrue(ShareInbox.pending(base: base).isEmpty)
  }

  func testSharedTextAndLinks() async throws {
    try ShareInbox.save(.init(kind: .text, question: "", text: "Bonjour tout le monde"), base: base)
    await appState.answerNextSharedItem(inbox: base)
    var log = await mock.sendLog
    XCTAssertEqual(log.last, "Bonjour tout le monde")

    appState.webSettings.allowed = false
    try ShareInbox.save(.init(kind: .url, question: "What is this?", url: "https://example.com/a"), base: base)
    await appState.answerNextSharedItem(inbox: base)
    log = await mock.sendLog
    XCTAssertEqual(log.last, "What is this?\n\nhttps://example.com/a", "No web access: the link is passed along")
    appState.webSettings.allowed = true
  }
}
