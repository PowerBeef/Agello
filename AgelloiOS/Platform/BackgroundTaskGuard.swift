import UIKit

/// Holds a short UIKit background execution assertion (`beginBackgroundTask`) while in-flight
/// native GPU work cancels and drains on background transition.
@MainActor
final class BackgroundTaskGuard {
  private var taskID: UIBackgroundTaskIdentifier = .invalid

  private init() {}

  static func begin(
    name: String,
    onExpire: @escaping @MainActor () -> Void = {}
  ) -> BackgroundTaskGuard {
    let guardTask = BackgroundTaskGuard()
    guardTask.taskID = UIApplication.shared.beginBackgroundTask(withName: name) {
      onExpire()
      guardTask.end()
    }
    return guardTask
  }

  func end() {
    guard taskID != .invalid else { return }
    let id = taskID
    taskID = .invalid
    UIApplication.shared.endBackgroundTask(id)
  }
}
