import SwiftData
import SwiftUI

/// Agello for Mac: the shared app in one main window. `--runtime-self-test` runs the runtime
/// check instead (RuntimeSelfTest).
@main
enum AgelloMacMain {
  static func main() {
    if CommandLine.arguments.contains(RuntimeSelfTest.flag) {
      Task { exit(await RuntimeSelfTest.run(arguments: CommandLine.arguments)) }
      dispatchMain()
    }
    AgelloMacApp.main()
  }
}

struct AgelloMacApp: App {
  @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
  @State private var appState: AppState
  @State private var shell: ShellModel
  let container: ModelContainer

  init() {
    let bootstrap = AppBootstrap()
    container = bootstrap.container
    _appState = State(initialValue: bootstrap.appState)
    _shell = State(initialValue: bootstrap.shell)
  }

  // AppState and the shell's model belong to the app, not the window: a reply keeps going when
  // the window closes, and the app never calls `enterBackground` (replies don't stop when it
  // isn't frontmost).
  var body: some Scene {
    Window("Agello", id: "main") {
      if AppBootstrap.hostsTests {
        Color.clear
      } else {
        MacRootView()
          .environment(appState)
          .environment(shell)
          // One tuned dark theme (see Theme).
          .preferredColorScheme(.dark)
          .tint(Theme.Brand.glacier)
      }
    }
    .modelContainer(container)
  }
}
