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
  @State private var shell: ShellModel
  @Environment(\.scenePhase) private var scenePhase
  let container: ModelContainer

  init() {
    let bootstrap = AppBootstrap()
    container = bootstrap.container
    _appState = State(initialValue: bootstrap.appState)
    _shell = State(initialValue: bootstrap.shell)
  }

  var body: some Scene {
    WindowGroup {
      if AppBootstrap.hostsTests {
        Color.clear
      } else {
        ContentView()
          .environment(appState)
          .environment(shell)
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
