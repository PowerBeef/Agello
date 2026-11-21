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
  static let identifierPrefix = "com.patricedery.agello.continued."

  /// Called when iOS or the user cancels the task. Awaited before `setTaskCompleted` so the
  /// background GPU entitlement stays held while Metal command buffers drain.
  var onExpire: (@MainActor () async -> Void)?
  /// Why the last task didn't start (diagnostics and tests).
  private(set) var lastFailure: String?

  private var task: BGContinuedProcessingTask?
  private var identifier: String?
  private var title = ""
  /// Expected characters in a reply, for a rough progress fraction.
  private static let expectedReplyCharacters = 1_500.0

  /// Whether this device lets continued tasks use the GPU (Gemma needs it).
  static var supportsBackgroundGPU: Bool {
    BGTaskScheduler.supportedResources.contains(.gpu)
  }

  /// A continued task has been launched by iOS and is actively running.
  var isActive: Bool { task != nil }

  /// A continued task has been submitted (pending launch) or is actively running.
  var isPendingOrActive: Bool { task != nil || identifier != nil }

  /// Start a continued task for the reply the user just asked for.
  func begin(title: String, subtitle: String) {
    guard identifier == nil else { return }
    guard Self.supportsBackgroundGPU else {
      lastFailure = "no background GPU"
      return
    }
    lastFailure = nil
    let identifier = Self.identifierPrefix + UUID().uuidString
    self.identifier = identifier
    self.title = title
    let registered = Self.registerTask(identifier: identifier, owner: self)
    guard registered else {
      self.identifier = nil
      lastFailure = "registration refused"
      return
    }
    let request = BGContinuedProcessingTaskRequest(
      identifier: identifier, title: title, subtitle: subtitle)
    request.requiredResources = .gpu
    // Run now or not at all: a queued task would start after the reply.
    request.strategy = .fail
    Self.submitRequest(request, identifier: identifier, owner: self)
  }

  /// Submits the task request from a `nonisolated` context so its completion handler never
  /// inherits `@MainActor` isolation when `BackgroundTasks` delivers it on an XPC queue.
  private nonisolated static func submitRequest(
    _ request: BGContinuedProcessingTaskRequest,
    identifier: String,
    owner: BackgroundWork
  ) {
    BGTaskScheduler.shared.submitTaskRequest(request) { [weak owner] error in
      guard let error else { return }
      let message = String(describing: error)
      let localized = error.localizedDescription
      Task { @MainActor in
        owner?.handleSubmissionFailure(identifier: identifier, message: message, localized: localized)
      }
    }
  }

  /// Registers the task and installs its expiration handler from a `nonisolated` context so
  /// Swift 6 never attaches `@MainActor` isolation checks to Objective-C blocks that
  /// `BackgroundTasks` invokes on its own XPC queue.
  private nonisolated static func registerTask(
    identifier: String,
    owner: BackgroundWork
  ) -> Bool {
    BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) {
      [weak owner] task in
      guard let continued = task as? BGContinuedProcessingTask else {
        task.setTaskCompleted(success: false)
        return
      }
      Self.attachExpirationHandler(to: continued, identifier: identifier, owner: owner)
      nonisolated(unsafe) let launched = continued
      MainActor.assumeIsolated {
        guard let owner else {
          launched.expirationHandler = nil
          launched.setTaskCompleted(success: false)
          return
        }
        owner.handleLaunch(launched, identifier: identifier)
      }
    }
  }

  private nonisolated static func attachExpirationHandler(
    to task: BGContinuedProcessingTask,
    identifier: String,
    owner: BackgroundWork?
  ) {
    nonisolated(unsafe) let expiredTask = task
    task.expirationHandler = { [weak owner] in
      Task { @MainActor in
        if let owner {
          await owner.handleExpiration(identifier: identifier)
        } else {
          expiredTask.setTaskCompleted(success: false)
        }
      }
    }
  }

  private func handleSubmissionFailure(identifier: String, message: String, localized: String) {
    guard self.identifier == identifier else { return }
    self.identifier = nil
    lastFailure = message
    Log.lifecycle.error("continued task: \(localized, privacy: .public)")
  }

  private func handleLaunch(_ task: BGContinuedProcessingTask, identifier: String) {
    guard self.identifier == identifier else {
      task.expirationHandler = nil
      task.setTaskCompleted(success: false)
      return
    }
    task.progress.totalUnitCount = 100
    self.task = task
  }

  private func handleExpiration(identifier: String) async {
    guard self.identifier == identifier else { return }
    let handler = onExpire
    onExpire = nil
    await handler?()
    completeTask(matching: identifier, success: false)
  }

  private func completeTask(matching id: String? = nil, success: Bool) {
    if let id, identifier != id { return }
    if let task {
      self.task = nil
      if success { task.progress.completedUnitCount = 100 }
      task.setTaskCompleted(success: success)
    } else if let identifier {
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
    identifier = nil
    onExpire = nil
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
    completeTask(success: success)
  }
}
