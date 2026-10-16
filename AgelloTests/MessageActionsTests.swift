import SwiftData
import XCTest

@testable import Agello

/// Regenerate, edit and version switching: branches persist correctly and
/// the engine is rebuilt from the right point in the conversation.
@MainActor
final class MessageActionsTests: XCTestCase {
  private var container: ModelContainer!
  private var appState: AppState!
  private var mock: MockChatEngine { appState.engine as! MockChatEngine }
  private var context: ModelContext { container.mainContext }
  private var savedSelection: Any?

  override func setUp() async throws {
    savedSelection = UserDefaults.standard.object(forKey: "selectedThreadID")
    container = try ModelContainer(
      for: ChatStore.schema,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    appState = AppState(useMockEngine: true)
    appState.modelContext = container.mainContext
  }

  override func tearDown() async throws {
    appState = nil
    container = nil
    UserDefaults.standard.set(savedSelection, forKey: "selectedThreadID")
  }

  /// Two exchanges: "One" → "A1", "Two" → "A2".
  private func twoExchanges() async -> ChatThread {
    let thread = appState.newThread(in: context)
    await mock.setScript("A1")
    await appState.send(text: "One", imageData: nil, audioFileURL: nil, in: thread)
    await mock.setScript("A2")
    await appState.send(text: "Two", imageData: nil, audioFileURL: nil, in: thread)
    return thread
  }

  func testRegenerateAddsAVersionAndRewindsTheEngine() async throws {
    let thread = await twoExchanges()
    let last = try XCTUnwrap(thread.orderedTurns.last)
    await mock.setScript("A2 again")

    let accepted = await appState.regenerate(last, in: thread)
    XCTAssertTrue(accepted)
    XCTAssertEqual(thread.orderedTurns.map(\.text), ["One", "A1", "Two", "A2 again"])
    // The engine was rebuilt without the old reply or its prompt...
    let reseeds = await mock.reseedLog
    XCTAssertEqual(reseeds.last, ["One", "A1"])
    // ...and asked the same prompt again.
    let sent = await mock.sendLog
    XCTAssertEqual(sent.last, "Two")
    // Both replies are versions of each other.
    let newReply = try XCTUnwrap(thread.orderedTurns.last)
    XCTAssertEqual(thread.siblings(of: newReply).map(\.text), ["A2", "A2 again"])
  }

  /// Regenerate samples (a conversation with MTP off and a seed of its own), so it can answer
  /// differently; each try gets a new seed, and the next message goes back to the usual
  /// conversation.
  func testRegenerateSamplesWithAFreshSeedEachTime() async throws {
    let thread = await twoExchanges()
    await appState.regenerate(try XCTUnwrap(thread.orderedTurns.last), in: thread)
    await appState.regenerate(try XCTUnwrap(thread.orderedTurns.last), in: thread)
    let seeds = await mock.samplingSeeds
    XCTAssertEqual(seeds.count, 2)
    XCTAssertNotEqual(seeds.first, seeds.last, "Each try needs its own seed")
    XCTAssertFalse(seeds.contains(0), "Seed 0 repeats the first reply")
    // The next message rebuilds the usual (greedy, MTP) conversation with the chat's history.
    let reseedsBefore = await mock.reseedLog.count
    await appState.send(text: "Three", imageData: nil, audioFileURL: nil, in: thread)
    let reseeds = await mock.reseedLog
    XCTAssertEqual(reseeds.count, reseedsBefore + 1)
    let seedsAfter = await mock.samplingSeeds.count
    XCTAssertEqual(seedsAfter, 2, "An ordinary message doesn't sample")
  }

  func testEditCreatesANewBranchAndKeepsTheOriginal() async throws {
    let thread = await twoExchanges()
    let first = try XCTUnwrap(thread.orderedTurns.first)
    await mock.setScript("B1")

    let accepted = await appState.edit(first, text: "Uno", in: thread)
    XCTAssertTrue(accepted)
    XCTAssertEqual(thread.orderedTurns.map(\.text), ["Uno", "B1"])
    let reseeds = await mock.reseedLog
    XCTAssertEqual(reseeds.last, [], "Editing the first message starts from an empty context")

    // Switching back to the original shows the whole original conversation.
    appState.selectVersion(first, in: thread)
    XCTAssertEqual(thread.orderedTurns.map(\.text), ["One", "A1", "Two", "A2"])
  }

  func testSwitchingVersionsRebuildsContextOnNextSend() async throws {
    let thread = await twoExchanges()
    let original = try XCTUnwrap(thread.orderedTurns.last)
    await mock.setScript("A2b")
    await appState.regenerate(original, in: thread)
    // The engine now holds the "A2b" branch; switch back to "A2".
    appState.selectVersion(original, in: thread)
    XCTAssertEqual(thread.orderedTurns.last?.text, "A2")

    await mock.setScript("A3")
    await appState.send(text: "Three", imageData: nil, audioFileURL: nil, in: thread)
    let reseeds = await mock.reseedLog
    XCTAssertEqual(reseeds.last, ["One", "A1", "Two", "A2"])
    XCTAssertEqual(thread.orderedTurns.map(\.text), ["One", "A1", "Two", "A2", "Three", "A3"])
  }

  func testVoiceOnlyRepliesCannotBeRegenerated() async throws {
    let thread = appState.newThread(in: context)
    let voice = FileManager.default.temporaryDirectory.appendingPathComponent("voice.wav")
    await appState.send(text: "", imageData: nil, audioFileURL: voice, in: thread)
    let reply = try XCTUnwrap(thread.orderedTurns.last)
    XCTAssertFalse(appState.canRegenerate(reply, in: thread))
    let accepted = await appState.regenerate(reply, in: thread)
    XCTAssertFalse(accepted)
  }

  func testEditKeepsTheImage() async throws {
    let thread = appState.newThread(in: context)
    let image = Data([0xFF, 0xD8, 0xFF])
    await appState.send(text: "What is this?", imageData: image, audioFileURL: nil, in: thread)
    let first = try XCTUnwrap(thread.orderedTurns.first)
    await appState.edit(first, text: "Describe it", in: thread)
    XCTAssertEqual(thread.orderedTurns.first?.text, "Describe it")
    XCTAssertEqual(thread.orderedTurns.first?.imageData, image)
  }
}

extension MessageActionsTests {
  func testEmptyChatsArePrunedExceptTheOpenOne() async {
    let kept = appState.newThread(in: context)
    let open = appState.newThread(in: context)
    let used = appState.newThread(in: context)
    await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: used)
    appState.selectedThreadID = open.id
    appState.pruneEmptyThreads()
    let ids = Set(((try? context.fetch(FetchDescriptor<ChatThread>())) ?? []).map(\.id))
    XCTAssertEqual(ids, [open.id, used.id])
    _ = kept
  }
}
