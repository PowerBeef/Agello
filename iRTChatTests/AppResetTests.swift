import SwiftData
import XCTest

@testable import iRTChat

@MainActor
final class AppResetTests: XCTestCase {
  func testResetClearsEverythingButTheModels() throws {
    let container = try ModelContainer(
      for: ChatStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = container.mainContext
    let thread = ChatThread(title: "Kyoto")
    context.insert(thread)
    thread.append(ChatTurn(role: .user, text: "Hello"))
    context.insert(Project(name: "Hiking"))
    let document = ChatDocument(
      name: "notes.md", kindRaw: "text", byteCount: 10, pageCount: 1, text: "Notes",
      threadID: thread.id)
    context.insert(document)
    document.chunks.append(DocumentChunk(index: 0, text: "Notes", pageStart: 1, pageEnd: 1))
    context.insert(MemoryItem(text: "Lives in Montreal"))
    try context.save()

    let domain = "AppResetTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
    defaults.set(true, forKey: "memoryEnabled")
    defaults.set(Data([1]), forKey: "webSearch")
    defaults.set(Data([1]), forKey: "benchmarkReport")

    let inbox = FileManager.default.temporaryDirectory
      .appendingPathComponent("AppResetTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: inbox) }
    _ = try ShareInbox.save(.init(kind: .text, question: "Summarize", text: "Shared text"), base: inbox)
    XCTAssertEqual(ShareInbox.pending(base: inbox).count, 1)

    let models = FileManager.default.temporaryDirectory
      .appendingPathComponent("AppResetTests-models-\(UUID().uuidString).litertlm")
    try Data([0]).write(to: models)
    defer { try? FileManager.default.removeItem(at: models) }

    AppReset.perform(
      context: context, defaults: defaults, domain: domain, shareInbox: inbox, systemStores: false)

    XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatThread>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatTurn>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<Project>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<ChatDocument>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<DocumentChunk>()), 0)
    XCTAssertEqual(try context.fetchCount(FetchDescriptor<MemoryItem>()), 0)
    for key in ["memoryEnabled", "webSearch", "benchmarkReport"] {
      XCTAssertNil(defaults.object(forKey: key), key)
    }
    XCTAssertTrue(ShareInbox.pending(base: inbox).isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: models.path), "Files are untouched")
  }
}
