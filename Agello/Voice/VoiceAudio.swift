@preconcurrency import AVFoundation
import Foundation

/// One audio engine for voice mode: the microphone (with Apple's voice
/// processing, so the assistant's own speech is cancelled from what the
/// microphone hears) and speech playback through the same engine (echo
/// cancellation needs to know what is being played).
final class VoiceAudio: @unchecked Sendable {
  /// Level of the microphone in dBFS over `duration` seconds (audio thread).
  var onLevel: (@Sendable (Float, TimeInterval) -> Void)?
  /// All queued speech has played (main thread).
  var onSpeechFinished: (@Sendable () -> Void)?

  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let synthesizer = AVSpeechSynthesizer()
  private let lock = NSLock()

  /// What Gemma takes: 16 kHz mono 16-bit.
  private let recordFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
  /// Speech is converted to this before playback.
  private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!

  private var inputConverter: AVAudioConverter?
  private var file: AVAudioFile?
  private var fileURL: URL?
  /// Recent converted audio, so an utterance includes its first syllable.
  private var preroll: [AVAudioPCMBuffer] = []
  private var prerollFrames: AVAudioFrameCount = 0
  private let prerollLimit: AVAudioFrameCount = 8_000  // 0.5 s at 16 kHz
  private var pendingSpeech = 0
  private(set) var echoCancellation = false

  // MARK: Lifecycle

  func start() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
    try session.setActive(true)
    do {
      try engine.inputNode.setVoiceProcessingEnabled(true)
      echoCancellation = true
    } catch {
      echoCancellation = false
      Log.lifecycle.error("voice: no echo cancellation: \(error.localizedDescription, privacy: .public)")
    }
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)

    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    inputConverter = AVAudioConverter(from: inputFormat, to: recordFormat)
    input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
      self?.process(buffer)
    }
    engine.prepare()
    try engine.start()
    player.play()
  }

  func stop() {
    synthesizer.stopSpeaking(at: .immediate)
    player.stop()
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    lock.withLock {
      file = nil
      preroll = []
    }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
      for buffer in preroll { try? file.write(from: buffer) }
      self.file = file
      fileURL = url
    }
  }

  /// Finish the utterance; returns its WAV file.
  func endUtterance() -> URL? {
    lock.withLock {
      defer {
        file = nil
        fileURL = nil
      }
      return file == nil ? nil : fileURL
    }
  }

  func cancelUtterance() {
    if let url = endUtterance() { try? FileManager.default.removeItem(at: url) }
  }

  private func process(_ buffer: AVAudioPCMBuffer) {
    let duration = Double(buffer.frameLength) / buffer.format.sampleRate
    onLevel?(Self.level(buffer), duration)
    guard let converter = inputConverter, let converted = convert(buffer, with: converter, to: recordFormat)
    else { return }
    lock.withLock {
      if let file { try? file.write(from: converted) }
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
    let utterance = AVSpeechUtterance(string: text)
    if let language { utterance.voice = AVSpeechSynthesisVoice(language: language) }
    lock.withLock { pendingSpeech += 1 }
    var converter: AVAudioConverter?
    let format = playbackFormat
    synthesizer.write(utterance) { [weak self] buffer in
      guard let self, let pcm = buffer as? AVAudioPCMBuffer else { return }
      guard pcm.frameLength > 0 else {
        // End of this sentence: a marker that completes after its audio.
        self.player.scheduleBuffer(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!) {
          self.sentenceDone()
        }
        return
      }
      if converter == nil { converter = AVAudioConverter(from: pcm.format, to: format) }
      if let converter, let converted = self.convert(pcm, with: converter, to: format) {
        self.player.scheduleBuffer(converted, completionHandler: nil)
      }
    }
  }

  /// Stop speaking now (barge-in, end of session).
  func stopSpeaking() {
    synthesizer.stopSpeaking(at: .immediate)
    player.stop()
    lock.withLock { pendingSpeech = 0 }
    player.play()
  }

  var isSpeaking: Bool { lock.withLock { pendingSpeech > 0 } }

  private func sentenceDone() {
    let finished: Bool = lock.withLock {
      pendingSpeech = max(0, pendingSpeech - 1)
      return pendingSpeech == 0
    }
    if finished {
      DispatchQueue.main.async { [weak self] in self?.onSpeechFinished?() }
    }
  }
}
