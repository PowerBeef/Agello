import SwiftData
import XCTest

@testable import iRTChat

@MainActor
final class ProjectTests: XCTestCase {
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

  private func chat(in project: Project?) -> ChatThread {
    let thread = appState.newThread(in: context)
    thread.projectID = project?.id
    return thread
  }

  func testComposeAddsTheProjectBlockLast() {
    var personalization = Personalization()
    personalization.name = "Sam"
    let prompt = SystemPrompt.compose(
      base: "Base.", personalization: personalization,
      project: ProjectContext(id: UUID(), name: "Travel", instructions: " Prefer trains. "))
    XCTAssertTrue(prompt.hasPrefix("Base."))
    XCTAssertTrue(prompt.contains("The user's name is Sam."))
    XCTAssertTrue(
      prompt.hasSuffix(
        "This chat is part of the project \"Travel\". Follow the project's instructions:\nPrefer trains."))
    XCTAssertEqual(
      SystemPrompt.compose(base: "Base.", personalization: Personalization(), project: nil), "Base.")
  }

  func testSystemPromptFollowsTheChatsProject() async {
    let travel = appState.newProject(named: "Travel", in: context)
    travel.instructions = "Prefer trains."
    let inProject = chat(in: travel)
    await appState.send(text: "Plan Kyoto", imageData: nil, audioFileURL: nil, in: inProject)
    var prompt = await mock.systemPrompt
    XCTAssertTrue(prompt.contains("Prefer trains."), prompt)

    let plain = chat(in: nil)
    await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: plain)
    prompt = await mock.systemPrompt
    XCTAssertFalse(prompt.contains("Travel"), prompt)

    // Back in the project chat: instructions again, with its history.
    await appState.send(text: "And Osaka?", imageData: nil, audioFileURL: nil, in: inProject)
    prompt = await mock.systemPrompt
    XCTAssertTrue(prompt.contains("Prefer trains."), prompt)
    let reseeds = await mock.reseedLog
    XCTAssertEqual(reseeds.last?.first, "Plan Kyoto")
  }

  func testEditedInstructionsApplyToTheNextMessage() async {
    let project = appState.newProject(named: "Work", in: context)
    project.instructions = "Be formal."
    let thread = chat(in: project)
    await appState.send(text: "Draft an email", imageData: nil, audioFileURL: nil, in: thread)
    project.instructions = "Be casual."
    appState.projectInstructionsChanged(project.id)
    await appState.send(text: "Shorter", imageData: nil, audioFileURL: nil, in: thread)
    let prompt = await mock.systemPrompt
    XCTAssertTrue(prompt.contains("Be casual."), prompt)
    XCTAssertFalse(prompt.contains("Be formal."), prompt)
  }

  func testProjectFilesReachItsChats() async throws {
    let project = appState.newProject(named: "Hike", in: context)
    appState.knowledge.add(
      ExtractedDocument(name: "gear.md", kind: .text, byteCount: 10, pages: ["Pack a headlamp."]),
      projectID: project.id)
    let thread = chat(in: project)
    await appState.send(text: "What should I pack?", imageData: nil, audioFileURL: nil, in: thread)
    let log = await mock.sendLog
    XCTAssertTrue(log.last?.contains("Pack a headlamp.") ?? false)
    // Not in chats outside the project.
    let other = chat(in: nil)
    await appState.send(text: "What should I pack?", imageData: nil, audioFileURL: nil, in: other)
    let after = await mock.sendLog
    XCTAssertEqual(after.last, "What should I pack?")
  }

  func testDeletingAProjectRemovesItsChatsAndFiles() async throws {
    let project = appState.newProject(named: "Old", in: context)
    let thread = chat(in: project)
    await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: thread)
    appState.knowledge.add(
      ExtractedDocument(name: "a.md", kind: .text, byteCount: 1, pages: ["x"]), projectID: project.id)
    let keep = chat(in: nil)
    await appState.send(text: "Keep me", imageData: nil, audioFileURL: nil, in: keep)

    appState.deleteProject(project, in: context)
    XCTAssertEqual(try context.fetch(FetchDescriptor<Project>()).count, 0)
    XCTAssertEqual(try context.fetch(FetchDescriptor<ChatThread>()).map(\.id), [keep.id])
    XCTAssertEqual(try context.fetch(FetchDescriptor<ChatDocument>()).count, 0)
  }

  func testMovingAChatRebuildsItsContextWithTheProject() async {
    let project = appState.newProject(named: "Garden", in: context)
    project.instructions = "Organic only."
    let thread = chat(in: nil)
    await appState.send(text: "Tomatoes?", imageData: nil, audioFileURL: nil, in: thread)
    appState.move(thread, toProject: project.id)
    await appState.send(text: "Fertilizer?", imageData: nil, audioFileURL: nil, in: thread)
    let prompt = await mock.systemPrompt
    XCTAssertTrue(prompt.contains("Organic only."), prompt)
  }
}
