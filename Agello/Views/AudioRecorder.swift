import AVFoundation
import Foundation

/// 16 kHz mono WAV recorder for Gemma 4 audio input (≤ 30 s, per model card).
@Observable
@MainActor
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
  static let maxDuration: TimeInterval = 30

  private(set) var isRecording = false
  private(set) var isStarting = false
  private(set) var elapsed: TimeInterval = 0
  private(set) var finishedURL: URL?
  var permissionDenied = false
  var errorMessage: String?

  @ObservationIgnored private nonisolated(unsafe) var recorder: AVAudioRecorder?
  @ObservationIgnored private nonisolated(unsafe) var timer: Timer?
  @ObservationIgnored private nonisolated(unsafe) var autoStopTask: Task<Void, Never>?
  @ObservationIgnored private nonisolated(unsafe) var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var startGeneration = 0

  deinit {
    autoStopTask?.cancel()
    recorder?.delegate = nil
    if let timer {
      if Thread.isMainThread {
        timer.invalidate()
      } else {
        nonisolated(unsafe) let mainTimer = timer
        DispatchQueue.main.async { mainTimer.invalidate() }
      }
    }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  /// UI tests: XCTest can't answer the system microphone prompt on device,
  /// so `--uitest-fake-mic` "records" a second of silence without it.
  #if DEBUG || BENCH
    private static let fakeMic = ProcessInfo.processInfo.arguments.contains("--uitest-fake-mic")
  #else
    private static let fakeMic = false
  #endif

  func toggle() async {
    if isRecording {
      stop()
      return
    }
    guard !isStarting else { return }
    if Self.fakeMic {
      startFake()
      return
    }
    isStarting = true
    startGeneration &+= 1
    let generation = startGeneration
    defer { isStarting = false }
    let granted = await AVAudioApplication.requestRecordPermission()
    guard !Task.isCancelled, startGeneration == generation else { return }
    guard granted else {
      permissionDenied = true
      return
    }
    start()
  }

  func stop() {
    startGeneration &+= 1
    guard isRecording else { return }
    if Self.fakeMic {
      stopFake()
      return
    }
    finishRecording(keepFile: true, stopRecorder: true)
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

  /// Transfers ownership of the staged recording URL to the caller without deleting the file.
  func takeFinishedURL() -> URL? {
    let url = finishedURL
    finishedURL = nil
    elapsed = 0
    return url
  }

  /// Delete the staged recording (call after the message is sent).
  func discard() {
    startGeneration &+= 1
    if isRecording { stop() }
    if let url = finishedURL {
      try? FileManager.default.removeItem(at: url)
    }
    finishedURL = nil
    elapsed = 0
  }

  private func finishRecording(keepFile: Bool, stopRecorder: Bool) {
    stopTimersAndObservers()
    let activeRecorder = recorder
    recorder = nil
    activeRecorder?.delegate = nil
    if let activeRecorder {
      elapsed = activeRecorder.currentTime
      if stopRecorder { activeRecorder.stop() }
      if keepFile {
        finishedURL = activeRecorder.url
      } else {
        try? FileManager.default.removeItem(at: activeRecorder.url)
      }
    }
    isRecording = false
    AudioSessionControl.deactivate(resumingOthers: true)
  }

  private func stopTimersAndObservers() {
    autoStopTask?.cancel()
    autoStopTask = nil
    timer?.invalidate()
    timer = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
  }

  private func startFake() {
    discard()
    isRecording = true
    elapsed = 0
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
      guard self != nil else {
        timer.invalidate()
        return
      }
      Task { @MainActor [weak self] in self?.elapsed += 0.25 }
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
    var sessionActivated = false
    do {
      try AudioSessionControl.activateForRecording()
      sessionActivated = true
      let recorder = try AVAudioRecorder(url: url, settings: settings)
      recorder.delegate = self
      self.recorder = recorder
      guard recorder.record() else {
        self.recorder = nil
        recorder.delegate = nil
        try? FileManager.default.removeItem(at: url)
        AudioSessionControl.deactivate(resumingOthers: true)
        errorMessage = "Couldn't start recording."
        return
      }
      isRecording = true
      observers = AudioSessionControl.observeInterruptions(
        began: { [weak self] in Task { @MainActor in self?.stop() } },
        ended: {},
        reset: { [weak self] in Task { @MainActor in self?.stop() } }
      )
      timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
        guard self != nil else {
          timer.invalidate()
          return
        }
        // Read the recorder's clock (a counted timer drifts under load).
        Task { @MainActor [weak self] in
          if let self, let recorder = self.recorder { self.elapsed = recorder.currentTime }
        }
      }
      autoStopTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(Self.maxDuration))
        guard !Task.isCancelled else { return }
        await MainActor.run { self?.stop() }
      }
    } catch {
      recorder?.delegate = nil
      recorder = nil
      try? FileManager.default.removeItem(at: url)
      stopTimersAndObservers()
      if sessionActivated { AudioSessionControl.deactivate(resumingOthers: true) }
      errorMessage = error.localizedDescription
      isRecording = false
    }
  }

  // MARK: - AVAudioRecorderDelegate

  nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
    let recorderID = ObjectIdentifier(recorder)
    Task { @MainActor [weak self] in
      guard let self, let active = self.recorder, ObjectIdentifier(active) == recorderID else { return }
      if !flag, self.errorMessage == nil {
        self.errorMessage = String(localized: "Recording stopped unexpectedly.")
      }
      self.finishRecording(keepFile: flag, stopRecorder: false)
    }
  }

  nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
    let recorderID = ObjectIdentifier(recorder)
    let message = error?.localizedDescription
    Task { @MainActor [weak self] in
      guard let self, let active = self.recorder, ObjectIdentifier(active) == recorderID else { return }
      self.errorMessage = message ?? String(localized: "Audio encoding failed.")
      self.finishRecording(keepFile: false, stopRecorder: false)
    }
  }
}
