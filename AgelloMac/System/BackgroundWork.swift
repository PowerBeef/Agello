/// The iPhone's continued processing task (a reply that keeps going in the background) with
/// nothing to do on the Mac, where leaving the app never stops a reply (docs/MAC.md, M2–M3).
@MainActor
final class BackgroundWork {
  static let shared = BackgroundWork()

  var onExpire: (() -> Void)?
  var isActive: Bool { false }

  func begin(title: String, subtitle: String) {}
  func update(subtitle: String) {}
  func replyProgress(characters: Int) {}
  func sectionProgress(completed: Int, total: Int) {}
  func end(success: Bool) { onExpire = nil }
}
