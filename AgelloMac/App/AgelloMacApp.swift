import Foundation
import SwiftUI

/// Agello for Mac. Until the shared app joins this target (MAC.md, M2), it's a placeholder
/// window and the runtime self-test.
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
  var body: some Scene {
    WindowGroup(id: "main") {
      VStack(spacing: 8) {
        Text("Agello for Mac")
          .font(.title2.weight(.semibold))
        Text("Under construction: the shared app arrives in M2.")
          .foregroundStyle(.secondary)
      }
      .padding(40)
      .frame(minWidth: 420, minHeight: 240)
    }
  }
}
