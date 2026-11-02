import SwiftUI

/// What VoiceOver says, beside each platform's ``Haptics``.
@MainActor
extension Haptics {
  /// A reply finished: a tap, and VoiceOver says so. Not in voice mode, where the speech would
  /// reach the microphone and interrupt the next turn.
  static func replyFinished(spoken: Bool) {
    complete()
    if spoken { announce(String(localized: "Reply finished")) }
  }

  /// VoiceOver speaks `text` (nothing happens without VoiceOver).
  static func announce(_ text: String) {
    AccessibilityNotification.Announcement(text).post()
  }
}
