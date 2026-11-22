@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Observation
import Speech

/// Resolves an already-installed Apple Neural Engine speech transcription module (`SpeechTranscriber`
/// or `DictationTranscriber`) for the user's primary language without triggering network downloads.
enum SpeechAnalyzerModule: Sendable {
  case speech(SpeechTranscriber)
  case dictation(DictationTranscriber)

  var module: any SpeechModule {
    switch self {
    case .speech(let transcriber): transcriber
    case .dictation(let transcriber): transcriber
    }
  }

  /// Resolves, reserves, and verifies an already-installed on-device ANE module for the user's
  /// primary preferred language; returns `nil` when unavailable so callers fall back cleanly.
  static func resolveInstalled(
    preferredLanguages: [String] = Locale.preferredLanguages
  ) async -> SpeechAnalyzerModule? {
    let speechLocales =
      SpeechTranscriber.isAvailable ? await SpeechTranscriber.installedLocales.map(\.identifier) : []
    let dictationLocales = await DictationTranscriber.installedLocales.map(\.identifier)
    let backend = Dictation.selectBackend(
      preferredLanguages: preferredLanguages,
      installedSpeechTranscriber: speechLocales,
      installedDictationTranscriber: dictationLocales
    )
    switch backend {
    case .speechTranscriber(let id):
      let locale = Locale(identifier: id)
      let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [.volatileResults, .fastResults],
        attributeOptions: []
      )
      guard (try? await AssetInventory.reserve(locale: locale)) != nil else { return nil }
      guard await AssetInventory.status(forModules: [transcriber]) == .installed else { return nil }
      return .speech(transcriber)
    case .dictationTranscriber(let id):
      let locale = Locale(identifier: id)
      let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
      guard (try? await AssetInventory.reserve(locale: locale)) != nil else { return nil }
      guard await AssetInventory.status(forModules: [transcriber]) == .installed else { return nil }
      return .dictation(transcriber)
    case .gemmaAudio:
      return nil
    }
  }

  /// Streams `(text, isFinal, rangeEnd)` tuples from the resolved module's result sequence.
  func consumeResults(
    _ handler: @escaping @Sendable (_ text: String, _ isFinal: Bool, _ rangeEnd: CMTime) async -> Void
  ) async throws {
    switch self {
    case .speech(let transcriber):
      for try await result in transcriber.results {
        await handler(String(result.text.characters), result.isFinal, result.range.end)
      }
    case .dictation(let transcriber):
      for try await result in transcriber.results {
        await handler(String(result.text.characters), result.isFinal, result.range.end)
      }
    }
  }
}

/// Thread-safe bridge from `AVAudioEngine`'s real-time tap to `SpeechAnalyzer`'s `AsyncStream`.
/// Serializes `AnalyzerInputConverter` (which is non-Sendable) on a dedicated utility queue so the
/// real-time audio thread never blocks.
final class SpeechAudioFeeder: @unchecked Sendable {
  let stream: AsyncStream<AnalyzerInput>
  private let continuation: AsyncStream<AnalyzerInput>.Continuation
  private let converter: AnalyzerInputConverter
  private let queue = DispatchQueue(label: "agello.speech.feeder", qos: .userInitiated)
  private var finished = false

  init(analyzerFormat: AVAudioFormat) {
    let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
    self.stream = stream
    self.continuation = continuation
    self.converter = AnalyzerInputConverter(analyzerFormat: analyzerFormat)
  }

  /// Copies `buffer` synchronously on the audio thread and converts it off-thread.
  func feed(_ buffer: AVAudioPCMBuffer) {
    guard buffer.frameLength > 0, let copy = Self.copy(buffer) else { return }
    queue.async { [weak self] in
      guard let self, !self.finished else { return }
      if let inputs = try? self.converter.convert(copy, at: nil) {
        for input in inputs { self.continuation.yield(input) }
      }
    }
  }

  /// Flushes any buffered samples and closes the `AsyncStream` (idempotent).
  func finish() {
    queue.async { [weak self] in
      guard let self, !self.finished else { return }
      self.finished = true
      if let remaining = try? self.converter.flush() {
        for input in remaining { self.continuation.yield(input) }
      }
      self.continuation.finish()
    }
  }

  private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let clone = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
    else { return nil }
    clone.frameLength = buffer.frameLength
    let channels = Int(buffer.format.channelCount)
    let frames = Int(buffer.frameLength)
    if let src = buffer.floatChannelData, let dst = clone.floatChannelData {
      for ch in 0..<channels { dst[ch].update(from: src[ch], count: frames) }
      return clone
    }
    if let src = buffer.int16ChannelData, let dst = clone.int16ChannelData {
      for ch in 0..<channels { dst[ch].update(from: src[ch], count: frames) }
      return clone
    }
    return nil
  }
}

/// Live on-device ANE streaming dictation for the chat composer.
/// Streams `<100 ms` partial words directly into the draft with zero E4B engine lock or KV eviction.
/// Returns `false` from `start` whenever ANE speech isn't available so `ChatView` falls back
/// seamlessly to `AudioRecorder` + Gemma 4 audio transcription.
@MainActor
@Observable
final class LiveDictation {
  static let maxDuration: TimeInterval = 120

  private(set) var isListening = false
  private(set) var elapsed: TimeInterval = 0
  var permissionDenied = false
  var errorMessage: String?

  @ObservationIgnored private var engine: AVAudioEngine?
  @ObservationIgnored private var analyzer: SpeechAnalyzer?
  @ObservationIgnored private var feeder: SpeechAudioFeeder?
  @ObservationIgnored private var analyzerTask: Task<CMTime?, Never>?
  @ObservationIgnored private var resultsTask: Task<Void, Never>?
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var autoStopTask: Task<Void, Never>?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var transcript = Dictation.LiveTranscript()
  @ObservationIgnored private var onDraftChange: (@MainActor (String) -> Void)?
  @ObservationIgnored private var startedAt: Date?
  @ObservationIgnored private var stopping = false

  #if DEBUG || BENCH
    private static let fakeMic = ProcessInfo.processInfo.arguments.contains("--uitest-fake-mic")
  #else
    private static let fakeMic = false
  #endif

  /// Attempts to start live ANE streaming dictation. Returns `true` if streaming started, or
  /// `false` if unavailable/denied (check `permissionDenied` before falling back to Gemma audio).
  func start(
    baseDraft: String,
    onDraftChange: @escaping @MainActor (String) -> Void
  ) async -> Bool {
    guard !isListening, !stopping else { return false }
    errorMessage = nil
    permissionDenied = false
    // UI tests drive AudioRecorder's fake microphone path without system prompts.
    guard !Self.fakeMic else { return false }

    let granted = await AVAudioApplication.requestRecordPermission()
    guard granted else {
      permissionDenied = true
      return false
    }

    guard let resolved = await SpeechAnalyzerModule.resolveInstalled() else {
      Log.lifecycle.info("dictation: no installed ANE Speech asset; falling back to Gemma audio")
      return false
    }

    do {
      try AudioSessionControl.activateForRecording()
      let audioEngine = AVAudioEngine()
      let inputFormat = audioEngine.inputNode.outputFormat(forBus: 0)
      guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
          compatibleWith: [resolved.module], considering: inputFormat)
      else {
        AudioSessionControl.deactivate()
        return false
      }

      let speechAnalyzer = SpeechAnalyzer(
        modules: [resolved.module],
        options: .init(priority: .userInitiated, modelRetention: .lingering)
      )
      try await speechAnalyzer.prepareToAnalyze(in: analyzerFormat)

      let bufferFeeder = SpeechAudioFeeder(analyzerFormat: analyzerFormat)
      transcript = Dictation.LiveTranscript(base: baseDraft)
      self.onDraftChange = onDraftChange
      self.engine = audioEngine
      self.analyzer = speechAnalyzer
      self.feeder = bufferFeeder

      audioEngine.inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
        bufferFeeder.feed(buffer)
      }
      audioEngine.prepare()
      try audioEngine.start()

      startTasks(analyzer: speechAnalyzer, module: resolved, feeder: bufferFeeder)
      observeInterruptions(for: audioEngine)
      startTimers()
      isListening = true
      Log.lifecycle.info("dictation: live ANE SpeechAnalyzer started")
      return true
    } catch {
      Log.lifecycle.error("dictation: ANE SpeechAnalyzer failed to start: \(error.localizedDescription, privacy: .public)")
      teardownAudio()
      return false
    }
  }

  /// Finishes dictation cleanly, finalizing any pending partial words into the composer draft.
  func stop() async {
    guard isListening, !stopping else { return }
    stopping = true
    defer {
      stopping = false
      isListening = false
      elapsed = 0
      onDraftChange = nil
    }

    stopTimersAndObservers()
    teardownAudioEngineOnly()
    feeder?.finish()

    let currentAnalyzer = analyzer
    let currentAnalyzerTask = analyzerTask
    let currentResultsTask = resultsTask
    analyzer = nil
    feeder = nil
    analyzerTask = nil
    resultsTask = nil

    if let currentAnalyzer {
      let lastTime = await currentAnalyzerTask?.value
      await Self.finalizeWithTimeout(analyzer: currentAnalyzer, through: lastTime)
    }
    currentResultsTask?.cancel()
    _ = await currentResultsTask?.value

    let finalDraft = transcript.commitVolatile()
    onDraftChange?(finalDraft)
    AudioSessionControl.deactivate(resumingOthers: true)
  }

  /// Immediately aborts dictation (e.g. switching threads or dismissing chat).
  func cancel() {
    guard isListening || analyzer != nil else { return }
    stopTimersAndObservers()
    teardownAudioEngineOnly()
    feeder?.finish()
    let currentAnalyzer = analyzer
    let currentAnalyzerTask = analyzerTask
    let currentResultsTask = resultsTask
    analyzer = nil
    feeder = nil
    analyzerTask = nil
    resultsTask = nil
    isListening = false
    elapsed = 0
    onDraftChange = nil
    AudioSessionControl.deactivate(resumingOthers: true)
    Task {
      currentAnalyzerTask?.cancel()
      currentResultsTask?.cancel()
      await currentAnalyzer?.cancelAndFinishNow()
    }
  }

  private func startTasks(
    analyzer: SpeechAnalyzer, module: SpeechAnalyzerModule, feeder: SpeechAudioFeeder
  ) {
    resultsTask = Task { [weak self] in
      do {
        try await module.consumeResults { [weak self] text, isFinal, _ in
          await MainActor.run {
            guard let self, self.isListening || self.stopping else { return }
            self.transcript.apply(text: text, isFinal: isFinal)
            self.onDraftChange?(self.transcript.composedDraft)
          }
        }
      } catch is CancellationError {
        return
      } catch {
        Log.lifecycle.error("dictation: ANE stream error: \(error.localizedDescription, privacy: .public)")
      }
    }
    analyzerTask = Task {
      try? await analyzer.analyzeSequence(feeder.stream)
    }
  }

  private func observeInterruptions(for audioEngine: AVAudioEngine) {
    observers = AudioSessionControl.observeInterruptions(
      began: { [weak self] in Task { @MainActor in await self?.stop() } },
      ended: {},
      reset: { [weak self] in Task { @MainActor in await self?.stop() } }
    )
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in await self?.stop() }
      }
    )
  }

  private func startTimers() {
    startedAt = Date()
    elapsed = 0
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, let startedAt = self.startedAt else { return }
        self.elapsed = Date().timeIntervalSince(startedAt)
      }
    }
    autoStopTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(Self.maxDuration))
      guard !Task.isCancelled else { return }
      await self?.stop()
    }
  }

  private func stopTimersAndObservers() {
    autoStopTask?.cancel()
    autoStopTask = nil
    timer?.invalidate()
    timer = nil
    startedAt = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
  }

  private func teardownAudioEngineOnly() {
    engine?.inputNode.removeTap(onBus: 0)
    engine?.stop()
    engine = nil
  }

  private func teardownAudio() {
    stopTimersAndObservers()
    teardownAudioEngineOnly()
    feeder?.finish()
    feeder = nil
    analyzer = nil
    AudioSessionControl.deactivate()
  }

  private static func finalizeWithTimeout(analyzer: SpeechAnalyzer, through lastTime: CMTime?) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        if let lastTime {
          try? await analyzer.finalizeAndFinish(through: lastTime)
        } else {
          await analyzer.cancelAndFinishNow()
        }
      }
      group.addTask { try? await Task.sleep(for: .milliseconds(1_500)) }
      _ = await group.next()
      group.cancelAll()
    }
  }
}

/// Passive ANE speech monitor fed by `VoiceAudio`'s echo-cancelled 16 kHz tap during Voice Mode.
/// Delivers real-time transcript cues to `NeuralTurnDetector` and instant captions to `VoiceSession`
/// without opening a second microphone session or touching Gemma 4's native audio token path.
final class VoiceSpeechMonitor: @unchecked Sendable {
  private let lock = NSLock()
  private var feeder: SpeechAudioFeeder?
  private var analyzer: SpeechAnalyzer?
  private var analyzerTask: Task<Void, Never>?
  private var resultsTask: Task<Void, Never>?
  private var lastResultEnd: CMTime = .zero
  private var ignoreBefore: CMTime = .zero
  private var utteranceTranscript = Dictation.LiveTranscript()
  private var stopped = false

  /// Prepares and starts an ANE `SpeechAnalyzer` accepting 16 kHz PCM buffers from `VoiceAudio`.
  /// Returns `true` when active; returns `false` when no installed ANE asset exists.
  func start(
    inputFormat: AVAudioFormat,
    onTranscript: @escaping @Sendable (_ text: String, _ isFinal: Bool) -> Void
  ) async -> Bool {
    guard let resolved = await SpeechAnalyzerModule.resolveInstalled() else { return false }
    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
      compatibleWith: [resolved.module], considering: inputFormat)
    else { return false }

    do {
      let speechAnalyzer = SpeechAnalyzer(
        modules: [resolved.module],
        options: .init(priority: .userInitiated, modelRetention: .lingering)
      )
      try await speechAnalyzer.prepareToAnalyze(in: analyzerFormat)

      let bufferFeeder = SpeechAudioFeeder(analyzerFormat: analyzerFormat)
      let alreadyStopped: Bool = lock.withLock {
        if stopped { return true }
        analyzer = speechAnalyzer
        feeder = bufferFeeder
        return false
      }
      if alreadyStopped {
        bufferFeeder.finish()
        await speechAnalyzer.cancelAndFinishNow()
        return false
      }

      let rTask = Task { [weak self] in
        do {
          try await resolved.consumeResults { [weak self] text, isFinal, rangeEnd in
            guard let self else { return }
            let snapshot: (String, Bool)? = self.lock.withLock {
              if CMTimeCompare(rangeEnd, self.lastResultEnd) > 0 {
                self.lastResultEnd = rangeEnd
              }
              guard CMTimeCompare(rangeEnd, self.ignoreBefore) > 0 else { return nil }
              self.utteranceTranscript.apply(text: text, isFinal: isFinal)
              let combined = self.utteranceTranscript.spokenText
              return combined.isEmpty ? nil : (combined, isFinal)
            }
            if let (combined, final) = snapshot {
              onTranscript(combined, final)
            }
          }
        } catch {
          return
        }
      }
      let aTask = Task {
        _ = try? await speechAnalyzer.analyzeSequence(bufferFeeder.stream)
      }
      lock.withLock {
        resultsTask = rTask
        analyzerTask = aTask
      }
      Log.lifecycle.info("voice: ANE neural turn monitor active")
      return true
    } catch {
      Log.lifecycle.error("voice: ANE neural turn monitor unavailable: \(error.localizedDescription, privacy: .public)")
      return false
    }
  }

  /// Feeds one echo-cancelled audio buffer from `VoiceAudio`.
  func feed(_ buffer: AVAudioPCMBuffer) {
    let activeFeeder = lock.withLock { stopped ? nil : feeder }
    activeFeeder?.feed(buffer)
  }

  /// Clears per-utterance transcript accumulation after a turn ends or is cancelled, ignoring any
  /// late results from audio already analyzed before this point.
  func resetUtterance() {
    lock.withLock {
      ignoreBefore = lastResultEnd
      utteranceTranscript = Dictation.LiveTranscript()
    }
  }

  /// Stops the monitor and releases the analyzer.
  func stop() {
    let (activeFeeder, activeAnalyzer, rTask, aTask) = lock.withLock {
      stopped = true
      defer {
        feeder = nil
        analyzer = nil
        resultsTask = nil
        analyzerTask = nil
      }
      return (feeder, analyzer, resultsTask, analyzerTask)
    }
    activeFeeder?.finish()
    rTask?.cancel()
    aTask?.cancel()
    if let activeAnalyzer {
      Task { await activeAnalyzer.cancelAndFinishNow() }
    }
  }
}
