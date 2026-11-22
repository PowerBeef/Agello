import XCTest

@testable import Agello

final class NeuralTurnDetectorTests: XCTestCase {
  private func feed(
    _ detector: inout NeuralTurnDetector,
    level: Float,
    seconds: Double,
    speaking: Bool = false
  ) -> [VoiceActivityDetector.Event] {
    var events: [VoiceActivityDetector.Event] = []
    let steps = Int((seconds / 0.05).rounded())
    for _ in 0..<steps {
      if let event = detector.feedLevel(level, duration: 0.05, assistantSpeaking: speaking) {
        events.append(event)
      }
    }
    return events
  }

  func testInactiveNeuralMatchesClassicAcousticTiming() {
    var detector = NeuralTurnDetector()
    XCTAssertFalse(detector.neuralActive)
    XCTAssertEqual(feed(&detector, level: -55, seconds: 1.0), [])
    XCTAssertEqual(feed(&detector, level: -25, seconds: 0.6), [.speechStarted])
    // Still active at 0.50 s silence (below classic 0.80 s threshold).
    XCTAssertEqual(feed(&detector, level: -55, seconds: 0.50), [])
    XCTAssertEqual(feed(&detector, level: -55, seconds: 0.40), [.speechEnded])
  }

  func testFinalizedTranscriptEndpointsFasterThanAcousticVAD() {
    var detector = NeuralTurnDetector()
    detector.setNeuralActive(true)
    _ = feed(&detector, level: -55, seconds: 1.0)
    XCTAssertEqual(feed(&detector, level: -25, seconds: 0.6), [.speechStarted])
    XCTAssertNil(detector.feedTranscript("What is the weather today", isFinal: true))
    // Ends right after completedEndAfter (~0.42 s), well before acoustic 0.80 s.
    XCTAssertEqual(feed(&detector, level: -55, seconds: 0.45), [.speechEnded])
  }

  func testTerminalPunctuationEndpointsFastEvenWhileVolatile() {
    var detector = NeuralTurnDetector()
    detector.setNeuralActive(true)
    _ = feed(&detector, level: -55, seconds: 1.0)
    XCTAssertEqual(feed(&detector, level: -25, seconds: 0.6), [.speechStarted])
    XCTAssertNil(detector.feedTranscript("How tall is Mount Everest?", isFinal: false))
    XCTAssertEqual(feed(&detector, level: -55, seconds: 0.45), [.speechEnded])
  }

  func testMidThoughtPauseHoldsPastAcousticThreshold() {
    var detector = NeuralTurnDetector()
    detector.setNeuralActive(true)
    _ = feed(&detector, level: -55, seconds: 1.0)
    XCTAssertEqual(feed(&detector, level: -25, seconds: 0.6), [.speechStarted])
    // Volatile words right before a thinking pause (no punctuation, not finalized).
    XCTAssertNil(detector.feedTranscript("Can you tell me about", isFinal: false))
    // 0.85 s silence exceeds classic 0.80 s acoustic VAD, but neural hold keeps turn open!
    XCTAssertEqual(feed(&detector, level: -55, seconds: 0.85), [])
    XCTAssertTrue(detector.speaking)
    // User resumes speaking and finishes the sentence.
    XCTAssertEqual(feed(&detector, level: -25, seconds: 0.4), [])
    XCTAssertNil(detector.feedTranscript("Can you tell me about Tokyo.", isFinal: true))
    XCTAssertEqual(feed(&detector, level: -55, seconds: 0.45), [.speechEnded])
  }

  func testMidThoughtPauseStillEndsAtUpperBound() {
    var detector = NeuralTurnDetector()
    detector.setNeuralActive(true)
    _ = feed(&detector, level: -55, seconds: 1.0)
    XCTAssertEqual(feed(&detector, level: -25, seconds: 0.6), [.speechStarted])
    XCTAssertNil(detector.feedTranscript("Never mind", isFinal: false))
    // Exceeds midThoughtEndAfter (1.05 s): ends cleanly instead of hanging.
    XCTAssertEqual(feed(&detector, level: -55, seconds: 1.15), [.speechEnded])
  }

  func testMultiSentenceSpeechDoesNotCutOffBetweenSentences() {
    var detector = NeuralTurnDetector()
    detector.setNeuralActive(true)
    _ = feed(&detector, level: -55, seconds: 1.0)
    XCTAssertEqual(feed(&detector, level: -25, seconds: 0.5), [.speechStarted])
    // Sentence 1 finalizes, but user only pauses 0.15 s before sentence 2.
    XCTAssertNil(detector.feedTranscript("Wait a second.", isFinal: true))
    XCTAssertEqual(feed(&detector, level: -55, seconds: 0.15), [])
    XCTAssertEqual(feed(&detector, level: -25, seconds: 0.5), [])
    XCTAssertNil(detector.feedTranscript("Wait a second. What's the capital of Peru?", isFinal: false))
    XCTAssertEqual(feed(&detector, level: -55, seconds: 0.45), [.speechEnded])
  }

  func testUnrecognizedLanguageStillEndpointsAcoustically() {
    var detector = NeuralTurnDetector()
    detector.setNeuralActive(true)
    _ = feed(&detector, level: -55, seconds: 1.0)
    XCTAssertEqual(feed(&detector, level: -25, seconds: 0.8), [.speechStarted])
    // Zero neural transcripts emitted (e.g. user spoke Japanese while ANE locale is English).
    XCTAssertEqual(feed(&detector, level: -55, seconds: 0.85), [.speechEnded])
  }

  func testNeuralBargeInTriggersDuringAssistantSpeech() {
    var detector = NeuralTurnDetector()
    detector.setNeuralActive(true)
    _ = feed(&detector, level: -55, seconds: 1.0)
    // Echo/soft user voice below acoustic barge-in margin doesn't trigger acoustically.
    XCTAssertEqual(feed(&detector, level: -38, seconds: 0.5, speaking: true), [])
    // Single stray word does not barge in.
    XCTAssertNil(detector.feedTranscript("Stop", isFinal: false, assistantSpeaking: true))
    // Two recognized words confirm human barge-in!
    XCTAssertEqual(
      detector.feedTranscript("Stop right there", isFinal: false, assistantSpeaking: true),
      .speechStarted
    )
    XCTAssertTrue(detector.speaking)
  }
}
