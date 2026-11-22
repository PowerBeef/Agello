@preconcurrency import AVFoundation
import Foundation

/// One audio engine for voice mode: the microphone (with Apple's voice
/// processing, so the assistant's own speech is cancelled from what the
/// microphone hears) and speech playback through the same engine (echo
/// cancellation needs to know what is being played).
final class VoiceAudio: @unchecked Sendable {
  /// Level of the microphone in dBFS over `duration` seconds (audio thread).
  var onLevel: (@Sendable (Float, TimeInterval) -> Void)?
  /// Echo-cancelled 16 kHz mono PCM buffer from the microphone tap (audio thread).
  var onAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
  /// All queued speech has played (main thread).
  var onSpeechFinished: (@Sendable () -> Void)?
  /// Audio paused (a call, another app) or came back after a pause, a route change or a
  /// media-services reset; false when it couldn't (main thread).
  var onAvailabilityChanged: (@Sendable (_ available: Bool) -> Void)?

  /// Format of buffers delivered to `onAudioBuffer` (16 kHz mono Int16).
  var captureFormat: AVAudioFormat { recordFormat }

  /// Replaced when audio restarts: a media-services reset invalidates the old engine.
  private var engine = AVAudioEngine()
  private var player = AVAudioPlayerNode()
  private var observers: [NSObjectProtocol] = []
  private let synthesizer = AVSpeechSynthesizer()
  private let lock = NSLock()

  /// What Gemma takes: 16 kHz mono 16-bit.
  private let recordFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
  /// Speech is converted to this before playback.
  private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

  private var inputConverter: AVAudioConverter?
  private var inputConverterSourceFormat: AVAudioFormat?
  private var file: AVAudioFile?
  private var fileURL: URL?
  /// Recent converted audio, so an utterance includes its first syllable.
  private var preroll: [AVAudioPCMBuffer] = []
  private var prerollFrames: AVAudioFrameCount = 0
  private let prerollLimit: AVAudioFrameCount = 8_000  // 0.5 s at 16 kHz
  private var pendingSpeech = 0
  /// Incremented on stop/pause/restart so late `synthesizer.write` or `scheduleBuffer` callbacks
  /// from a cancelled utterance never schedule onto a detached player or decrement a newer reply.
  private var speechGeneration: UInt64 = 0
  /// True only while `engine` is started and `player` is attached & connected.
  private var engineRunning = false
  /// Suppresses re-entrant `.AVAudioEngineConfigurationChange` notifications fired by `restart()`.
  private var restarting = false
  private var pendingRestartWorkItem: DispatchWorkItem?
  private(set) var echoCancellation = false
  /// Utterance files are written here, not on the real-time audio thread (a blocking disk write
  /// there can glitch the microphone and echo cancellation).
  private let writer = DispatchQueue(label: "agello.voice.writer", qos: .userInitiated)

  deinit {
    pendingRestartWorkItem?.cancel()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  // MARK: Lifecycle

  func start() throws {
    try activateSession()
    try startEngine()
    observeInterruptions()
  }

  private func activateSession() throws {
    try AudioSessionControl.activateForVoiceChat()
  }

  private func startEngine() throws {
    do {
      try engine.inputNode.setVoiceProcessingEnabled(true)
      echoCancellation = true
    } catch {
      echoCancellation = false
      Log.lifecycle.error("voice: no echo cancellation: \(error.localizedDescription, privacy: .public)")
    }
    engine.attach(player)
    try engine.connectNode(player, to: engine.mainMixerNode, format: playbackFormat)

    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    // Bluetooth HFP / route switches can transiently report 0 Hz / 0 channels; pass `nil` so
    // AVAudioEngine supplies the live hardware format once active and build the converter lazily.
    let tapFormat: AVAudioFormat? =
      inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 ? inputFormat : nil
    let converter = tapFormat.flatMap { AVAudioConverter(from: $0, to: recordFormat) }
    lock.withLock {
      inputConverter = converter
      inputConverterSourceFormat = tapFormat
    }
    try input.installAudioTap(onBus: 0, bufferSize: 1_024, format: tapFormat) { [weak self] buffer, _ in
      self?.process(AVAudioPCMBuffer(copying: buffer))
    }
    engine.prepare()
    try engine.start()
    try player.playAudio()
    lock.withLock { engineRunning = true }
  }

  func stop() {
    pendingRestartWorkItem?.cancel()
    pendingRestartWorkItem = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    synthesizer.stopSpeaking(at: .immediate)
    stopEngine()
    // An utterance cut off by the end of the session is never sent.
    cancelUtterance()
    lock.withLock {
      preroll = []
      prerollFrames = 0
    }
    AudioSessionControl.deactivate(resumingOthers: true)
  }

  private func stopEngine() {
    let (activeEngine, activePlayer) = lock.withLock { () -> (AVAudioEngine, AVAudioPlayerNode) in
      engineRunning = false
      speechGeneration &+= 1
      pendingSpeech = 0
      return (engine, player)
    }
    activePlayer.stop()
    activeEngine.inputNode.removeTap(onBus: 0)
    activeEngine.stop()
  }

  // MARK: Interruptions

  /// A call or another app takes the audio, the route changes (AirPods in or out), or media
  /// services restart: the engine stops on its own and has to be started again.
  private func observeInterruptions() {
    observers = AudioSessionControl.observeInterruptions(
      began: { [weak self] in self?.pause() },
      ended: { [weak self] in self?.restart(newEngine: false) },
      reset: { [weak self] in self?.restart(newEngine: true) })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
      ) { [weak self] note in
        guard let self, !self.restarting, (note.object as? AVAudioEngine) === self.engine else {
          return
        }
        self.scheduleConfigRestart()
      })
  }

  private func scheduleConfigRestart() {
    pendingRestartWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.observers.isEmpty else { return }
      self.restart(newEngine: false)
    }
    pendingRestartWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
  }

  private func pause() {
    pendingRestartWorkItem?.cancel()
    pendingRestartWorkItem = nil
    synthesizer.stopSpeaking(at: .immediate)
    stopEngine()
    cancelUtterance()
    onAvailabilityChanged?(false)
  }

  /// Audio again, on the current route, after a pause or change; a new engine after a reset.
  private func restart(newEngine: Bool) {
    pendingRestartWorkItem?.cancel()
    pendingRestartWorkItem = nil
    restarting = true
    defer { restarting = false }
    synthesizer.stopSpeaking(at: .immediate)
    stopEngine()
    cancelUtterance()
    lock.withLock {
      preroll = []
      prerollFrames = 0
      inputConverter = nil
      inputConverterSourceFormat = nil
      if newEngine {
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
      } else if player.engine === engine {
        engine.detach(player)
      }
    }
    do {
      try activateSession()
      try startEngine()
      Log.lifecycle.info("voice: audio restarted (new engine \(newEngine))")
      onAvailabilityChanged?(true)
    } catch {
      Log.lifecycle.error("voice: audio didn't restart: \(error.localizedDescription, privacy: .public)")
      onAvailabilityChanged?(false)
    }
  }

  // MARK: Recording

  /// Start writing an utterance (with the last half second before it).
  func beginUtterance() {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("agello-voice-\(UUID().uuidString).wav")
    lock.withLock {
      guard
        let file = try? AVAudioFile(
          forWriting: url, settings: recordFormat.settings, commonFormat: .pcmFormatInt16,
          interleaved: false)
      else { return }
      let prerolled = preroll
      writer.async { for buffer in prerolled { try? file.write(from: buffer) } }
      self.file = file
      fileURL = url
    }
  }

  /// Finish the utterance; returns its WAV file.
  func endUtterance() -> URL? {
    let url: URL? = lock.withLock {
      defer {
        file = nil
        fileURL = nil
      }
      return file == nil ? nil : fileURL
    }
    // Every buffer of the utterance is on disk before the file is read.
    writer.sync {}
    return url
  }

  func cancelUtterance() {
    if let url = endUtterance() { try? FileManager.default.removeItem(at: url) }
  }

  private func process(_ buffer: AVAudioPCMBuffer) {
    guard buffer.format.sampleRate > 0, buffer.frameLength > 0 else { return }
    let duration = Double(buffer.frameLength) / buffer.format.sampleRate
    onLevel?(Self.level(buffer), duration)
    let converter: AVAudioConverter? = lock.withLock {
      if inputConverter == nil || inputConverterSourceFormat != buffer.format {
        inputConverterSourceFormat = buffer.format
        inputConverter = AVAudioConverter(from: buffer.format, to: recordFormat)
      }
      return inputConverter
    }
    guard let converter,
      let converted = convert(buffer, with: converter, to: recordFormat)
    else { return }
    onAudioBuffer?(converted)
    lock.withLock {
      if let file { writer.async { try? file.write(from: converted) } }
      preroll.append(converted)
      prerollFrames += converted.frameLength
      while prerollFrames > prerollLimit, let first = preroll.first {
        prerollFrames -= first.frameLength
        preroll.removeFirst()
      }
    }
  }

  /// RMS level in dBFS.
  static func level(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -80 }
    var sum: Float = 0
    for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
    let rms = (sum / Float(buffer.frameLength)).squareRoot()
    return rms > 0 ? max(-80, 20 * log10(rms)) : -80
  }

  private func convert(
    _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat
  ) -> AVAudioPCMBuffer? {
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
    var consumed = false
    var error: NSError?
    converter.convert(to: output, error: &error) { _, status in
      if consumed {
        status.pointee = .noDataNow
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return buffer
    }
    return error == nil && output.frameLength > 0 ? output : nil
  }

  // MARK: Speech

  /// Queue a sentence; it plays after the ones before it.
  func speak(_ text: String, language: String?) {
    let generation: UInt64? = lock.withLock {
      guard engineRunning else { return nil }
      pendingSpeech += 1
      return speechGeneration
    }
    guard let generation else { return }
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = VoiceText.voice(for: language)
    var converter: AVAudioConverter?
    let format = playbackFormat
    synthesizer.write(utterance) { [weak self] buffer in
      guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
      guard pcm.frameLength > 0 else {
        // End of this sentence: a marker that completes only after the speaker finishes playing.
        guard let marker = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
          self.sentenceDone(generation: generation)
          return
        }
        self.lock.withLock {
          guard self.speechGeneration == generation, self.engineRunning, self.engine.isRunning,
            self.player.engine === self.engine
          else { return }
          self.player.scheduleBuffer(marker, completionCallbackType: .dataPlayedBack) { _ in
            self.sentenceDone(generation: generation)
          }
        }
        return
      }
      if converter == nil { converter = AVAudioConverter(from: pcm.format, to: format) }
      guard let converter, let converted = self.convert(pcm, with: converter, to: format) else {
        return
      }
      self.lock.withLock {
        guard self.speechGeneration == generation, self.engineRunning, self.engine.isRunning,
          self.player.engine === self.engine
        else { return }
        self.player.scheduleBuffer(converted, completionHandler: nil)
      }
    }
  }

  /// Stop speaking now (barge-in, end of session).
  func stopSpeaking() {
    synthesizer.stopSpeaking(at: .immediate)
    let (activePlayer, shouldPlay) = lock.withLock { () -> (AVAudioPlayerNode, Bool) in
      speechGeneration &+= 1
      pendingSpeech = 0
      return (player, engineRunning && engine.isRunning && player.engine === engine)
    }
    activePlayer.stop()
    if shouldPlay {
      try? activePlayer.playAudio()
    }
  }

  var isSpeaking: Bool { lock.withLock { pendingSpeech > 0 } }

  private func sentenceDone(generation: UInt64) {
    let finished: Bool = lock.withLock {
      guard speechGeneration == generation else { return false }
      pendingSpeech = max(0, pendingSpeech - 1)
      return pendingSpeech == 0
    }
    if finished {
      DispatchQueue.main.async { [weak self] in self?.onSpeechFinished?() }
    }
  }
}

extension VoiceText {
  /// Languages of the installed speech voices.
  static let voiceLanguages = Array(Set(AVSpeechSynthesisVoice.speechVoices().map(\.language)))
    .sorted()

  /// The voice for a language the recognizer named, or nil (the system's default voice).
  static func voice(for language: String?) -> AVSpeechSynthesisVoice? {
    language
      .flatMap { voiceLanguage(for: $0, available: voiceLanguages) }
      .flatMap(AVSpeechSynthesisVoice.init(language:))
  }
}
