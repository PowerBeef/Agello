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

  func testVoiceInstructionJoinsTheSystemPrompt() {
    let prompt = SystemPrompt.compose(
      base: "Base.", personalization: Personalization(), project: nil, voice: true)
    XCTAssertTrue(prompt.hasSuffix(VoiceText.instruction))
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
    XCTAssertEqual(thread.title, "Lunch time", "Titled from the transcript")
    let prompt = await mock.systemPrompt
    XCTAssertTrue(prompt.contains(VoiceText.instruction))

    // Leaving voice mode removes the instruction before the next message.
    appState.voiceModeActive = false
    appState.onVoiceReply = nil
    await mock.setScript("Sure.")
    await appState.send(text: "Thanks", imageData: nil, audioFileURL: nil, in: thread)
    let after = await mock.systemPrompt
    XCTAssertFalse(after.contains(VoiceText.instruction))
    // The voice turn replays as text.
    let reseeds = await mock.reseedLog
    XCTAssertEqual(reseeds.last?.first, "What time is it?")
  }
}
