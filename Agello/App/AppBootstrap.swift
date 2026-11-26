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
  #if DEBUG
    static let hostsTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
  #else
    static let hostsTests = false
  #endif

  let container: ModelContainer
  let appState: AppState
  let shell: ShellModel

  init() {
    // `--mock-engine` launch arg (or AGELLO_MOCK_ENGINE=1 env) runs the scripted
    // engine: full UI without a model download (Debug/Bench only).
    let args = ProcessInfo.processInfo.arguments
    let env = ProcessInfo.processInfo.environment
    // Debug and Bench builds only (2026-11-17): an App Store build carries no test hooks.
    #if DEBUG || BENCH
      let useMock = args.contains("--mock-engine") || env["AGELLO_MOCK_ENGINE"] != nil
    #else
      _ = args
      _ = env
      let useMock = false
    #endif

    // Crash, hang and performance reports from the system, kept on the device (Settings → Help).
    if !Self.hostsTests { MetricsReporter.shared.start() }

    let opened = ChatStoreLoader.open()
    container = opened.container
    EntityIndexing.configure(container: container)

    // `--uitest-reset`: start UI tests from a clean slate (see AppReset). Downloaded models are
    // kept. Debug builds only: the UI suites build Debug, and an archive shouldn't carry a launch
    // argument that deletes every chat (an external review, 2026-11-16).
    #if DEBUG
      if args.contains("--uitest-reset") {
        AppReset.perform(context: container.mainContext)
      }
    #endif

    // The bench driver's prompt is the draft of a new chat (docs/HARNESS.md): don't reopen the last one.
    #if DEBUG || BENCH
      if env["AGELLO_BENCH_DRAFT"] != nil { UserDefaults.standard.removeObject(forKey: "selectedThreadID") }
    #endif

    let state = AppState(useMockEngine: useMock)
    // Must be the same context the views use (`.modelContainer` injects
    // mainContext): turns are appended to view-owned threads, then saved here.
    state.modelContext = container.mainContext
    AppIntentBridge.appState = state
    ShortcutCallbackBroker.shared.setLauncher { url in
      await NativeActions.openExternalURL(url)
    }
    if let notice = opened.recoveryNotice { state.generationError = notice }
    appState = state
    shell = ShellModel(appState: state, context: container.mainContext)
  }
}
