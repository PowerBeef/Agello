import UIKit

/// Subtle haptics for key moments. Fire-and-forget; UIKit feedback
/// generators are main-actor only.
@MainActor
enum Haptics {
  /// Sending a message, regenerating, retrying.
  static func send() {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
  }

  /// A small confirmation: toggles, copy, pin, a reply finishing.
  static func complete() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  /// Picking an option (mode pills, versions, suggestions).
  static func selection() {
    UISelectionFeedbackGenerator().selectionChanged()
  }

  /// A reply finished: a tap, and VoiceOver says so. Not in voice mode, where the speech would
  /// reach the microphone and interrupt the next turn.
  static func replyFinished(spoken: Bool) {
    complete()
    if spoken { announce(String(localized: "Reply finished")) }
  }

  /// VoiceOver speaks `text` (nothing happens without VoiceOver).
  static func announce(_ text: String) {
    UIAccessibility.post(notification: .announcement, argument: text)
  }

  /// Something finished well (a download).
  static func success() {
    UINotificationFeedbackGenerator().notificationOccurred(.success)
  }

  /// Before something destructive.
  static func warning() {
    UINotificationFeedbackGenerator().notificationOccurred(.warning)
  }

  static func error() {
    UINotificationFeedbackGenerator().notificationOccurred(.error)
  }
}
