import AVFoundation
import NaturalLanguage
import Observation
import SwiftData

/// Hands-free conversation: listen, detect the end of the user's turn,
/// send the audio (and what the camera sees) to Gemma, speak the answer
/// sentence by sentence; talking over the assistant interrupts it.
@MainActor
@Observable
final class VoiceSession {
  enum State: Equatable {
    case starting, listening, hearing, thinking, speaking
    case failed(String)

    var label: String {
      switch self {
      case .starting: return String(localized: "Starting…")
      case .listening: return String(localized: "Listening")
      case .hearing: return String(localized: "Listening…")
      case .thinking: return String(localized: "Thinking…")
      case .speaking: return String(localized: "Speaking")
      case .failed(let message): return message
      }
    }
  }

  private(set) var state: State = .starting
  /// Microphone or speech level, 0…1, for the orb.
  private(set) var level: Double = 0
  /// What the user said last (their transcript) and the answer so far.
  private(set) var heard = ""
  private(set) var answer = ""
  private(set) var cameraOn = false
  private(set) var muted = false

  let camera = CameraFeed()
  @ObservationIgnored private let audio = VoiceAudio()
  @ObservationIgnored private var vad = VoiceActivityDetector()
  @ObservationIgnored private var sentences = VoiceText.SentenceStream()
  @ObservationIgnored private var replyLanguage: String?
  @ObservationIgnored private var replyFinished = false
  /// The current reply was interrupted: don't speak what's left of it.
  @ObservationIgnored private var silenced = false
  @ObservationIgnored private var turnTask: Task<Void, Never>?
  @ObservationIgnored private var utteranceStarted: Date?
  @ObservationIgnored private let appState: AppState
  @ObservationIgnored private let makeThread: () -> ChatThread
  @ObservationIgnored private var thread: ChatThread?

  /// UI tests can't answer the system microphone prompt on device.
  private static let fakeMic = ProcessInfo.processInfo.arguments.contains("--uitest-fake-mic")
  static let maxUtterance: TimeInterval = 30

  init(appState: AppState, thread: ChatThread?, makeThread: @escaping () -> ChatThread) {
    self.appState = appState
    self.thread = thread
    self.makeThread = makeThread
  }

  // MARK: Session

  func start() async {
    appState.voiceModeActive = true
    appState.onVoiceReply = { [weak self] answer, final in self?.replyUpdated(answer, final: final) }
    if Self.fakeMic {
      state = .listening
      return
    }
    guard await AVAudioApplication.requestRecordPermission() else {
      state = .failed(String(localized: "Microphone access is off. Turn it on in Settings."))
      return
    }
    audio.onLevel = { [weak self] level, duration in
      Task { @MainActor in self?.heardLevel(level, duration: duration) }
    }
    audio.onSpeechFinished = { [weak self] in
      Task { @MainActor in self?.speechFinished() }
    }
    audio.onAvailabilityChanged = { [weak self] available in
      Task { @MainActor in self?.audioAvailabilityChanged(available) }
    }
    do {
      try audio.start()
      state = .listening
      _ = await appState.ensureEngineLoaded()  // warm up while the user talks
    } catch {
      state = .failed(String(localized: "The microphone couldn't start."))
    }
  }

  func end() {
    // Stop the reply first: cancelling only the turn's task would leave the engine busy.
    if appState.isBusy { appState.stop() }
    turnTask?.cancel()
    audio.stop()
    if cameraOn { camera.stop() }
    appState.onVoiceReply = nil
    appState.voiceModeActive = false
  }

  func toggleCamera() async {
    if cameraOn {
      camera.stop()
      cameraOn = false
    } else {
      cameraOn = await camera.start()
    }
  }

  func toggleMute() {
    muted.toggle()
    if muted, state == .hearing {
      audio.cancelUtterance()
      vad.reset()
      state = .listening
    }
  }

  /// Tap on the orb while the assistant thinks or speaks: interrupt it.
  func interrupt() {
    guard state == .speaking || state == .thinking else { return }
    stopReply()
    state = .listening
  }

  // MARK: Turn-taking

  private func heardLevel(_ level: Float, duration: TimeInterval) {
    let assistantBusy = state == .speaking || state == .thinking
    if state != .speaking { self.level = Double(max(0, min(1, (level + 60) / 50))) }
    guard !muted, state != .starting else { return }
    if case .failed = state { return }
    switch vad.feed(level: level, duration: duration, assistantSpeaking: assistantBusy) {
    case .speechStarted:
      if assistantBusy { stopReply() }  // barge-in
      audio.beginUtterance()
      utteranceStarted = Date()
      state = .hearing
    case .speechEnded:
      finishUtterance()
    case nil:
      if state == .hearing, let started = utteranceStarted,
        Date().timeIntervalSince(started) > Self.maxUtterance
      {
        vad.reset()
        finishUtterance()
      }
    }
  }

  private func finishUtterance() {
    guard let url = audio.endUtterance() else {
      state = .listening
      return
    }
    state = .thinking
    heard = ""
    answer = ""
    sentences = VoiceText.SentenceStream()
    replyLanguage = nil
    replyFinished = false
    silenced = false
    let image = cameraOn ? camera.snapshot() : nil
    turnTask = Task { [weak self] in
      guard let self else { return }
      let thread = self.thread ?? self.makeThread()
      self.thread = thread
      let accepted = await self.appState.sendVoiceTurn(
        audioFileURL: url, imageData: image, in: thread)
      try? FileManager.default.removeItem(at: url)
      self.heard = thread.orderedTurns.last(where: \.isUser)?.text ?? self.heard
      if !accepted || self.answer.isEmpty, self.state == .thinking { self.state = .listening }
    }
  }

  private func replyUpdated(_ text: String, final: Bool) {
    guard !silenced else { return }
    answer = text
    if let userTurn = thread?.orderedTurns.last(where: \.isUser), !userTurn.text.isEmpty {
      heard = userTurn.text
    }
    if replyLanguage == nil, text.count > 20 {
      replyLanguage = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
    }
    let ready = sentences.next(from: text, final: final)
    for sentence in ready {
      audio.speak(sentence, language: replyLanguage ?? NLLanguageRecognizer.dominantLanguage(for: sentence)?.rawValue)
    }
    if !ready.isEmpty, state == .thinking { state = .speaking }
    if final {
      replyFinished = true
      if !audio.isSpeaking, state != .hearing { state = .listening }
    }
  }

  /// A call took the audio (paused, "Starting…"), or it came back on the current route.
  private func audioAvailabilityChanged(_ available: Bool) {
    if state == .speaking || state == .thinking || state == .hearing { stopReply() }
    vad = VoiceActivityDetector()
    level = 0
    state = available ? .listening : .starting
  }

  private func speechFinished() {
    level = 0
    if replyFinished, state == .speaking { state = .listening }
  }

  private func stopReply() {
    silenced = true
    audio.stopSpeaking()
    if appState.isBusy { appState.stop() }
    replyFinished = true
  }
}
