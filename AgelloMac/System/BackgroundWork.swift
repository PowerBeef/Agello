import Foundation

/// The iPhone's continued processing task (a reply that keeps going in the background) has
/// nothing to do on the Mac, where leaving the app never stops a reply. What a long summary
/// needs there is the Mac staying awake: from `begin` to `end`, idle sleep is held off.
@MainActor
final class BackgroundWork {
  static let shared = BackgroundWork()

  var onExpire: (() -> Void)?
  private var activity: NSObjectProtocol?

  var isActive: Bool { activity != nil }

  func begin(title: String, subtitle: String) {
    guard activity == nil else { return }
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .idleSystemSleepDisabled], reason: title)
  }

  func update(subtitle: String) {}
  func replyProgress(characters: Int) {}
  func sectionProgress(completed: Int, total: Int) {}

  func end(success: Bool) {
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
    onExpire = nil
  }
}
