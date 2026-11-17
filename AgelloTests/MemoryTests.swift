import SwiftData
import XCTest

@testable import Agello

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

  /// The languages the app reads, each with a message about the user and one that isn't
  /// (English and French only until 2026-11-16).
  func testMemoryCuesInEachLanguage() {
    let aboutTheUser = [
      "Ich heiße Anna und wohne in Berlin.", "Mein Sohn ist 8.", "Sono vegetariana, consigliami una cena.",
      "Mi figlia ha sei anni.", "Yo trabajo como enfermera.", "Recuerda que mi código es 4521.",
      "Eu moro em Lisboa.", "A minha filha tem 5 anos.", "Ik woon in Utrecht.", "Mijn hond heet Max.",
      "Mam dwoje dzieci.", "Moja córka ma 5 lat.", "私は東京に住んでいます。", "我住在上海。", "저는 서울에 살아요.",
    ]
    for message in aboutTheUser { XCTAssertTrue(HelperTasks.shouldLookForMemories(message), message) }
    let impersonal = [
      "Wie hoch ist der Eiffelturm?", "Qual è la capitale del Canada?", "¿Qué es la fotosíntesis?",
      "Quanto custa um bilhete de comboio?", "Hoe laat is het in Tokio?", "Jaka jest stolica Francji?",
      "東京の人口は？", "上海的天气怎么样？", "서울의 인구는?",
    ]
    for message in impersonal { XCTAssertFalse(HelperTasks.shouldLookForMemories(message), message) }
  }

  func testParseCleansFacts() {
    let json = Data(#"{"memories":["  Is vegetarian. ", "", "x", "- Lives in Montreal", "-5 °C is the coldest they'll run in"]}"#.utf8)
    XCTAssertEqual(
      HelperTasks.parseMemories(json), ["Is vegetarian", "Lives in Montreal", "-5 °C is the coldest they'll run in"])
    XCTAssertEqual(HelperTasks.parseMemories(Data("not json".utf8)), [])
  }

  func testDuplicatesAreSkipped() {
    let kept = HelperTasks.newMemories(
      ["is Vegetarian", "Has a dog named Rex", "Has a dog named Rex", "Works as a nurse"],
      existing: ["Is vegetarian", "Works as a nurse in Montreal"])
    XCTAssertEqual(kept, ["Has a dog named Rex"])
  }

  /// Two-letter words count: a new city isn't taken for a vaguer copy of the old one (2026-11-16).
  func testShortWordsKeepAFactApart() {
    XCTAssertEqual(HelperTasks.newMemories(["Lives in NY"], existing: ["Lives in Montreal"]), ["Lives in NY"])
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
    await appState.runPendingHelpers()
    XCTAssertEqual(memories.map(\.text), ["Is vegetarian"])
    XCTAssertEqual(memories.first?.sourceThreadID, thread.id)
    let reply = try XCTUnwrap(thread.orderedTurns.last)
    XCTAssertEqual(reply.parts.toolActivity.last?.name, "memory")

    await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: appState.newThread(in: context))
    let prompt = await mock.systemPrompt
    XCTAssertTrue(prompt.contains("- Is vegetarian"), prompt)
  }

  /// With more memories than a chat holds, it gets the most recent and those closest in meaning
  /// to its first message: an old one that bears on the chat makes it in, and stays out of others.
  func testManyMemoriesAreChosenByMeaning() async throws {
    appState.memoryEnabled = true
    let peanut = MemoryItem(text: "Is allergic to peanut butter")
    peanut.updatedAt = Date(timeIntervalSinceNow: -100_000)
    context.insert(peanut)
    for index in 0..<40 {
      let item = MemoryItem(text: "Collects stamps from country number \(index)")
      item.updatedAt = Date(timeIntervalSinceNow: -Double(index) * 60)
      context.insert(item)
    }
    try context.save()
    func remembered(_ prompt: String) -> [String] {
      prompt.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
    }
    await appState.send(
      text: "Can I bake peanut butter cookies for the party?", imageData: nil, audioFileURL: nil,
      in: appState.newThread(in: context))
    var prompt = await mock.systemPrompt
    XCTAssertTrue(prompt.contains("- Is allergic to peanut butter"), prompt)
    XCTAssertEqual(remembered(prompt).count, SystemPrompt.memoryLimit)
    XCTAssertTrue(prompt.contains("- Collects stamps from country number 0\n"), "the most recent are kept")

    await appState.send(
      text: "Recommend a good album for my collection", imageData: nil, audioFileURL: nil,
      in: appState.newThread(in: context))
    prompt = await mock.systemPrompt
    XCTAssertFalse(prompt.contains("peanut"), prompt)
    XCTAssertEqual(remembered(prompt).count, SystemPrompt.memoryLimit)
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
    await appState.runPendingHelpers()
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
