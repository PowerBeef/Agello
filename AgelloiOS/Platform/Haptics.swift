import UIKit

/// Subtle haptics for key moments. Fire-and-forget; UIKit feedback
/// generators are main-actor only and retained as singletons to avoid
/// per-tap allocation and cold Taptic Engine spin-up.
@MainActor
enum Haptics {
  private static let mediumImpact: UIImpactFeedbackGenerator = {
    let generator = UIImpactFeedbackGenerator(style: .medium)
    generator.prepare()
    return generator
  }()

  private static let lightImpact: UIImpactFeedbackGenerator = {
    let generator = UIImpactFeedbackGenerator(style: .light)
    generator.prepare()
    return generator
  }()

  private static let selectionGenerator: UISelectionFeedbackGenerator = {
    let generator = UISelectionFeedbackGenerator()
    generator.prepare()
    return generator
  }()

  private static let notificationGenerator: UINotificationFeedbackGenerator = {
    let generator = UINotificationFeedbackGenerator()
    generator.prepare()
    return generator
  }()

  /// Sending a message, regenerating, retrying.
  static func send() {
    mediumImpact.impactOccurred()
    mediumImpact.prepare()
  }

  /// A small confirmation: toggles, copy, pin, a reply finishing.
  static func complete() {
    lightImpact.impactOccurred()
    lightImpact.prepare()
  }

  /// Picking an option (mode pills, versions, suggestions).
  static func selection() {
    selectionGenerator.selectionChanged()
    selectionGenerator.prepare()
  }

  /// Something finished well (a download).
  static func success() {
    notificationGenerator.notificationOccurred(.success)
    notificationGenerator.prepare()
  }

  /// Before something destructive.
  static func warning() {
    notificationGenerator.notificationOccurred(.warning)
    notificationGenerator.prepare()
  }

  static func error() {
    notificationGenerator.notificationOccurred(.error)
    notificationGenerator.prepare()
  }
}
