import Foundation
import Observation

/// Tells macOS the app is working for the user while it answers, loads the model, takes
/// dictation or indexes files, so a hidden or covered window doesn't put it in App Nap (which
/// throttles its timers and lowers its priority). Idle sleep stays allowed; long summaries keep
/// the Mac awake through ``BackgroundWork``.
@MainActor
final class WorkActivity {
  private let appState: AppState
  private var token: NSObjectProtocol?

  init(appState: AppState) {
    self.appState = appState
    observe()
  }

  private var isWorking: Bool {
    if case .loading = appState.engineState { return true }
    return appState.isBusy || appState.isTranscribing || !appState.knowledge.indexing.isEmpty
  }

  private func observe() {
    let working = withObservationTracking {
      isWorking
    } onChange: { [weak self] in
      Task { @MainActor in self?.observe() }
    }
    if working, token == nil {
      token = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep, reason: "Answering or indexing")
    } else if !working, let token {
      ProcessInfo.processInfo.endActivity(token)
      self.token = nil
    }
  }
}
