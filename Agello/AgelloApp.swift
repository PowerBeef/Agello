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
struct AgelloApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var appState: AppState
  @Environment(\.scenePhase) private var scenePhase
  let container: ModelContainer
  /// Hosting the unit and device test bundles, which build their own
  /// `AppState`: the app shows nothing, so it doesn't warm up a second engine
  /// (1.1-1.9 GB that device runs measured as memory left after unloading,
  /// probe 16), answer the share inbox or open chats while tests run. UI tests
  /// launch the app normally, without this variable.
  private let hostsTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

  init() {
    // `--mock-engine` launch arg (or AGELLO_MOCK_ENGINE=1 env) runs the scripted
    // engine: full UI without a 2 GB model. Used for simulator smoke tests.
    let args = ProcessInfo.processInfo.arguments
    let env = ProcessInfo.processInfo.environment
    let useMock = args.contains("--mock-engine") || env["AGELLO_MOCK_ENGINE"] != nil

    // Crash, hang and performance reports from iOS, kept on the device (Settings → Advanced).
    if !hostsTests { MetricsReporter.shared.start() }

    let opened = ChatStoreLoader.open()
    container = opened.container

    // `--uitest-reset`: start UI tests from a clean slate (see AppReset).
    // Downloaded models are kept.
    if args.contains("--uitest-reset") {
      AppReset.perform(context: container.mainContext)
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
      if hostsTests {
        Color.clear
      } else {
        ContentView()
          .environment(appState)
          // One tuned dark theme (see Theme).
          .preferredColorScheme(.dark)
          .tint(Theme.Brand.glacier)
      }
    }
    .modelContainer(container)
    .onChange(of: scenePhase) { _, phase in
      Log.lifecycle.info(
        "scenePhase=\(String(describing: phase), privacy: .public) generating=\(appState.isGenerating)"
      )
      switch phase {
      case .background: appState.enterBackground()
      case .active: appState.enterForeground()
      default: break
      }
    }
  }
}
