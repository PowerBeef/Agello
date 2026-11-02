import SwiftData
import SwiftUI

/// What both apps set up at launch: the chat store, ``AppState`` and the shell's model, with the
/// launch switches for tests and the scripted engine.
@MainActor
struct AppBootstrap {
  /// Hosting the unit and device test bundles, which build their own
  /// `AppState`: the app shows nothing, so it doesn't warm up a second engine
  /// (1.1-1.9 GB that device runs measured as memory left after unloading,
  /// probe 16), answer the share inbox or open chats while tests run. UI tests
  /// launch the app normally, without this variable.
  static let hostsTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

  let container: ModelContainer
  let appState: AppState
  let shell: ShellModel

  init() {
    // `--mock-engine` launch arg (or AGELLO_MOCK_ENGINE=1 env) runs the scripted
    // engine: full UI without a 2 GB model. Used for simulator smoke tests.
    let args = ProcessInfo.processInfo.arguments
    let env = ProcessInfo.processInfo.environment
    let useMock = args.contains("--mock-engine") || env["AGELLO_MOCK_ENGINE"] != nil

    // Crash, hang and performance reports from the system, kept on the device (Settings → Advanced).
    if !Self.hostsTests { MetricsReporter.shared.start() }

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
    appState = state
    shell = ShellModel(appState: state, context: container.mainContext)
  }
}
