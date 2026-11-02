import AppKit
import SwiftData

/// What shared code asks of the device it runs on (one file per platform).
enum Platform {
  /// The device in the app's text: "stays on this Mac".
  static let deviceName = "Mac"
  /// The operating system in the app's text.
  static let osName = "macOS"
  /// Where SwiftData keeps the chat store: the app's own container. On a Mac the App Group's
  /// container can also be the iPhone app's (Designed for iPad), and extensions hand items over
  /// through ShareInbox, never the store (docs/MAC.md, open decisions 1 and 3).
  static let chatStoreGroupContainer = ModelConfiguration.GroupContainer.none

  /// The prompt before a large download on a metered network: on a Mac, Personal Hotspot or a
  /// network in Low Data Mode.
  static func meteredDownloadTitle(size: String) -> String {
    String(localized: "Download \(size) over a metered connection?")
  }
  static let waitForUnmeteredNetwork = String(localized: "Wait for Another Network")
  static let waitingForUnmeteredNetwork = String(localized: "Waiting for another network…")

  /// Puts `text` on the clipboard.
  @MainActor
  static func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  /// Reduce Motion, for animations started outside a view (views read the environment).
  @MainActor
  static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
