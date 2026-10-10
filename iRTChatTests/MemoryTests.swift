import SwiftData
import XCTest

@testable import iRTChat

final class MemoryHelperTests: XCTestCase {
  func testOnlyMessagesAboutTheUserAreExamined() {
    for message in [
      "I'm vegetarian, suggest a dinner", "My daughter is 6", "Remember that the gate code is 4521",
      "Je vis à Montréal", "J'aime le vélo",
    ] {
      XCTAssertTrue(HelperTasks.shouldLookForMemories(message), message)
    }
    for message in ["What is 2+2?", "Summarize this report", "Write a haiku about the sea"] {
      XCTAssertFalse(HelperTasks.shouldLookForMemories(message), message)
    }
  }

  func testParseCleansFacts() {
    let json = Data(#"{"memories":["  Is vegetarian. ", "", "x", "- Lives in Montreal"]}"#.utf8)
    XCTAssertEqual(HelperTasks.parseMemories(json), ["Is vegetarian", "Lives in Montreal"])
    XCTAssertEqual(HelperTasks.parseMemories(Data("not json".utf8)), [])
  }

  func testDuplicatesAreSkipped() {
    let kept = HelperTasks.newMemories(
      ["is Vegetarian", "Has a dog named Rex", "Has a dog named Rex", "Works as a nurse"],
      existing: ["Is vegetarian", "Works as a nurse in Montreal"])
    XCTAssertEqual(kept, ["Has a dog named Rex"])
  }

  func testMemoriesJoinTheSystemPrompt() {
    let prompt = SystemPrompt.compose(
      base: "Base.", personalization: Personalization(), project: nil,
      memories: ["Is vegetarian", "Lives in Montreal"])
    XCTAssertTrue(prompt.hasPrefix("Base."))
    XCTAssertTrue(prompt.contains("- Is vegetarian\n- Lives in Montreal"))
  }
}

@MainActor
final class MemoryFlowTests: XCTestCase {
  private var container: ModelContainer!
  private var appState: AppState!
  private var mock: MockChatEngine { appState.engine as! MockChatEngine }
  private var context: ModelContext { container.mainContext }
  private var saved: [String: Any] = [:]
  private static let keys = ["selectedThreadID", "memoryEnabled"]

  override func setUp() async throws {
    for key in Self.keys { saved[key] = UserDefaults.standard.object(forKey: key) }
    container = try ModelContainer(
      for: ChatStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    appState = AppState(useMockEngine: true)
    appState.modelContext = container.mainContext
    await mock.setHelperResponse(#"{"title":"Mock chat","memories":["Is vegetarian"]}"#)
  }

  override func tearDown() async throws {
    appState = nil
    container = nil
    for key in Self.keys { UserDefaults.standard.set(saved[key], forKey: key) }
  }

  private var memories: [MemoryItem] { (try? context.fetch(FetchDescriptor<MemoryItem>())) ?? [] }

  func testLearnedMemoryReachesTheNextChat() async throws {
    appState.memoryEnabled = true
    let thread = appState.newThread(in: context)
    await appState.send(
      text: "I'm vegetarian. Suggest a dinner.", imageData: nil, audioFileURL: nil, in: thread)
    XCTAssertEqual(memories.map(\.text), ["Is vegetarian"])
    XCTAssertEqual(memories.first?.sourceThreadID, thread.id)
    let reply = try XCTUnwrap(thread.orderedTurns.last)
    XCTAssertEqual(reply.parts.toolActivity.last?.name, "memory")

    await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: appState.newThread(in: context))
    let prompt = await mock.systemPrompt
    XCTAssertTrue(prompt.contains("- Is vegetarian"), prompt)
  }

  func testNothingIsLearnedOrUsedWhenOff() async {
    appState.memoryEnabled = false
    context.insert(MemoryItem(text: "Lives in Montreal"))
    await appState.send(
      text: "I'm vegetarian.", imageData: nil, audioFileURL: nil, in: appState.newThread(in: context))
    XCTAssertEqual(memories.count, 1)
    let prompt = await mock.systemPrompt
    XCTAssertFalse(prompt.contains("Montreal"), prompt)
  }

  func testImpersonalQuestionsDontRunTheHelper() async {
    appState.memoryEnabled = true
    await appState.send(
      text: "What is 2+2?", imageData: nil, audioFileURL: nil, in: appState.newThread(in: context))
    let prompts = await mock.helperPrompts
    XCTAssertFalse(prompts.contains { $0.contains("Already remembered") })
    XCTAssertTrue(memories.isEmpty)
  }

  func testEditedMemoriesApplyToTheNextMessage() async {
    appState.memoryEnabled = true
    let memory = MemoryItem(text: "Prefers trains")
    context.insert(memory)
    let thread = appState.newThread(in: context)
    await appState.send(text: "Plan a trip", imageData: nil, audioFileURL: nil, in: thread)
    var prompt = await mock.systemPrompt
    XCTAssertTrue(prompt.contains("Prefers trains"))
    memory.text = "Prefers buses"
    appState.memoriesChanged()
    await appState.send(text: "Again", imageData: nil, audioFileURL: nil, in: thread)
    prompt = await mock.systemPrompt
    XCTAssertTrue(prompt.contains("Prefers buses"), prompt)
    XCTAssertFalse(prompt.contains("Prefers trains"), prompt)
  }
}
