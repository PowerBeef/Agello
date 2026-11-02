import SwiftData
import UIKit

/// What shared code asks of the device it runs on (one file per platform).
enum Platform {
  /// The device in the app's text: "stays on this iPhone".
  static let deviceName = "iPhone"
  /// The operating system in the app's text.
  static let osName = "iOS"
  /// Where SwiftData keeps the chat store: SwiftData's default with the App Group entitlement,
  /// the group container, where every install's chats already are.
  static let chatStoreGroupContainer = ModelConfiguration.GroupContainer.automatic

  /// Puts `text` on the clipboard.
  @MainActor
  static func copy(_ text: String) {
    UIPasteboard.general.string = text
  }

  /// Reduce Motion, for animations started outside a view (views read the environment).
  @MainActor
  static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
}
