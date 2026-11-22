import AVFoundation
import NaturalLanguage
import Observation
import SwiftData

/// Hands-free conversation: listen, detect the end of the user's turn,
/// send the audio (and what the camera sees) to Gemma, speak the answer
/// sentence by sentence; talking over the assistant interrupts it.
@MainActor
@Observable
final class VoiceSession: Identifiable {
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
  @ObservationIgnored private let speechMonitor = VoiceSpeechMonitor()
  @ObservationIgnored private var monitorStartTask: Task<Void, Never>?
  @ObservationIgnored private var vad = NeuralTurnDetector()
  @ObservationIgnored private var sentences = VoiceText.SentenceStream()
  @ObservationIgnored private var replyLanguage: String?
  @ObservationIgnored private var replyFinished = false
  /// The current reply was interrupted: don't speak what's left of it.
  @ObservationIgnored private var silenced = false
  @ObservationIgnored private var turnTask: Task<Void, Never>?
  /// Counts utterances sent, so a turn that finishes after a newer one leaves its state alone.
  @ObservationIgnored private var turnNumber = 0
  @ObservationIgnored private var utteranceStarted: Date?
  @ObservationIgnored private let appState: AppState
  @ObservationIgnored private let makeThread: () -> ChatThread
  @ObservationIgnored private var thread: ChatThread?
  @ObservationIgnored private let startWithCamera: Bool

  /// UI tests can't answer the system microphone prompt on device.
  #if DEBUG || BENCH
    private static let fakeMic = ProcessInfo.processInfo.arguments.contains("--uitest-fake-mic")
  #else
    private static let fakeMic = false
  #endif
  static let maxUtterance: TimeInterval = 30

  init(
    appState: AppState, thread: ChatThread?, startWithCamera: Bool = false,
    makeThread: @escaping () -> ChatThread
  ) {
    self.appState = appState
    self.thread = thread
    self.startWithCamera = startWithCamera
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
    audio.onAudioBuffer = { [weak self] buffer in
      self?.speechMonitor.feed(buffer)
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
      if startWithCamera, CameraFeed.isAvailable {
        cameraOn = await camera.start()
      }
      let captureFormat = audio.captureFormat
      monitorStartTask = Task { [weak self] in
        guard let self else { return }
        let active = await self.speechMonitor.start(inputFormat: captureFormat) { [weak self] text, isFinal in
          Task { @MainActor in self?.heardTranscript(text, isFinal: isFinal) }
        }
        guard !Task.isCancelled else { return }
        self.vad.setNeuralActive(active)
      }
      _ = await appState.ensureEngineLoaded()  // warm up while the user talks
    } catch {
      state = .failed(String(localized: "The microphone couldn't start."))
    }
  }

  /// Pending mutating-tool confirmation card surfaced directly inside Voice Mode so hands-free
  /// actions never deadlock behind the full-screen cover.
  var pendingToolConfirmation: ToolConfirmationRequest? { appState.pendingToolConfirmation }

  func resolveToolConfirmation(id: UUID, approved: Bool) {
    appState.resolvePendingToolConfirmation(id: id, approved: approved)
  }

  func end() {
    appState.cancelPendingToolConfirmation(reason: "Voice mode closed.")
    // Stop the reply first: cancelling only the turn's task would leave the engine busy.
    if appState.isBusy { appState.stop() }
    monitorStartTask?.cancel()
    monitorStartTask = nil
    turnTask?.cancel()
    speechMonitor.stop()
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
      speechMonitor.resetUtterance()
      state = .listening
    }
  }

  /// Tap on the orb while the assistant thinks or speaks: interrupt it.
  func interrupt() {
    guard state == .speaking || state == .thinking else { return }
    stopReply()
    speechMonitor.resetUtterance()
    state = .listening
  }

  // MARK: Turn-taking

  private func heardLevel(_ level: Float, duration: TimeInterval) {
    let assistantBusy = state == .speaking || state == .thinking
    // The orb follows visible changes only: every buffer (~50 a second) re-rendered it.
    let shown = Double(max(0, min(1, (level + 60) / 50)))
    if state != .speaking, abs(shown - self.level) >= 0.02 { self.level = shown }
    guard !muted, state != .starting else { return }
    if case .failed = state { return }
    switch vad.feedLevel(level, duration: duration, assistantSpeaking: assistantBusy) {
    case .speechStarted:
      beginListeningToUtterance(interrupting: assistantBusy)
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

  private func heardTranscript(_ text: String, isFinal: Bool) {
    guard !muted, state != .starting else { return }
    if case .failed = state { return }
    let assistantBusy = state == .speaking || state == .thinking
    if vad.feedTranscript(text, isFinal: isFinal, assistantSpeaking: assistantBusy) == .speechStarted {
      beginListeningToUtterance(interrupting: assistantBusy)
    }
    if state == .hearing {
      heard = text
    }
  }

  private func beginListeningToUtterance(interrupting: Bool) {
    if interrupting { stopReply() }  // barge-in
    audio.beginUtterance()
    utteranceStarted = Date()
    state = .hearing
  }

  private func finishUtterance() {
    speechMonitor.resetUtterance()
    guard let url = audio.endUtterance() else {
      state = .listening
      return
    }
    state = .thinking
    if !vad.neuralActive { heard = "" }
    let image = cameraOn ? camera.snapshot() : nil
    turnNumber += 1
    let number = turnNumber
    let previous = turnTask
    turnTask = Task { [weak self] in
      // A barge-in stopped the last reply: it finishes stopping first, or this turn would find
      // the engine busy and be dropped (2026-11-16).
      await previous?.value
      // Spoken over before it was sent, as a barge-in stops a reply.
      guard let self, self.turnNumber == number else {
        try? FileManager.default.removeItem(at: url)
        return
      }
      // Reset only now: until the last reply has stopped, `silenced` keeps its late chunks quiet.
      self.answer = ""
      self.sentences = VoiceText.SentenceStream()
      self.replyLanguage = nil
      self.replyFinished = false
      self.silenced = false
      let thread = self.thread ?? self.makeThread()
      self.thread = thread
      let accepted = await self.appState.sendVoiceTurn(
        audioFileURL: url, imageData: image, in: thread)
      try? FileManager.default.removeItem(at: url)
      // A newer utterance owns the orb and the transcript now.
      guard self.turnNumber == number else { return }
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
    if state == .speaking || state == .thinking || state == .hearing {
      if available {
        stopReply()
      } else {
        // `VoiceAudio.pause()` already stopped the engine; stop inference without restarting playback.
        silenced = true
        if appState.isBusy { appState.stop() }
      }
    }
    let neuralActive = vad.neuralActive
    vad = NeuralTurnDetector()
    vad.setNeuralActive(neuralActive)
    speechMonitor.resetUtterance()
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
