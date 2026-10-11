import BackgroundTasks
import Foundation

/// Lets a reply the user started keep running when they leave the app:
/// a continued processing task (iOS shows its progress in a Live Activity,
/// where it can be cancelled). It needs the GPU in the background, which
/// only some devices support; without it, replies stop when the app leaves
/// the foreground, as before.
@MainActor
final class BackgroundWork {
  static let shared = BackgroundWork()
  static let identifierPrefix = "com.patricedery.irtchat.continued."

  /// Called when iOS or the user cancels the task.
  var onExpire: (() -> Void)?

  private var task: BGContinuedProcessingTask?
  private var identifier: String?
  private var title = ""
  /// Expected characters in a reply, for a rough progress fraction.
  private static let expectedReplyCharacters = 1_500.0

  /// Whether this device lets continued tasks use the GPU (Gemma needs it).
  static var supportsBackgroundGPU: Bool {
    BGTaskScheduler.supportedResources.contains(.gpu)
  }

  /// A reply runs as a continued task (it keeps going in the background).
  var isActive: Bool { task != nil }

  /// Start a continued task for the reply the user just asked for.
  func begin(title: String, subtitle: String) {
    guard identifier == nil, Self.supportsBackgroundGPU else { return }
    let identifier = Self.identifierPrefix + UUID().uuidString
    self.identifier = identifier
    self.title = title
    let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) {
      [weak self] task in
      guard let task = task as? BGContinuedProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      MainActor.assumeIsolated {
        guard let self, self.identifier == identifier else {
          task.setTaskCompleted(success: false)
          return
        }
        task.progress.totalUnitCount = 100
        task.expirationHandler = { [weak self] in
          Task { @MainActor in
            guard self?.identifier == identifier else { return }
            self?.onExpire?()
            task.setTaskCompleted(success: false)
            self?.task = nil
            self?.identifier = nil
          }
        }
        self.task = task
      }
    }
    guard registered else {
      self.identifier = nil
      return
    }
    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier, title: title, subtitle: subtitle)
    request.requiredResources = .gpu
    // Run now or not at all: a queued task would start after the reply.
    request.strategy = .fail
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      self.identifier = nil
      Log.lifecycle.error("continued task: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// What's happening now (shown in the Live Activity).
  func update(subtitle: String) {
    task?.updateTitle(title, subtitle: subtitle)
  }

  /// Progress from the reply's length so far (never "done" before the end).
  func replyProgress(characters: Int) {
    guard let task else { return }
    let fraction = min(0.95, 0.1 + Double(characters) / Self.expectedReplyCharacters * 0.85)
    task.progress.completedUnitCount = max(task.progress.completedUnitCount, Int64(fraction * 100))
  }

  /// Real section progress, followed by the final answer (last 20%).
  func sectionProgress(completed: Int, total: Int) {
    guard total > 0, let task else { return }
    task.progress.completedUnitCount = max(
      task.progress.completedUnitCount, Int64(min(80, completed * 80 / total)))
  }

  func end(success: Bool) {
    if let task {
      if success { task.progress.completedUnitCount = 100 }
      task.setTaskCompleted(success: success)
    } else if let identifier {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
    self.task = nil
    identifier = nil
    onExpire = nil
  }
}
