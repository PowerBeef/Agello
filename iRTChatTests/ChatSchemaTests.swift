import SwiftData
import XCTest

@testable import iRTChat

/// Store migrations (V0/V1 → V2), branching, and store recovery.
@MainActor
final class ChatSchemaTests: XCTestCase {
  private var directory: URL!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ChatSchemaTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private var storeURL: URL { directory.appendingPathComponent("chats.store") }

  // MARK: - Migration

  func testV1StoreMigratesToBranchesWithoutLoss() throws {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    let threadID = UUID()
    let image = Data([0xFF, 0xD8, 0x01])
    do {
      let container = try ModelContainer(
        for: Schema(versionedSchema: SchemaV1.self),
        configurations: ModelConfiguration(url: storeURL))
      let context = container.mainContext
      let thread = SchemaV1.ChatThread(
        id: threadID, title: "Lighthouses", createdAt: base, modelIDRaw: "e4b")
      context.insert(thread)
      for (offset, (role, text)) in [("user", "Hi"), ("model", "Hello!"), ("user", "Tell me more")]
        .enumerated()
      {
        let turn = SchemaV1.ChatTurn(
          id: UUID(), roleRaw: role, text: text, createdAt: base.addingTimeInterval(Double(offset)))
        if offset == 0 {
          turn.imageData = image
          turn.hasAudio = true
        }
        thread.turns.append(turn)
      }
      try context.save()
    }

    let opened = ChatStoreLoader.open(url: storeURL)
    XCTAssertNil(opened.recoveryNotice)
    let threads = try opened.container.mainContext.fetch(FetchDescriptor<ChatThread>())
    let thread = try XCTUnwrap(threads.first)
    XCTAssertEqual(threads.count, 1)
    XCTAssertEqual(thread.id, threadID)
    XCTAssertEqual(thread.title, "Lighthouses")
    XCTAssertEqual(thread.modelID, .e4b)
    XCTAssertEqual(thread.orderedTurns.map(\.text), ["Hi", "Hello!", "Tell me more"])
    XCTAssertEqual(thread.activeLeafID, thread.orderedTurns.last?.id)
    XCTAssertNil(thread.orderedTurns.first?.parentID)
    XCTAssertEqual(thread.orderedTurns[2].parentID, thread.orderedTurns[1].id)
    XCTAssertEqual(thread.updatedAt, base.addingTimeInterval(2))
    XCTAssertEqual(thread.orderedTurns.first?.imageData, image)
    XCTAssertEqual(thread.orderedTurns.first?.hasAudio, true)
  }

  func testV0StoreMigrates() throws {
    do {
      let container = try ModelContainer(
        for: Schema(versionedSchema: SchemaV0.self),
        configurations: ModelConfiguration(url: storeURL))
      let thread = SchemaV0.ChatThread(
        id: UUID(), title: "Old", createdAt: Date(), modelIDRaw: "e2b")
      container.mainContext.insert(thread)
      thread.turns.append(
        SchemaV0.ChatTurn(id: UUID(), roleRaw: "user", text: "From the first release", createdAt: Date()))
      try container.mainContext.save()
    }
    let opened = ChatStoreLoader.open(url: storeURL)
    XCTAssertNil(opened.recoveryNotice)
    let thread = try XCTUnwrap(
      try opened.container.mainContext.fetch(FetchDescriptor<ChatThread>()).first)
    XCTAssertEqual(thread.orderedTurns.map(\.text), ["From the first release"])
    XCTAssertEqual(thread.orderedTurns.first?.hasAudio, false)
  }

  func testV2StoreMigratesToV3WithoutLoss() throws {
    let threadID = UUID()
    let image = Data([0xFF, 0xD8, 0x02])
    do {
      let container = try ModelContainer(
        for: Schema(versionedSchema: SchemaV2.self),
        configurations: ModelConfiguration(url: storeURL))
      let thread = SchemaV2.ChatThread(title: "Pinned trip")
      thread.id = threadID
      thread.isPinned = true
      container.mainContext.insert(thread)
      let first = SchemaV2.ChatTurn(role: .user, text: "Plan Kyoto", imageData: image)
      let reply = SchemaV2.ChatTurn(role: .model, text: "Day 1: temples")
      reply.parentID = first.id
      thread.turns.append(contentsOf: [first, reply])
      thread.activeLeafID = reply.id
      try container.mainContext.save()
    }

    let opened = ChatStoreLoader.open(url: storeURL)
    XCTAssertNil(opened.recoveryNotice)
    let context = opened.container.mainContext
    let thread = try XCTUnwrap(try context.fetch(FetchDescriptor<ChatThread>()).first)
    XCTAssertEqual(thread.id, threadID)
    XCTAssertTrue(thread.isPinned)
    XCTAssertNil(thread.projectID)
    XCTAssertEqual(thread.orderedTurns.map(\.text), ["Plan Kyoto", "Day 1: temples"])
    XCTAssertEqual(thread.orderedTurns.first?.imageData, image)

    // The new models work in the migrated store.
    let project = Project(name: "Travel")
    context.insert(project)
    thread.projectID = project.id
    let document = ChatDocument(
      name: "guide.pdf", kindRaw: "pdf", byteCount: 10, pageCount: 2, text: "…",
      projectID: project.id)
    document.chunks.append(DocumentChunk(index: 0, text: "Temples", pageStart: 1, pageEnd: 1))
    context.insert(document)
    context.insert(MemoryItem(text: "Prefers trains"))
    XCTAssertNoThrow(try context.save())
    XCTAssertEqual(try context.fetch(FetchDescriptor<DocumentChunk>()).count, 1)
  }

  func testUnreadableStoreIsSetAsideNotFatal() throws {
    try Data("not a database".utf8).write(to: storeURL)
    let opened = ChatStoreLoader.open(url: storeURL)
    XCTAssertNotNil(opened.recoveryNotice)
    let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertTrue(files.contains { $0.contains(".unreadable-") }, "Backup missing: \(files)")
    // The fresh store works.
    opened.container.mainContext.insert(ChatThread())
    XCTAssertNoThrow(try opened.container.mainContext.save())
  }

  // MARK: - Branches

  private func makeThread() throws -> (ModelContext, ChatThread) {
    let container = try ModelContainer(
      for: ChatStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = ModelContext(container)
    let thread = ChatThread()
    context.insert(thread)
    retained = container
    return (context, thread)
  }
  private var retained: ModelContainer?

  func testAppendBuildsAPath() throws {
    let (_, thread) = try makeThread()
    let hi = ChatTurn(role: .user, text: "Hi")
    thread.append(hi)
    let hello = ChatTurn(role: .model, text: "Hello")
    thread.append(hello)
    XCTAssertEqual(thread.orderedTurns.map(\.text), ["Hi", "Hello"])
    XCTAssertEqual(hello.parentID, hi.id)
    XCTAssertEqual(thread.activeLeafID, hello.id)
  }

  func testRegenerateCreatesSwitchableVersions() throws {
    let (_, thread) = try makeThread()
    let question = ChatTurn(role: .user, text: "Q")
    thread.append(question)
    let first = ChatTurn(role: .model, text: "A1")
    thread.append(first)
    // Regenerate: a sibling reply under the same question.
    let second = ChatTurn(role: .model, text: "A2")
    second.createdAt = first.createdAt.addingTimeInterval(1)
    thread.addVersion(second, of: first)

    XCTAssertEqual(thread.orderedTurns.map(\.text), ["Q", "A2"])
    XCTAssertEqual(thread.siblings(of: second).map(\.text), ["A1", "A2"])
    thread.selectBranch(through: first)
    XCTAssertEqual(thread.orderedTurns.map(\.text), ["Q", "A1"])
  }

  func testEditingAnEarlierMessageBranchesAndSelectionFollowsLatestReply() throws {
    let (_, thread) = try makeThread()
    let q1 = ChatTurn(role: .user, text: "Q1")
    thread.append(q1)
    let a1 = ChatTurn(role: .model, text: "A1")
    thread.append(a1)
    let q2 = ChatTurn(role: .user, text: "Q2")
    thread.append(q2)
    // Edit Q1 → a sibling user turn with its own reply.
    let q1b = ChatTurn(role: .user, text: "Q1 edited")
    q1b.createdAt = q2.createdAt.addingTimeInterval(1)
    thread.addVersion(q1b, of: q1)
    XCTAssertNil(q1b.parentID, "Editing the first message starts a new root branch")
    let a1b = ChatTurn(role: .model, text: "A1 edited")
    a1b.createdAt = q1b.createdAt.addingTimeInterval(1)
    thread.append(a1b)
    XCTAssertEqual(thread.orderedTurns.map(\.text), ["Q1 edited", "A1 edited"])
    thread.selectBranch(through: q1)
    XCTAssertEqual(thread.orderedTurns.map(\.text), ["Q1", "A1", "Q2"])
  }

  func testRemovingTheLeafStepsBack() throws {
    let (_, thread) = try makeThread()
    let q = ChatTurn(role: .user, text: "Q")
    thread.append(q)
    let empty = ChatTurn(role: .model)
    thread.append(empty)
    thread.removeLeaf(empty)
    XCTAssertEqual(thread.activeLeafID, q.id)
    XCTAssertEqual(thread.orderedTurns.map(\.text), ["Q"])
  }

  func testMessagePartsRoundTrip() throws {
    let (_, thread) = try makeThread()
    let reply = ChatTurn(role: .model, text: "Paris [1]")
    thread.append(reply)
    XCTAssertNil(reply.partsData)
    reply.parts = MessageParts(
      toolActivity: [ToolActivityRecord(name: "web_search", summary: "Searched for capital of France")],
      sources: [SourceRecord(index: 1, title: "Paris", url: "https://en.wikipedia.org/wiki/Paris")])
    XCTAssertEqual(reply.parts.sources.first?.title, "Paris")
    reply.parts = MessageParts()
    XCTAssertNil(reply.partsData)
  }
}
