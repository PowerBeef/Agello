import SwiftData

/// What shared code asks of the device it runs on (one file per platform). The command line
/// answers as the iPhone does where the answer steers the engine.
enum Platform {
  static let deviceName = "Mac"
  static let osName = "macOS"
  /// The iPhone's floor (12 GB iPhones report 12.3 GB), so the same devices count as supported.
  static let minimumMemoryBytes: UInt64 = 11_000_000_000
  /// The command line keeps its chats in memory and never opens the app's store.
  static let chatStoreGroupContainer = ModelConfiguration.GroupContainer.none
}
