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

  func testSelectBackendPrefersSpeechTranscriberForPrimaryLocale() {
    XCTAssertEqual(
      Dictation.selectBackend(
        preferredLanguages: ["fr-CA", "en-US"],
        installedSpeechTranscriber: ["fr_FR", "fr_CA"],
        installedDictationTranscriber: ["fr_CA", "en_US"]),
      .speechTranscriber(localeIdentifier: "fr_CA")
    )
    XCTAssertEqual(
      Dictation.selectBackend(
        preferredLanguages: ["fr-CA"],
        installedSpeechTranscriber: ["fr_FR"],
        installedDictationTranscriber: ["en_US"]),
      .speechTranscriber(localeIdentifier: "fr_FR")
    )
  }

  func testSelectBackendUsesDictationTranscriberInsteadOfWrongLanguage() {
    // Primary language is English, SpeechTranscriber only has French, DictationTranscriber has English.
    XCTAssertEqual(
      Dictation.selectBackend(
        preferredLanguages: ["en-US", "fr-CA"],
        installedSpeechTranscriber: ["fr_CA", "fr_FR"],
        installedDictationTranscriber: ["fr_CA", "en_US"]),
      .dictationTranscriber(localeIdentifier: "en_US")
    )
  }

  func testSelectBackendFallsBackToGemmaWhenPrimaryLocaleMissing() {
    XCTAssertEqual(
      Dictation.selectBackend(
        preferredLanguages: ["ja-JP", "en-US"],
        installedSpeechTranscriber: ["fr_CA"],
        installedDictationTranscriber: ["en_US"]),
      .gemmaAudio
    )
    XCTAssertEqual(
      Dictation.selectBackend(
        preferredLanguages: [],
        installedSpeechTranscriber: ["en_US"],
        installedDictationTranscriber: ["en_US"]),
      .gemmaAudio
    )
  }

  func testLiveTranscriptStreamsAndCommitsOnTopOfBaseDraft() {
    var live = Dictation.LiveTranscript(base: "Please summarize:")
    live.apply(text: "the", isFinal: false)
    XCTAssertEqual(live.composedDraft, "Please summarize: the")
    live.apply(text: "the quarterly report.", isFinal: true)
    XCTAssertEqual(live.composedDraft, "Please summarize: the quarterly report.")
    XCTAssertEqual(live.volatile, "")

    live.apply(text: "Keep it brief", isFinal: false)
    XCTAssertEqual(live.composedDraft, "Please summarize: the quarterly report. Keep it brief")
    let committed = live.commitVolatile()
    XCTAssertEqual(committed, "Please summarize: the quarterly report. Keep it brief")
    XCTAssertEqual(live.volatile, "")
    XCTAssertEqual(live.finalized, "the quarterly report. Keep it brief")

    // Punctuation-leading final segments attach without stray spaces.
    live.apply(text: "!", isFinal: true)
    XCTAssertEqual(live.composedDraft, "Please summarize: the quarterly report. Keep it brief!")
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
