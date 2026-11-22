import BackgroundTasks
import Foundation

/// Lets long multi-document synthesis and multi-step agentic research keep running when the user
/// leaves the app: a continued processing task (iOS shows its progress in a Live Activity, where
/// it can be cancelled). Uses `.gpu` resources paired with the `continued-processing.gpu` and
/// `continued-processing.inference` entitlements; without device support, replies stop cleanly
/// when backgrounded.
@MainActor
final class BackgroundWork {
  static let shared = BackgroundWork()
  static let identifierPrefix = "com.patricedery.agello.continued."

  /// Called when iOS or the user cancels the task. Awaited before `setTaskCompleted` so the
  /// background GPU entitlement stays held while Metal command buffers drain.
  var onExpire: (@MainActor () async -> Void)?
  /// Called when `submitTaskRequest` asynchronously rejects the request (e.g. `.immediateRunIneligible`
  /// after the app already moved to the background). Callers close `GPUGate` and drain if backgrounded.
  var onSubmissionFailure: (@MainActor () async -> Void)?
  /// Why the last task didn't start (diagnostics and tests).
  private(set) var lastFailure: String?
  /// Latest Live Activity progress state (synced even if updates arrive before task launch).
  private(set) var progressState: BackgroundWorkPlan.ProgressState?

  private var task: BGContinuedProcessingTask?
  private var identifier: String?
  private var title = ""
  /// Expected characters in a reply, for a smooth final progress phase.
  private static let expectedReplyCharacters = 1_500.0

  /// Whether this device lets continued tasks use the GPU (Gemma needs it).
  static var supportsBackgroundGPU: Bool {
    BGTaskScheduler.supportedResources.contains(.gpu)
  }

  /// Whether continued GPU + ANE inference tasks can run in the background on this device.
  static var supportsBackgroundInference: Bool {
    supportsBackgroundGPU
  }

  /// A continued task has been launched by iOS and is actively running.
  var isActive: Bool { task != nil }

  /// A continued task has been submitted (pending launch) or is actively running.
  var isPendingOrActive: Bool { task != nil || identifier != nil }

  /// Start a continued task for long synthesis or multi-step agentic work.
  func begin(title: String, subtitle: String, totalSteps: Int = 1) {
    let steps = max(1, totalSteps)
    guard identifier == nil else {
      update(title: title, subtitle: subtitle)
      return
    }
    progressState = BackgroundWorkPlan.ProgressState(
      title: title, subtitle: subtitle, completedUnits: 0, completedSteps: 0, totalSteps: steps)
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
    progressState = nil
    let failureHandler = onSubmissionFailure
    onExpire = nil
    onSubmissionFailure = nil
    Log.lifecycle.error("continued task: \(localized, privacy: .public)")
    if let failureHandler {
      Task { @MainActor in await failureHandler() }
    }
  }

  private func handleLaunch(_ task: BGContinuedProcessingTask, identifier: String) {
    guard self.identifier == identifier else {
      task.expirationHandler = nil
      task.setTaskCompleted(success: false)
      return
    }
    task.progress.totalUnitCount = 100
    self.task = task
    if let state = progressState {
      task.progress.completedUnitCount = state.completedUnits
      task.updateTitle(state.title, subtitle: state.subtitle)
    }
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
    onSubmissionFailure = nil
    progressState = nil
  }

  /// What's happening now (shown in the Live Activity).
  func update(title newTitle: String? = nil, subtitle: String) {
    if let newTitle { title = newTitle }
    if var state = progressState {
      if let newTitle { state.title = newTitle }
      state.subtitle = subtitle
      progressState = state
    }
    task?.updateTitle(title, subtitle: subtitle)
  }

  /// Granular multi-step progress for research or tool loops (maps onto `0...80%`).
  func stepProgress(completed: Int, total: Int, subtitle: String? = nil) {
    let units = BackgroundWorkPlan.stepUnits(completed: completed, total: total)
    let nextUnits = max(progressState?.completedUnits ?? 0, units)
    if var state = progressState {
      state.completedSteps = max(state.completedSteps, completed)
      state.totalSteps = max(state.totalSteps, total)
      state.completedUnits = nextUnits
      if let subtitle { state.subtitle = subtitle }
      progressState = state
    }
    if let task {
      task.progress.completedUnitCount = max(task.progress.completedUnitCount, nextUnits)
      if let subtitle { task.updateTitle(title, subtitle: subtitle) }
    }
  }

  /// Progress from the reply's length so far (smoothly finishes up to 95%).
  func replyProgress(characters: Int) {
    let current = progressState?.completedUnits ?? task?.progress.completedUnitCount ?? 0
    let target = BackgroundWorkPlan.replyUnits(
      characters: characters, currentUnits: current, expectedCharacters: Self.expectedReplyCharacters)
    if var state = progressState {
      state.completedUnits = target
      progressState = state
    }
    if let task {
      task.progress.completedUnitCount = max(task.progress.completedUnitCount, target)
    }
  }

  /// Real section progress for a single document, followed by the final answer (last 20%).
  func sectionProgress(completed: Int, total: Int) {
    let units = BackgroundWorkPlan.documentSectionUnits(
      documentIndex: 0, documentCount: 1, sectionCompleted: completed, sectionTotal: total)
    applyUnits(units)
  }

  /// Granular progress across multiple documents and their sections (`0...80%`).
  func documentSectionProgress(
    documentIndex: Int, documentCount: Int, sectionCompleted: Int, sectionTotal: Int,
    documentName: String
  ) {
    let units = BackgroundWorkPlan.documentSectionUnits(
      documentIndex: documentIndex, documentCount: documentCount,
      sectionCompleted: sectionCompleted, sectionTotal: sectionTotal)
    let subtitle = BackgroundWorkPlan.documentSubtitle(
      name: documentName, documentIndex: documentIndex, documentCount: documentCount,
      section: min(sectionCompleted + 1, sectionTotal), totalSections: sectionTotal)
    applyUnits(units, subtitle: subtitle)
  }

  private func applyUnits(_ units: Int64, subtitle: String? = nil) {
    let nextUnits = max(progressState?.completedUnits ?? 0, units)
    if var state = progressState {
      state.completedUnits = nextUnits
      if let subtitle { state.subtitle = subtitle }
      progressState = state
    }
    if let task {
      task.progress.completedUnitCount = max(task.progress.completedUnitCount, nextUnits)
      if let subtitle { task.updateTitle(title, subtitle: subtitle) }
    }
  }

  func end(success: Bool) {
    completeTask(success: success)
  }
}
