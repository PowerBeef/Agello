import AVFoundation
import NaturalLanguage
import Observation

/// Reads replies aloud with the system speech synthesizer, in the reply's
/// detected language. One reply at a time; tapping again stops.
@MainActor
@Observable
final class SpeechReader: NSObject, AVSpeechSynthesizerDelegate {
  /// The turn being read, if any.
  private(set) var speakingID: UUID?
  @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  func toggle(_ text: String, id: UUID) {
    if speakingID == id {
      stop()
      return
    }
    stop()
    let spoken = MarkdownDocument(parsing: text).plainText
    guard !spoken.isEmpty else { return }
    AudioSessionControl.activateForSpeech()
    let utterance = AVSpeechUtterance(string: spoken)
    utterance.voice = VoiceText.voice(for: NLLanguageRecognizer.dominantLanguage(for: spoken)?.rawValue)
    speakingID = id
    synthesizer.speak(utterance)
  }

  func stop() {
    guard speakingID != nil else { return }
    synthesizer.stopSpeaking(at: .immediate)
    finished()
  }

  private func finished() {
    speakingID = nil
    AudioSessionControl.deactivate(resumingOthers: true)
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in
      if !self.synthesizer.isSpeaking { self.finished() }
    }
  }
}
