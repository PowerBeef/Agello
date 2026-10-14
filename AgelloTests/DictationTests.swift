import SwiftData
import XCTest

@testable import Agello

final class DictationTests: XCTestCase {
  func testCleanRemovesLabelsQuotesAndExtraSpace() {
    XCTAssertEqual(Dictation.clean("  Transcript: \"Book a table\n for four.\" "), "Book a table for four.")
    XCTAssertEqual(Dictation.clean("« Bonjour à tous »"), "Bonjour à tous")
    XCTAssertEqual(Dictation.clean("\n\n"), "")
  }

  func testInsertAppendsWithASpace() {
    XCTAssertEqual(Dictation.insert("world", into: "Hello "), "Hello world")
    XCTAssertEqual(Dictation.insert("Hi", into: ""), "Hi")
    XCTAssertEqual(Dictation.insert("", into: "Keep"), "Keep")
  }

  func testWordErrorRate() {
    XCTAssertEqual(Dictation.wordErrorRate(reference: "Book a table for four.", hypothesis: "book a table for four"), 0)
    XCTAssertEqual(
      Dictation.wordErrorRate(reference: "book a table for four", hypothesis: "book the table for"), 0.4,
      accuracy: 0.001)
    XCTAssertEqual(Dictation.wordErrorRate(reference: "Québec", hypothesis: "Quebec"), 0)
  }
}

@MainActor
final class DictationFlowTests: XCTestCase {
  func testTranscribeRebuildsTheConversationAfterwards() async throws {
    let container = try ModelContainer(
      for: ChatStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let appState = AppState(useMockEngine: true)
    appState.modelContext = container.mainContext
    let mock = appState.engine as! MockChatEngine
    let thread = appState.newThread(in: container.mainContext)
    await appState.send(text: "Hi", imageData: nil, audioFileURL: nil, in: thread)
    await appState.send(text: "Again", imageData: nil, audioFileURL: nil, in: thread)

    let text = await appState.transcribe(URL(filePath: "/tmp/voice.wav"))
    XCTAssertEqual(text, "Dictated text.")
    XCTAssertFalse(appState.isTranscribing)
    let reseedsBefore = await mock.reseedLog.count
    await appState.send(text: "More", imageData: nil, audioFileURL: nil, in: thread)
    let log = await mock.reseedLog
    XCTAssertEqual(log.count, reseedsBefore + 1, "The chat must be rebuilt after dictation")
    XCTAssertEqual(log.last?.first, "Hi")
  }
}
