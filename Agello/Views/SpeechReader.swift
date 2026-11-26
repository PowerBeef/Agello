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
  @ObservationIgnored private var activeUtterance: AVSpeechUtterance?
  @ObservationIgnored private var activeUtteranceID: ObjectIdentifier?
  @ObservationIgnored private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

  override init() {
    super.init()
    synthesizer.delegate = self
  }

  deinit {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  func toggle(_ text: String, id: UUID) {
    if speakingID == id {
      stop()
      return
    }
    let spoken = MarkdownDocument(parsing: text).plainText
    guard !spoken.isEmpty else {
      stop()
      return
    }
    // Allocate the replacement utterance before releasing `activeUtterance` so their
    // `ObjectIdentifier`s cannot collide when switching directly from Message A to Message B.
    let utterance = AVSpeechUtterance(string: spoken)
    utterance.voice = VoiceText.voice(for: NLLanguageRecognizer.dominantLanguage(for: spoken)?.rawValue)
    let wasSpeaking = speakingID != nil || synthesizer.isSpeaking
    activeUtterance = utterance
    activeUtteranceID = ObjectIdentifier(utterance)
    speakingID = id
    if wasSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
    }
    if observers.isEmpty {
      observers = AudioSessionControl.observeInterruptions(
        began: { [weak self] in Task { @MainActor in self?.stop() } },
        ended: {},
        reset: { [weak self] in Task { @MainActor in self?.stop() } }
      )
    }
    AudioSessionControl.activateForSpeech()
    synthesizer.speak(utterance)
  }

  func stop() {
    guard speakingID != nil || activeUtteranceID != nil || synthesizer.isSpeaking else { return }
    activeUtterance = nil
    activeUtteranceID = nil
    synthesizer.stopSpeaking(at: .immediate)
    finished()
  }

  private func finished() {
    speakingID = nil
    activeUtterance = nil
    activeUtteranceID = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    AudioSessionControl.deactivate(resumingOthers: true)
  }

  private func handleEnded(utteranceID: ObjectIdentifier) {
    guard activeUtteranceID == utteranceID else { return }
    finished()
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor [weak self] in
      self?.handleEnded(utteranceID: id)
    }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    let id = ObjectIdentifier(utterance)
    Task { @MainActor [weak self] in
      self?.handleEnded(utteranceID: id)
    }
  }
}
