import Foundation

/// The iPhone's continued processing task (a reply that keeps going in the background) has
/// nothing to do on the Mac. What long synthesis needs here is the Mac staying awake: from
/// `begin` to `end`, idle sleep is held off.
@MainActor
final class BackgroundWork {
  static let shared = BackgroundWork()

  var onExpire: (@MainActor () async -> Void)?
  private(set) var progressState: BackgroundWorkPlan.ProgressState?
  private var activity: NSObjectProtocol?

  var isActive: Bool { activity != nil }
  var isPendingOrActive: Bool { activity != nil }

  func begin(title: String, subtitle: String, totalSteps: Int = 1) {
    progressState = BackgroundWorkPlan.ProgressState(
      title: title, subtitle: subtitle, completedUnits: 0, completedSteps: 0,
      totalSteps: max(1, totalSteps))
    guard activity == nil else { return }
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiated, .idleSystemSleepDisabled], reason: title)
  }

  func update(title: String? = nil, subtitle: String) {
    guard var state = progressState else { return }
    if let title { state.title = title }
    state.subtitle = subtitle
    progressState = state
  }

  func stepProgress(completed: Int, total: Int, subtitle: String? = nil) {
    guard var state = progressState else { return }
    state.completedSteps = max(state.completedSteps, completed)
    state.totalSteps = max(state.totalSteps, total)
    state.completedUnits = max(
      state.completedUnits, BackgroundWorkPlan.stepUnits(completed: completed, total: total))
    if let subtitle { state.subtitle = subtitle }
    progressState = state
  }

  func replyProgress(characters: Int) {
    guard var state = progressState else { return }
    state.completedUnits = BackgroundWorkPlan.replyUnits(
      characters: characters, currentUnits: state.completedUnits)
    progressState = state
  }

  func sectionProgress(completed: Int, total: Int) {
    guard var state = progressState else { return }
    state.completedUnits = max(
      state.completedUnits,
      BackgroundWorkPlan.documentSectionUnits(
        documentIndex: 0, documentCount: 1, sectionCompleted: completed, sectionTotal: total))
    progressState = state
  }

  func documentSectionProgress(
    documentIndex: Int, documentCount: Int, sectionCompleted: Int, sectionTotal: Int,
    documentName: String
  ) {
    guard var state = progressState else { return }
    state.completedUnits = max(
      state.completedUnits,
      BackgroundWorkPlan.documentSectionUnits(
        documentIndex: documentIndex, documentCount: documentCount,
        sectionCompleted: sectionCompleted, sectionTotal: sectionTotal))
    state.subtitle = BackgroundWorkPlan.documentSubtitle(
      name: documentName, documentIndex: documentIndex, documentCount: documentCount,
      section: min(sectionCompleted + 1, sectionTotal), totalSections: sectionTotal)
    progressState = state
  }

  func end(success: Bool) {
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
    onExpire = nil
    progressState = nil
  }
}
