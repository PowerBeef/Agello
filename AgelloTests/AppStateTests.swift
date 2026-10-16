import SwiftData
import UIKit
import UniformTypeIdentifiers
import ImageIO
import XCTest

@testable import Agello

/// Engine-lifecycle and thread ↔ conversation regressions, driven through the
/// scripted mock engine with an in-memory store.
@MainActor
final class AppStateTests: XCTestCase {
  private static let defaultsKeys = [
    "selectedThreadID", "inferenceOptions", "personalization", "memoryEnabled",
    "enableTools", "webSearch",
  ]
  private var savedDefaults: [String: Any] = [:]
  private var container: ModelContainer!
  private var appState: AppState!
  private var mock: MockChatEngine { appState.engine as! MockChatEngine }
  private var context: ModelContext { container.mainContext }

  override func setUp() async throws {
    // Start from default settings, whatever the app saved on the device
    // (restored in tearDown).
    for key in Self.defaultsKeys {
      savedDefaults[key] = UserDefaults.standard.object(forKey: key)
      UserDefaults.standard.removeObject(forKey: key)
    }
    container = try ModelContainer(
      for: ChatStore.schema,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    appState = AppState(useMockEngine: true)
    appState.modelContext = container.mainContext
  }

  override func tearDown() async throws {
    GPUGate.set(true)
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

  /// A stream that fails mid-way leaves the native conversation in an unknown state (the
  /// engine stops it): the next message is answered from a rebuilt conversation.
  func testAStreamErrorRebuildsTheConversationBeforeTheNextSend() async {
    let thread = appState.newThread(in: context)
    await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: thread)
    await mock.failNextSend(afterChunks: 1, with: .underlying(message: "INVALID_ARGUMENT: tool call"))
    await appState.send(text: "Next", imageData: nil, audioFileURL: nil, in: thread)
    await appState.send(text: "Again", imageData: nil, audioFileURL: nil, in: thread)
    let seen = await mock.heldAtSend.last
    XCTAssertEqual(seen, ["Hi", "Hello from the mock engine!", "Next", "Hello"])
    XCTAssertEqual(thread.orderedTurns.last?.text, "Hello from the mock engine!")
  }

  /// A reply whose task is cancelled (voice mode closed) cancels the native conversation,
  /// which then rejects messages until rebuilt: the next message must still be answered.
  func testAnAbandonedReplyIsRebuiltBeforeTheNextSend() async {
    let thread = appState.newThread(in: context)
    await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: thread)
    let state: AppState = appState
    let sending = Task { await state.send(text: "Long one", imageData: nil, audioFileURL: nil, in: thread) }
    while !appState.isGenerating { try? await Task.sleep(for: .milliseconds(5)) }
    sending.cancel()
    _ = await sending.value
    XCTAssertFalse(appState.isGenerating)
    await appState.send(text: "After", imageData: nil, audioFileURL: nil, in: thread)
    XCTAssertEqual(thread.orderedTurns.last?.text, "Hello from the mock engine!")
  }

  /// Stop while the model is still loading: nothing is sent and the draft comes back.
  func testStopWhilePreparingSendsNothing() async {
    await mock.setLoadDelay(.milliseconds(300))
    let thread = appState.newThread(in: context)
    let state: AppState = appState
    let sending = Task { await state.send(text: "Hi", imageData: nil, audioFileURL: nil, in: thread) }
    while !appState.isPreparing { try? await Task.sleep(for: .milliseconds(5)) }
    appState.stop()
    let accepted = await sending.value
    XCTAssertFalse(accepted)
    XCTAssertTrue(thread.orderedTurns.isEmpty)
    let sends = await mock.sendLog
    XCTAssertTrue(sends.isEmpty)
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
    await appState.send(text: "Again", imageData: nil, audioFileURL: nil, in: a)
    let b = appState.newThread(in: context)

    // Opening B must not continue A's native conversation.
    await appState.activate(b)
    let held = await mock.held
    XCTAssertEqual(held, [])

    // Re-opening A restores A's context.
    await appState.activate(a)
    let log = await mock.reseedLog
    XCTAssertEqual(
      log.last, ["Hi", "Hello from the mock engine!", "Again", "Hello from the mock engine!"])
    XCTAssertEqual(appState.selectedThreadID, a.id)
  }

  func testReopeningSameThreadDoesNotReseed() async {
    let thread = appState.newThread(in: context)
    await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: thread)
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
    await appState.runPendingHelpers()
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

  /// Our runtime keeps the chat's conversation across a helper (T3): the next
  /// message continues it without replaying history.
  func testHelperThatKeepsTheConversationNeedsNoRebuild() async {
    await mock.setHelpersKeepConversation(true)
    let thread = appState.newThread(in: context)
    await appState.send(text: "Tell me about lighthouses", imageData: nil, audioFileURL: nil, in: thread)
    await appState.runPendingHelpers()
    XCTAssertEqual(thread.title, "Mock chat")
    let reseedsBefore = await mock.reseedLog.count
    await appState.send(text: "More", imageData: nil, audioFileURL: nil, in: thread)
    let reseedsAfter = await mock.reseedLog.count
    XCTAssertEqual(reseedsAfter, reseedsBefore)
  }

  /// Titles and memories wait for a quiet moment: on Google's runtime each helper empties the
  /// chat's conversation, and running one between messages made the next reply re-read the chat.
  func testHelpersWaitForAQuietMoment() async {
    let thread = appState.newThread(in: context)
    await appState.send(text: "Tell me about lighthouses", imageData: nil, audioFileURL: nil, in: thread)
    var prompts = await mock.helperPrompts
    XCTAssertTrue(prompts.isEmpty)
    XCTAssertTrue(appState.hasPendingHelpers)
    // The next message continues the chat without a rebuild.
    await appState.send(text: "More", imageData: nil, audioFileURL: nil, in: thread)
    let seen = await mock.heldAtSend.last
    XCTAssertEqual(seen, ["Tell me about lighthouses", "Hello from the mock engine!"])
    await appState.runPendingHelpers()
    prompts = await mock.helperPrompts
    XCTAssertEqual(prompts.count, 1)
    XCTAssertEqual(thread.title, "Mock chat")
    XCTAssertFalse(appState.hasPendingHelpers)
  }

  /// A message sent while a helper runs is prepared after it, as one step: the helper can't
  /// empty the conversation between the message's preparation and its context check.
  func testAMessageSentDuringAHelperKeepsItsHistory() async {
    appState.memoryEnabled = true
    let thread = appState.newThread(in: context)
    await appState.send(text: "I like tea. Suggest a snack.", imageData: nil, audioFileURL: nil, in: thread)
    await mock.holdNextHelper()
    let state: AppState = appState
    let helpers = Task { await state.runPendingHelpers() }
    while await !mock.helperWaiting { try? await Task.sleep(for: .milliseconds(5)) }
    let second = Task { await state.send(text: "And a drink?", imageData: nil, audioFileURL: nil, in: thread) }
    while !appState.isPreparing { try? await Task.sleep(for: .milliseconds(5)) }
    await mock.releaseHelper()
    await helpers.value
    _ = await second.value
    let seen = await mock.heldAtSend.last
    XCTAssertEqual(seen, ["I like tea. Suggest a snack.", "Hello from the mock engine!"])
    XCTAssertEqual(thread.orderedTurns.last?.text, "Hello from the mock engine!")
    // The title helper didn't run during the send: it's still waiting.
    XCTAssertTrue(appState.hasPendingHelpers)
    await appState.runPendingHelpers()
    XCTAssertEqual(thread.title, "Mock chat")
  }

  /// No GPU work in the background: a running helper is stopped, and it runs again on return.
  func testBackgroundStopsAHelperThatRunsAgainLater() async {
    let thread = appState.newThread(in: context)
    await appState.send(text: "Tell me about lighthouses", imageData: nil, audioFileURL: nil, in: thread)
    await mock.holdNextHelper()
    let state: AppState = appState
    let helpers = Task { await state.runPendingHelpers() }
    while await !mock.helperWaiting { try? await Task.sleep(for: .milliseconds(5)) }
    appState.enterBackground()
    XCTAssertFalse(GPUGate.isOpen)
    try? await Task.sleep(for: .milliseconds(50))  // the cancel reaches the engine
    await mock.releaseHelper()
    await helpers.value
    XCTAssertEqual(thread.title, "Tell me about lighthouses")
    XCTAssertTrue(appState.hasPendingHelpers)
    appState.enterForeground()
    XCTAssertTrue(GPUGate.isOpen)
    await appState.runPendingHelpers()
    XCTAssertEqual(thread.title, "Mock chat")
  }

  func testUserRenamedChatKeepsItsTitle() async {
    let thread = appState.newThread(in: context)
    thread.title = "My trip"
    await appState.send(text: "Plan a day in Kyoto", imageData: nil, audioFileURL: nil, in: thread)
    await appState.runPendingHelpers()
    XCTAssertEqual(thread.title, "My trip")
  }

  func testUnusableHelperOutputKeepsProvisionalTitle() async {
    await mock.setHelperResponse(#"{"title":"   "}"#)
    let thread = appState.newThread(in: context)
    await appState.send(text: "Hi there", imageData: nil, audioFileURL: nil, in: thread)
    await appState.runPendingHelpers()
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

  /// Read with ImageIO at the target size (never decoded in full), with the photo's EXIF
  /// orientation applied: a phone photo stored landscape with orientation 6 comes out portrait.
  func testImagePreparerAppliesOrientationWithoutAFullDecode() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let landscape = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: format)
      .image { context in
        UIColor.red.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000))
      }
    let output = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(
      destination, try XCTUnwrap(landscape.cgImage),
      [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 0.8]
        as [CFString: Any] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let prepared = try XCTUnwrap(ImagePreparer.prepare(output as Data))
    let image = try XCTUnwrap(UIImage(data: prepared))
    XCTAssertEqual(image.size.width * image.scale, 1176)
    XCTAssertEqual(image.size.height * image.scale, 1568)
  }

  // MARK: - Attachment-only messages (audit #12)

  func testVoiceOnlyMessageIsLabelledAndTitled() async {
    let thread = appState.newThread(in: context)
    let voice = FileManager.default.temporaryDirectory.appendingPathComponent("voice.wav")
    let accepted = await appState.send(text: "", imageData: nil, audioFileURL: voice, in: thread)
    XCTAssertTrue(accepted)
    XCTAssertEqual(thread.orderedTurns.first?.hasAudio, true)
    await appState.runPendingHelpers()
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

// MARK: - Long contexts (LiteRT-LM #3913, fixed in the model file)

extension AppStateTests {
  /// The patched model is exact at every position with 16-bit activations,
  /// so a long chat keeps the engine it has: no precision switch, no rebuild.
  func testLongChatsKeepTheEngine() async {
    await appState.ensureEngineLoaded()
    let before = appState.resolved
    let long = appState.newThread(in: context)
    let essay = String(repeating: "A long paragraph about lighthouses and their keepers. ", count: 180)
    await appState.send(text: essay, imageData: nil, audioFileURL: nil, in: long)
    XCTAssertEqual(appState.resolved, before)
    XCTAssertEqual(appState.resolved?.backendLabel, "GPU")
  }
}
