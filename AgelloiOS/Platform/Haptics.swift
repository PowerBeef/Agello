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
