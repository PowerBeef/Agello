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
  private(set) var latestActionCards: [ActionCardRecord] = []
  private(set) var cameraOn = false
  private(set) var muted = false
  /// Shown when camera permission is denied or camera capture cannot start.
  private(set) var cameraError: String?

  let camera = CameraFeed()
  @ObservationIgnored private static weak var activeOwner: VoiceSession?
  @ObservationIgnored private var started = false
  @ObservationIgnored private var ended = false
  @ObservationIgnored private var cameraToggling = false
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
  /// Cached turns for the active voice reply so 10 Hz flushes never re-scan `thread.orderedTurns`.
  @ObservationIgnored private var turnBaseLeafID: UUID?
  @ObservationIgnored private var activeUserTurn: ChatTurn?
  @ObservationIgnored private var activeReplyTurn: ChatTurn?
  /// EMA-smoothed mic level and timestamp to throttle `@Observable` `level` writes to ~25 Hz.
  @ObservationIgnored private var smoothedLevel: Double = 0
  @ObservationIgnored private var lastLevelPublish: ContinuousClock.Instant?

  private static let levelPublishInterval: Duration = .milliseconds(40)

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
    guard !ended, !started else { return }
    started = true
    Self.activeOwner = self
    appState.voiceModeActive = true
    appState.onVoiceReply = { [weak self] answer, final in self?.replyUpdated(answer, final: final) }
    if Self.fakeMic {
      state = .listening
      return
    }
    guard await AVAudioApplication.requestRecordPermission() else {
      guard !ended, !Task.isCancelled else {
        end()
        return
      }
      state = .failed(String(localized: "Microphone access is off. Turn it on in Settings."))
      return
    }
    guard !ended, !Task.isCancelled else {
      end()
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
      guard !ended, !Task.isCancelled else {
        end()
        return
      }
      state = .listening
      if startWithCamera, CameraFeed.isAvailable {
        let startedCamera = await camera.start()
        if ended || Task.isCancelled {
          camera.stop()
          end()
          return
        }
        cameraOn = startedCamera
        if !startedCamera {
          cameraError = String(localized: "Camera access is off. Turn it on in Settings.")
        }
      }
      guard !ended, !Task.isCancelled else {
        end()
        return
      }
      let captureFormat = audio.captureFormat
      monitorStartTask = Task { [weak self] in
        guard let self, !self.ended else { return }
        let active = await self.speechMonitor.start(inputFormat: captureFormat) { [weak self] text, isFinal in
          Task { @MainActor in self?.heardTranscript(text, isFinal: isFinal) }
        }
        guard !Task.isCancelled, !self.ended else {
          self.speechMonitor.stop()
          return
        }
        self.vad.setNeuralActive(active)
      }
      _ = await appState.ensureEngineLoaded()  // warm up while the user talks
    } catch {
      guard !ended, !Task.isCancelled else {
        end()
        return
      }
      state = .failed(String(localized: "The microphone couldn't start."))
    }
  }

  /// Pending mutating-tool confirmation card surfaced directly inside Voice Mode, scoped strictly
  /// to this session's active thread so another chat's confirmation never appears here.
  var pendingToolConfirmation: ToolConfirmationRequest? {
    guard let threadID = thread?.id,
      let ownerID = appState.generatingThreadID ?? appState.pendingToolConfirmationThreadID,
      ownerID == threadID
    else { return nil }
    return appState.pendingToolConfirmation
  }

  func resolveToolConfirmation(id: UUID, approved: Bool) {
    appState.resolvePendingToolConfirmation(id: id, approved: approved)
  }

  func resolveToolConfirmation(id: UUID, approvedSteps: Set<Int>) {
    appState.resolvePendingToolConfirmation(id: id, approvedSteps: approvedSteps)
  }

  func end() {
    guard !ended else { return }
    ended = true
    let ownsAppState = Self.activeOwner === self
    if ownsAppState {
      Self.activeOwner = nil
      if let confirmation = pendingToolConfirmation {
        appState.cancelPendingToolConfirmation(id: confirmation.id, reason: "Voice mode closed.")
      }
      // Stop the reply first: cancelling only the turn's task would leave the engine busy.
      if appState.isBusy, let threadID = thread?.id,
        appState.generatingThreadID == threadID || appState.preparingThreadID == threadID
      {
        appState.stop()
      }
      appState.onVoiceReply = nil
      appState.voiceModeActive = false
    }
    monitorStartTask?.cancel()
    monitorStartTask = nil
    turnTask?.cancel()
    turnTask = nil
    speechMonitor.stop()
    audio.stop()
    camera.stop()
    cameraOn = false
    activeUserTurn = nil
    activeReplyTurn = nil
    turnBaseLeafID = nil
    resetLevel()
  }

  func toggleCamera() async {
    guard !ended, !cameraToggling else { return }
    cameraError = nil
    if cameraOn {
      camera.stop()
      cameraOn = false
    } else {
      cameraToggling = true
      defer { cameraToggling = false }
      let startedCamera = await camera.start()
      guard !ended, !Task.isCancelled else {
        camera.stop()
        return
      }
      cameraOn = startedCamera
      if !startedCamera {
        cameraError = String(localized: "Camera access is off. Turn it on in Settings.")
      }
    }
  }

  func toggleMute() {
    guard !ended else { return }
    muted.toggle()
    if muted, state == .hearing {
      audio.cancelUtterance()
      vad.reset()
      speechMonitor.resetUtterance()
      resetLevel()
      state = .listening
    }
  }

  /// Tap on the orb while the assistant thinks or speaks: interrupt it.
  func interrupt() {
    guard !ended, pendingToolConfirmation == nil else { return }
    guard state == .speaking || state == .thinking else { return }
    stopReply()
    speechMonitor.resetUtterance()
    resetLevel()
    state = .listening
  }

  // MARK: Turn-taking

  private func resetLevel() {
    smoothedLevel = 0
    lastLevelPublish = nil
    if level != 0 { level = 0 }
  }

  private func heardLevel(_ level: Float, duration: TimeInterval) {
    guard !ended else { return }
    let assistantBusy = state == .speaking || state == .thinking
    // React only while actively hearing speech (EMA-smoothed & throttled to ~25 Hz); reset to 0
    // in all other states so the orb never freezes at a stale mic scale during thinking/speaking.
    if state == .hearing {
      let raw = Double(max(0, min(1, (level + 60) / 50)))
      smoothedLevel = smoothedLevel * 0.65 + raw * 0.35
      let now = ContinuousClock.now
      let due = lastLevelPublish.map { now - $0 >= Self.levelPublishInterval } ?? true
      if due, abs(smoothedLevel - self.level) >= 0.02 {
        self.level = smoothedLevel
        lastLevelPublish = now
      }
    } else {
      resetLevel()
    }
    // Pause VAD barge-in while a mutating-tool confirmation card awaits physical tap approval.
    guard !muted, state != .starting, pendingToolConfirmation == nil else { return }
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
    guard !ended, !muted, state != .starting, pendingToolConfirmation == nil else { return }
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
    resetLevel()
    state = .thinking
    if !vad.neuralActive { heard = "" }
    turnNumber += 1
    let number = turnNumber
    let previous = turnTask
    let audioCapture = audio
    let cameraCapture = camera
    let shouldCaptureImage = cameraOn
    // Flush WAV buffers and snapshot the camera frame off MainActor so the orb and UI stay smooth.
    let captureTask = Task.detached(priority: .userInitiated) { () -> (URL?, Data?) in
      let url = audioCapture.endUtterance()
      let image = (url != nil && shouldCaptureImage) ? cameraCapture.snapshot() : nil
      return (url, image)
    }
    turnTask = Task { [weak self] in
      let (capturedURL, image) = await captureTask.value
      guard let url = capturedURL else {
        if let self, !self.ended, self.turnNumber == number, self.state == .thinking {
          self.state = .listening
        }
        return
      }
      // A barge-in stopped the last reply: it finishes stopping first, or this turn would find
      // the engine busy and be dropped (2026-11-16).
      await previous?.value
      // Spoken over before it was sent, or session ended while waiting.
      guard let self, !self.ended, self.turnNumber == number else {
        try? FileManager.default.removeItem(at: url)
        return
      }
      // Reset only now: until the last reply has stopped, `silenced` keeps its late chunks quiet.
      self.answer = ""
      self.latestActionCards = []
      self.sentences = VoiceText.SentenceStream()
      self.replyLanguage = nil
      self.replyFinished = false
      self.silenced = false
      let thread = self.thread ?? self.makeThread()
      self.thread = thread
      self.turnBaseLeafID = thread.activeLeafID
      self.activeUserTurn = nil
      self.activeReplyTurn = nil
      let accepted = await self.appState.sendVoiceTurn(
        audioFileURL: url, imageData: image, in: thread)
      try? FileManager.default.removeItem(at: url)
      // A newer utterance or closed session owns the orb and transcript now.
      guard !self.ended, self.turnNumber == number else { return }
      self.resolveActiveVoiceTurns()
      if let userText = self.activeUserTurn?.text, !userText.isEmpty, self.heard != userText {
        self.heard = userText
      }
      if !accepted || self.answer.isEmpty, self.state == .thinking { self.state = .listening }
    }
  }

  private func resolveActiveVoiceTurns() {
    guard let thread, thread.activeLeafID != turnBaseLeafID else { return }
    guard activeUserTurn == nil || activeReplyTurn == nil else { return }
    let turns = thread.orderedTurns
    if activeReplyTurn == nil { activeReplyTurn = turns.last { !$0.isUser } }
    if activeUserTurn == nil { activeUserTurn = turns.last(where: \.isUser) }
  }

  private func replyUpdated(_ text: String, final: Bool) {
    guard !ended, !silenced else { return }
    answer = text
    resolveActiveVoiceTurns()
    if let userText = activeUserTurn?.text, !userText.isEmpty, heard != userText {
      heard = userText
    }
    if replyLanguage == nil, text.count > 20 {
      replyLanguage = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
    }
    let ready = sentences.next(from: text, final: final)
    for sentence in ready {
      audio.speak(sentence, language: replyLanguage ?? NLLanguageRecognizer.dominantLanguage(for: sentence)?.rawValue)
    }
    if !ready.isEmpty, state == .thinking {
      resetLevel()
      state = .speaking
    }
    if final {
      replyFinished = true
      latestActionCards = activeReplyTurn?.parts.actionCards ?? []
      if !audio.isSpeaking, state != .hearing {
        resetLevel()
        state = .listening
      }
    }
  }

  /// A call took the audio (paused, "Starting…"), or it came back on the current route.
  private func audioAvailabilityChanged(_ available: Bool) {
    guard !ended else { return }
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
    resetLevel()
    state = available ? .listening : .starting
  }

  private func speechFinished() {
    guard !ended else { return }
    resetLevel()
    if replyFinished, state == .speaking { state = .listening }
  }

  private func stopReply() {
    silenced = true
    audio.stopSpeaking()
    if appState.isBusy { appState.stop() }
    replyFinished = true
  }
}
