import Foundation

/// The Mac has no shared audio session to claim: each audio feature uses the devices the user
/// picked in System Settings. The same calls as on iPhone, as no-ops.
enum AudioSessionControl {
  static func activateForVoiceChat() throws {}
  static func activateForRecording() throws {}
  static func activateForSpeech() {}
  static func deactivate(resumingOthers: Bool = false) {}

  /// No calls or other apps take the audio away on the Mac; AVAudioEngine's configuration
  /// changes (a headset plugged in) are observed by the shared code.
  static func observeInterruptions(
    began: @escaping @Sendable () -> Void, ended: @escaping @Sendable () -> Void,
    reset: @escaping @Sendable () -> Void
  ) -> [NSObjectProtocol] {
    []
  }
}
