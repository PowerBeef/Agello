import XCTest

@testable import Agello

final class VoiceTextTests: XCTestCase {
  func testSplitTranscriptAndAnswer() {
    let reply = "⟦Quelle est la capitale de l'Australie?⟧ Canberra est la capitale."
    let split = VoiceText.split(reply)
    XCTAssertEqual(split.heard, "Quelle est la capitale de l'Australie?")
    XCTAssertEqual(split.answer, "Canberra est la capitale.")
    // Partial transcript: nothing to show or speak yet.
    XCTAssertNil(VoiceText.split("⟦What's a go").heard)
    XCTAssertEqual(VoiceText.split("⟦What's a go").answer, "")
    // No transcript: the whole reply is the answer.
    XCTAssertEqual(VoiceText.split("Sure, here it is.").answer, "Sure, here it is.")
    XCTAssertNil(VoiceText.split("Sure.").heard)
  }

  func testSpeakableText() {
    XCTAssertEqual(
      VoiceText.speakable("**Canberra** is the [capital](https://x.y) [1]. 🇦🇺 See https://a.b"),
      "Canberra is the capital. See")
  }

  func testSentencesStreamAsTheyComplete() {
    var stream = VoiceText.SentenceStream()
    XCTAssertEqual(stream.next(from: "Boil it for six"), [])
    XCTAssertEqual(stream.next(from: "Boil it for six minutes. Then cool"), ["Boil it for six minutes."])
    XCTAssertEqual(stream.next(from: "Boil it for six minutes. Then cool it in 3.5 degree water"), [])
    XCTAssertEqual(
      stream.next(from: "Boil it for six minutes. Then cool it in 3.5 degree water", final: true),
      ["Then cool it in 3.5 degree water"])
    XCTAssertEqual(stream.next(from: "Boil it for six minutes. Then cool it in 3.5 degree water", final: true), [])
  }

  func testQuestionAndExclamationEndSentences() {
    var stream = VoiceText.SentenceStream()
    XCTAssertEqual(stream.next(from: "Sure! How about Sunny? Or "), ["Sure!", "How about Sunny?"])
  }

  /// Chinese and Japanese write no space after a full stop: each sentence is spoken as soon as
  /// it ends, not when the whole reply is done. Hindi and Arabic ends count too.
  func testSentencesEndInOtherScripts() {
    var chinese = VoiceText.SentenceStream()
    XCTAssertEqual(chinese.next(from: "今天天气很好。我们去公园吧"), ["今天天气很好。"])
    var japanese = VoiceText.SentenceStream()
    XCTAssertEqual(japanese.next(from: "はい！東京は晴れです。明日は"), ["はい！", "東京は晴れです。"])
    var hindi = VoiceText.SentenceStream()
    XCTAssertEqual(hindi.next(from: "नमस्ते। आप कैसे हैं"), ["नमस्ते।"])
    var arabic = VoiceText.SentenceStream()
    XCTAssertEqual(arabic.next(from: "كيف حالك؟ أنا بخير"), ["كيف حالك؟"])
  }

  /// The language recognizer says "zh-Hans" and "fr"; voices are named "zh-CN" and "fr-CA".
  func testRecognizedLanguagesFindTheirVoice() {
    let voices = ["en-US", "en-GB", "fr-FR", "fr-CA", "zh-CN", "zh-TW", "ja-JP", "nb-NO"]
    XCTAssertEqual(VoiceText.voiceLanguage(for: "zh-Hans", available: voices), "zh-CN")
    XCTAssertEqual(VoiceText.voiceLanguage(for: "zh-Hant", available: voices), "zh-TW")
    XCTAssertEqual(VoiceText.voiceLanguage(for: "fr", available: voices, preferred: ["fr-CA"]), "fr-CA")
    XCTAssertEqual(VoiceText.voiceLanguage(for: "fr", available: voices, preferred: ["en-US"]), "fr-FR")
    XCTAssertEqual(VoiceText.voiceLanguage(for: "nb", available: voices, preferred: []), "nb-NO")
    XCTAssertEqual(VoiceText.voiceLanguage(for: "ja", available: voices, preferred: []), "ja-JP")
    XCTAssertNil(VoiceText.voiceLanguage(for: "sw", available: voices, preferred: []))
  }

  /// Recordings an earlier run left behind are deleted at launch; other files stay.
  func testLeftoverRecordingsAreRemoved() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Leftovers-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["agello-audio-1.wav", "agello-voice-2.wav", "keep.wav", "agello-audio-3.txt"] {
      try Data([1]).write(to: folder.appendingPathComponent(name))
    }
    AudioRecorder.removeLeftovers(in: folder)
    let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    XCTAssertEqual(left, ["agello-audio-3.txt", "keep.wav"])
  }

  func testVoiceInstructionStaysOutOfTheSystemPrompt() {
    XCTAssertFalse(
      SystemPrompt.compose(base: "Base.", personalization: Personalization(), project: nil)
        .contains("⟦"))
  }
}

final class VoiceActivityTests: XCTestCase {
  /// Feed `seconds` of `level` dBFS in 50 ms steps; returns the events.
  private func feed(
    _ vad: inout VoiceActivityDetector, _ level: Float, _ seconds: Double, speaking: Bool = false
  ) -> [VoiceActivityDetector.Event] {
    var events: [VoiceActivityDetector.Event] = []
    for _ in 0..<Int(seconds / 0.05) {
      if let event = vad.feed(level: level, duration: 0.05, assistantSpeaking: speaking) {
        events.append(event)
      }
    }
    return events
  }

  func testUtteranceStartsAndEnds() {
    var vad = VoiceActivityDetector()
    XCTAssertEqual(feed(&vad, -55, 1.0), [], "Room noise")
    XCTAssertEqual(feed(&vad, -25, 1.5), [.speechStarted])
    XCTAssertEqual(feed(&vad, -55, 0.5), [], "Short pause between words")
    XCTAssertEqual(feed(&vad, -25, 0.5), [])
    XCTAssertEqual(feed(&vad, -55, 1.0), [.speechEnded])
  }

  func testCoughsAndClicksAreIgnored() {
    var vad = VoiceActivityDetector()
    _ = feed(&vad, -55, 1.0)
    XCTAssertEqual(feed(&vad, -20, 0.1), [], "Too short to start")
    _ = feed(&vad, -55, 0.5)
    XCTAssertEqual(feed(&vad, -20, 0.25), [.speechStarted])
    XCTAssertEqual(feed(&vad, -55, 1.0), [], "Too short to count as an utterance")
  }

  func testNoisyRoomRaisesTheThreshold() {
    var vad = VoiceActivityDetector()
    XCTAssertEqual(feed(&vad, -35, 6.0), [], "Steady noise adapts the floor")
    XCTAssertGreaterThan(vad.noiseFloor, -40)
    XCTAssertEqual(feed(&vad, -15, 0.5), [.speechStarted])
  }

  func testBargeInNeedsToBeLouderThanEcho() {
    var vad = VoiceActivityDetector()
    _ = feed(&vad, -55, 1.0)
    XCTAssertEqual(feed(&vad, -38, 1.0, speaking: true), [], "Echo leaking past cancellation")
    XCTAssertEqual(feed(&vad, -22, 0.5, speaking: true), [.speechStarted])
  }
}

import SwiftData

@MainActor
final class VoiceTurnFlowTests: XCTestCase {
  func testVoiceTurnSplitsTranscriptAndStreamsTheAnswer() async throws {
    let saved = UserDefaults.standard.object(forKey: "selectedThreadID")
    defer { UserDefaults.standard.set(saved, forKey: "selectedThreadID") }
    let container = try ModelContainer(
      for: ChatStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let appState = AppState(useMockEngine: true)
    appState.modelContext = container.mainContext
    let mock = appState.engine as! MockChatEngine
    await mock.setScript("⟦What time is it?⟧ It's noon. Have a nice lunch.")
    await mock.setHelperResponse(#"{"title":"Lunch time"}"#)

    var updates: [(String, Bool)] = []
    appState.voiceModeActive = true
    appState.onVoiceReply = { updates.append(($0, $1)) }
    let thread = appState.newThread(in: container.mainContext)
    let accepted = await appState.sendVoiceTurn(
      audioFileURL: URL(filePath: "/tmp/turn.wav"), imageData: nil, in: thread)
    XCTAssertTrue(accepted)

    let turns = thread.orderedTurns
    XCTAssertEqual(turns.first?.text, "What time is it?")
    XCTAssertEqual(turns.first?.hasAudio, true)
    XCTAssertEqual(turns.last?.text, "It's noon. Have a nice lunch.")
    XCTAssertEqual(updates.last?.0, "It's noon. Have a nice lunch.")
    XCTAssertEqual(updates.last?.1, true)
    XCTAssertFalse(updates.contains { $0.0.contains("⟦") })
    // Titled from the transcript; the model-written title waits until voice mode closes.
    XCTAssertEqual(thread.title, "What time is it?")
    // The instruction travels with the recording, not in the system prompt.
    let sent = await mock.sendLog
    XCTAssertEqual(sent.last, VoiceText.instruction)
    let prompt = await mock.systemPrompt
    XCTAssertFalse(prompt.contains(VoiceText.instruction))

    // Leaving voice mode doesn't rebuild the conversation for its own sake.
    appState.voiceModeActive = false
    appState.onVoiceReply = nil
    await appState.runPendingHelpers()
    XCTAssertEqual(thread.title, "Lunch time")
    await mock.setScript("Sure.")
    await appState.send(text: "Thanks", imageData: nil, audioFileURL: nil, in: thread)
    let after = await mock.systemPrompt
    XCTAssertFalse(after.contains(VoiceText.instruction))
    // The voice turn replays as text.
    let reseeds = await mock.reseedLog
    XCTAssertEqual(reseeds.last?.first, "What time is it?")
  }
}
