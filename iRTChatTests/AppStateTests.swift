import SwiftData
import UIKit
import XCTest

@testable import iRTChat

/// Engine-lifecycle and thread ↔ conversation regressions, driven through the
/// scripted mock engine with an in-memory store.
@MainActor
final class AppStateTests: XCTestCase {
  private static let defaultsKeys = ["selectedThreadID", "inferenceOptions", "personalization"]
  private var savedDefaults: [String: Any] = [:]
  private var container: ModelContainer!
  private var appState: AppState!
  private var mock: MockChatEngine { appState.engine as! MockChatEngine }
  private var context: ModelContext { container.mainContext }

  override func setUp() async throws {
    for key in Self.defaultsKeys {
      savedDefaults[key] = UserDefaults.standard.object(forKey: key)
    }
    container = try ModelContainer(
      for: ChatStore.schema,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    appState = AppState(useMockEngine: true)
    appState.modelContext = container.mainContext
  }

  override func tearDown() async throws {
    appState = nil
    container = nil
    for key in Self.defaultsKeys {
      if let value = savedDefaults[key] {
        UserDefaults.standard.set(value, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
  }

  func testMockModeSendsWithoutDownloadedModel() async {
    let thread = appState.newThread(in: context)
    let accepted = await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: thread)
    XCTAssertTrue(accepted)
    XCTAssertEqual(thread.orderedTurns.map(\.text), ["Hi", "Hello from the mock engine!"])
    XCTAssertEqual(appState.engineState, .ready)
    XCTAssertFalse(appState.isGenerating)
  }

  func testConcurrentLoadsCoalesceIntoOne() async {
    await mock.setLoadDelay(.milliseconds(200))
    let state: AppState = appState
    async let first = state.ensureEngineLoaded()
    async let second = state.ensureEngineLoaded()
    let results = await [first, second]
    XCTAssertEqual(results, [true, true])
    let loads = await mock.loadCount
    XCTAssertEqual(loads, 1)
  }

  func testSwitchingThreadsReplaysTheOpenThreadsHistory() async {
    let a = appState.newThread(in: context)
    await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: a)
    // A second message, so the engine holds A's context (the first exchange's
    // title helper leaves it empty).
    await appState.send(text: "Again", imageData: nil, audioFileURL: nil, in: a)
    let b = appState.newThread(in: context)

    // Opening B must not continue A's native conversation.
    await appState.activate(b)
    var log = await mock.reseedLog
    XCTAssertEqual(log.last, [])

    // Re-opening A restores A's context.
    await appState.activate(a)
    log = await mock.reseedLog
    XCTAssertEqual(
      log.last, ["Hi", "Hello from the mock engine!", "Again", "Hello from the mock engine!"])
    XCTAssertEqual(appState.selectedThreadID, a.id)
  }

  func testReopeningSameThreadDoesNotReseed() async {
    let thread = appState.newThread(in: context)
    await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: thread)
    // The title helper replaced the engine's conversation: one rebuild...
    await appState.activate(thread)
    let before = await mock.reseedLog.count
    // ...then reopening the same chat doesn't replay it again.
    await appState.activate(thread)
    await appState.activate(thread)
    let after = await mock.reseedLog.count
    XCTAssertEqual(before, after)
  }

  // MARK: - Titles (helper task)

  func testFirstExchangeGetsAModelWrittenTitleAndContextIsRebuilt() async {
    let thread = appState.newThread(in: context)
    await appState.send(text: "Tell me about lighthouses", imageData: nil, audioFileURL: nil, in: thread)
    XCTAssertEqual(thread.title, "Mock chat")
    let prompts = await mock.helperPrompts
    XCTAssertEqual(prompts.count, 1)
    XCTAssertTrue(prompts.first?.contains("Tell me about lighthouses") ?? false)

    // The helper wiped the engine's conversation, so the next message replays history.
    let reseedsBefore = await mock.reseedLog.count
    await appState.send(text: "More", imageData: nil, audioFileURL: nil, in: thread)
    let log = await mock.reseedLog
    XCTAssertEqual(log.count, reseedsBefore + 1)
    XCTAssertEqual(log.last?.first, "Tell me about lighthouses")
    // Only the first exchange is titled.
    let promptsAfter = await mock.helperPrompts
    XCTAssertEqual(promptsAfter.count, 1)
  }

  func testUserRenamedChatKeepsItsTitle() async {
    let thread = appState.newThread(in: context)
    thread.title = "My trip"
    await appState.send(text: "Plan a day in Kyoto", imageData: nil, audioFileURL: nil, in: thread)
    XCTAssertEqual(thread.title, "My trip")
  }

  func testUnusableHelperOutputKeepsProvisionalTitle() async {
    await mock.setHelperResponse(#"{"title":"   "}"#)
    let thread = appState.newThread(in: context)
    await appState.send(text: "Hi there", imageData: nil, audioFileURL: nil, in: thread)
    XCTAssertEqual(thread.title, "Hi there")
  }

  func testStoppedConversationIsRebuiltBeforeTheNextMessage() async throws {
    let thread = appState.newThread(in: context)
    let state: AppState = appState
    let sending = Task { @MainActor in
      await state.send(text: "Long story", imageData: nil, audioFileURL: nil, in: thread)
    }
    try await Task.sleep(for: .milliseconds(90))  // first chunk streamed
    appState.stop()
    _ = await sending.value
    let partial = thread.orderedTurns.last(where: { !$0.isUser })?.text ?? ""
    XCTAssertFalse(partial.hasPrefix(ChatTurn.errorPrefix), "Stop surfaced as an error")

    let reseedsBefore = await mock.reseedLog.count
    let accepted = await appState.send(
      text: "Continue", imageData: nil, audioFileURL: nil, in: thread)
    XCTAssertTrue(accepted)
    let log = await mock.reseedLog
    XCTAssertEqual(log.count, reseedsBefore + 1, "Cancelled conversation must be rebuilt")
    XCTAssertEqual(log.last?.first, "Long story")
  }

  // MARK: - Context window (audit #15)

  func testTrimmedContextSendsAndShowsNotice() async {
    await mock.setFitResult(.success(true))
    let thread = appState.newThread(in: context)
    let accepted = await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: thread)
    XCTAssertTrue(accepted)
    XCTAssertEqual(thread.turns.count, 2)
    XCTAssertNotNil(appState.generationError, "User should learn older messages were dropped")
  }

  func testMessageTooLongIsRejectedWithoutPersisting() async {
    await mock.setFitResult(.failure(.messageTooLong))
    let thread = appState.newThread(in: context)
    let accepted = await appState.send(
      text: "Very long", imageData: nil, audioFileURL: nil, in: thread)
    XCTAssertFalse(accepted)
    XCTAssertTrue(thread.turns.isEmpty)
    XCTAssertEqual(appState.generationError, ChatError.messageTooLong.displayMessage)
  }

  func testFailedRepliesAreNotReplayedAsHistory() {
    let thread = ChatThread()
    context.insert(thread)
    thread.turns.append(ChatTurn(role: .user, text: "Hi"))
    thread.turns.append(ChatTurn(role: .model, text: ChatTurn.errorPrefix + "boom"))
    thread.turns.append(ChatTurn(role: .user, text: "Again"))
    XCTAssertEqual(thread.textHistory.map(\.text), ["Hi", "Again"])
  }

  /// Audit #13: the 1568 px cap must be pixels, not points × screen scale.
  func testImagePreparerCapsPixels() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let big = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format)
      .image { context in
        UIColor.blue.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
      }
    let prepared = try XCTUnwrap(ImagePreparer.prepare(try XCTUnwrap(big.jpegData(compressionQuality: 0.9))))
    let image = try XCTUnwrap(UIImage(data: prepared))
    XCTAssertEqual(image.size.width * image.scale, 1568)
    XCTAssertEqual(image.size.height * image.scale, 1176)
  }

  // MARK: - Attachment-only messages (audit #12)

  func testVoiceOnlyMessageIsLabelledAndTitled() async {
    let thread = appState.newThread(in: context)
    let voice = FileManager.default.temporaryDirectory.appendingPathComponent("voice.wav")
    let accepted = await appState.send(text: "", imageData: nil, audioFileURL: voice, in: thread)
    XCTAssertTrue(accepted)
    XCTAssertEqual(thread.orderedTurns.first?.hasAudio, true)
    // "Voice message" is the provisional title the model is asked to improve.
    let prompts = await mock.helperPrompts
    XCTAssertTrue(prompts.first?.contains("User: Voice message") ?? false)
    XCTAssertEqual(thread.title, "Mock chat")
  }

  func testTitles() {
    XCTAssertEqual(AppState.title(prompt: "Hello there", hasImage: true), "Hello there")
    XCTAssertEqual(AppState.title(prompt: "", hasImage: true), "Photo")
    XCTAssertEqual(AppState.title(prompt: "", hasImage: false), "Voice message")
    XCTAssertEqual(AppState.title(prompt: String(repeating: "a", count: 100), hasImage: false).count, 42)
  }

  func testOptionChangeDoesNotLoadAnUnloadedModel() async {
    appState.options.samplerPreset = .creative
    await appState.applyCurrentOptions()
    let loads = await mock.loadCount
    XCTAssertEqual(loads, 0)
  }

  // MARK: - Personalization

  func testPersonalizationReachesTheModelsSystemPrompt() async {
    appState.personalization.name = "Patrice"
    await appState.ensureEngineLoaded()
    var prompt = await mock.systemPrompt
    XCTAssertTrue(prompt.contains("The user's name is Patrice."), prompt)
    XCTAssertTrue(prompt.hasPrefix(appState.options.systemPrompt))

    appState.personalization.instructions = "Answer in French."
    await appState.applyCurrentOptions()
    prompt = await mock.systemPrompt
    XCTAssertTrue(prompt.contains("Answer in French."), prompt)
    // Stored separately: the base prompt setting is unchanged.
    XCTAssertFalse(appState.options.systemPrompt.contains("Patrice"))
  }

  func testThinkToggleAppliesToTheVeryNextMessage() async {
    let thread = appState.newThread(in: context)
    await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: thread)
    XCTAssertTrue(thread.orderedTurns.last?.thought.isEmpty ?? false, "Thinking is off by default")
    // As the composer does: toggle, schedule, and send before the debounce fires.
    appState.options.enableThinking = true
    appState.scheduleApplyOptions()
    await appState.send(text: "Again", imageData: nil, audioFileURL: nil, in: thread)
    XCTAssertFalse(thread.orderedTurns.last?.thought.isEmpty ?? true, "Think didn't apply in time")
  }
}
