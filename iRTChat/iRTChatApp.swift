import SwiftData
import SwiftUI

/// Receives background download events when iOS relaunches the app for them.
final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    guard identifier == BackgroundDownloads.identifier else { return completionHandler() }
    BackgroundDownloads.completionHandler = completionHandler
    // Reconnect to the session so its pending events are delivered.
    _ = BackgroundDownloads.session
  }
}

@main
struct iRTChatApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var appState: AppState
  @Environment(\.scenePhase) private var scenePhase
  let container: ModelContainer

  init() {
    // `--mock-engine` launch arg (or IRT_MOCK_ENGINE=1 env) runs the scripted
    // engine: full UI without a 2 GB model. Used for simulator smoke tests.
    let args = ProcessInfo.processInfo.arguments
    let env = ProcessInfo.processInfo.environment
    let useMock = args.contains("--mock-engine") || env["IRT_MOCK_ENGINE"] != nil

    let opened = ChatStoreLoader.open()
    container = opened.container

    // `--uitest-reset`: start UI tests from a clean slate (no chats, default
    // settings). Downloaded models are kept.
    if args.contains("--uitest-reset") {
      try? container.mainContext.delete(model: ChatTurn.self)
      try? container.mainContext.delete(model: ChatThread.self)
      try? container.mainContext.save()
      for key in [
        "inferenceOptions", "enableTools", "selectedThreadID", "activeModelID", "personalization",
        "memoryEnabled",
      ] {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }

    let state = AppState(useMockEngine: useMock)
    // Must be the same context the views use (`.modelContainer` injects
    // mainContext): turns are appended to view-owned threads, then saved here.
    state.modelContext = container.mainContext
    if let notice = opened.recoveryNotice { state.generationError = notice }
    _appState = State(initialValue: state)
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(appState)
    }
    .modelContainer(container)
    .onChange(of: scenePhase) { _, phase in
      Log.lifecycle.info(
        "scenePhase=\(String(describing: phase), privacy: .public) generating=\(appState.isGenerating)"
      )
      if phase == .background { appState.enterBackground() }
    }
  }
}
