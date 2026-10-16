import AVFoundation
import Foundation

/// 16 kHz mono WAV recorder for Gemma 4 audio input (≤ 30 s, per model card).
@Observable
@MainActor
final class AudioRecorder: NSObject {
  static let maxDuration: TimeInterval = 30

  private(set) var isRecording = false
  private(set) var elapsed: TimeInterval = 0
  private(set) var finishedURL: URL?
  var permissionDenied = false
  var errorMessage: String?

  private var recorder: AVAudioRecorder?
  private var timer: Timer?
  private var autoStopTask: Task<Void, Never>?

  /// UI tests: XCTest can't answer the system microphone prompt on device,
  /// so `--uitest-fake-mic` "records" a second of silence without it.
  private static let fakeMic = ProcessInfo.processInfo.arguments.contains("--uitest-fake-mic")

  func toggle() async {
    if isRecording {
      stop()
      return
    }
    if Self.fakeMic {
      startFake()
      return
    }
    let granted = await AVAudioApplication.requestRecordPermission()
    guard granted else {
      permissionDenied = true
      return
    }
    start()
  }

  func stop() {
    guard isRecording else { return }
    if Self.fakeMic {
      stopFake()
      return
    }
    autoStopTask?.cancel()
    autoStopTask = nil
    timer?.invalidate()
    timer = nil
    if let recorder { elapsed = recorder.currentTime }
    recorder?.stop()
    finishedURL = recorder?.url
    recorder = nil
    isRecording = false
    try? AVAudioSession.sharedInstance().setActive(false)
  }

  /// Recordings left in the temporary folder by an earlier run (a voice message never sent, an
  /// utterance cut off when the app quit). Called at launch, before anything records.
  nonisolated static func removeLeftovers(in folder: URL = FileManager.default.temporaryDirectory) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in names
    where (name.hasPrefix("agello-audio-") || name.hasPrefix("agello-voice-")) && name.hasSuffix(".wav") {
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
  }

  /// Delete the staged recording (call after the message is sent).
  func discard() {
    if isRecording { stop() }
    if let url = finishedURL {
      try? FileManager.default.removeItem(at: url)
    }
    finishedURL = nil
    elapsed = 0
  }

  private func startFake() {
    discard()
    isRecording = true
    elapsed = 0
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.elapsed += 0.25 }
    }
  }

  private func stopFake() {
    timer?.invalidate()
    timer = nil
    isRecording = false
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("agello-audio-\(UUID().uuidString).wav")
    if let format = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000),
      // Processing format must match the buffer (the default is Float32).
      let file = try? AVAudioFile(
        forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16,
        interleaved: false)
    {
      buffer.frameLength = 16_000
      try? file.write(from: buffer)
      finishedURL = url
    }
  }

  private func start() {
    discard()
    errorMessage = nil
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("agello-audio-\(UUID().uuidString).wav")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16_000,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
    ]
    do {
      // AirPods and other headsets record too, not only the built-in microphone.
      try AVAudioSession.sharedInstance().setCategory(
        .record, mode: .measurement, options: [.allowBluetoothHFP])
      try AVAudioSession.sharedInstance().setActive(true)
      let recorder = try AVAudioRecorder(url: url, settings: settings)
      self.recorder = recorder
      guard recorder.record() else {
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        errorMessage = "Couldn't start recording."
        return
      }
      isRecording = true
      timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
        // Read the recorder's clock (a counted timer drifts under load).
        Task { @MainActor in
          if let self, let recorder = self.recorder { self.elapsed = recorder.currentTime }
        }
      }
      autoStopTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(Self.maxDuration))
        guard !Task.isCancelled else { return }
        await MainActor.run { self?.stop() }
      }
    } catch {
      errorMessage = error.localizedDescription
      isRecording = false
    }
  }
}
