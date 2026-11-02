import AVFoundation

/// The app's claims on iOS's shared audio session: how each audio feature plays and records, and
/// the interruptions voice mode has to survive.
enum AudioSessionControl {
  /// Voice mode: the microphone and the speaker together, AirPods and other headsets included
  /// (voice chat implies HFP; stated for clarity).
  static func activateForVoiceChat() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
    try session.setActive(true)
  }

  /// A voice message: AirPods and other headsets record too, not only the built-in microphone.
  static func activateForRecording() throws {
    try AVAudioSession.sharedInstance().setCategory(
      .record, mode: .measurement, options: [.allowBluetoothHFP])
    try AVAudioSession.sharedInstance().setActive(true)
  }

  /// A reply read aloud: .playback so it's audible with the silent switch on.
  static func activateForSpeech() {
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: .duckOthers)
    try? AVAudioSession.sharedInstance().setActive(true)
  }

  /// Gives the session back; `resumingOthers` lets audio another app paused for ours resume.
  static func deactivate(resumingOthers: Bool = false) {
    try? AVAudioSession.sharedInstance().setActive(
      false, options: resumingOthers ? .notifyOthersOnDeactivation : [])
  }

  /// A call or another app takes the audio (`began`) and gives it back (`ended`), or media
  /// services restart (`reset`). The handlers run on the main queue; remove the observers with
  /// NotificationCenter.
  static func observeInterruptions(
    began: @escaping @Sendable () -> Void, ended: @escaping @Sendable () -> Void,
    reset: @escaping @Sendable () -> Void
  ) -> [NSObjectProtocol] {
    let center = NotificationCenter.default
    return [
      center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
        let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
          .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
        if type == .began { began() } else { ended() }
      },
      center.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
      ) { _ in reset() },
    ]
  }
}
