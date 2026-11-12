import SwiftData
import UIKit

/// What shared code asks of the device it runs on (one file per platform).
enum Platform {
  /// The device in the app's text: "stays on this iPhone".
  static let deviceName = "iPhone"
  /// The operating system in the app's text.
  static let osName = "iOS"
  /// The least physical memory the app runs on (the maintainer's choice, 2026-11-10): the 12 GB
  /// iPhones, which report 12.3 GB (iPhone 17 Pro and Pro Max, iPhone Air, and later). 8 GB
  /// iPhones see ``UnsupportedDeviceView``. iOS has no capability key for memory, and the
  /// gaming tier is for games (dropped 2026-11-12, the maintainer's choice): every iPhone on
  /// iOS 27 can install the app, and this check holds the floor.
  static let minimumMemoryBytes: UInt64 = 11_000_000_000
  /// Where SwiftData keeps the chat store: SwiftData's default with the App Group entitlement,
  /// the group container, where every install's chats already are.
  static let chatStoreGroupContainer = ModelConfiguration.GroupContainer.automatic

  /// The prompt before a large download on a metered network (cellular, Low Data Mode).
  static func meteredDownloadTitle(size: String) -> String {
    String(localized: "Download \(size) over cellular?")
  }
  static let waitForUnmeteredNetwork = String(localized: "Wait for Wi-Fi")
  static let waitingForUnmeteredNetwork = String(localized: "Waiting for Wi-Fi…")

  /// Puts `text` on the clipboard.
  @MainActor
  static func copy(_ text: String) {
    UIPasteboard.general.string = text
  }

  /// Reduce Motion, for animations started outside a view (views read the environment).
  @MainActor
  static var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

  /// Keeps the screen from locking while the app is in front: for the driverless bench, where
  /// no touch keeps the phone awake between cases.
  @MainActor
  static func keepScreenOn() {
    UIApplication.shared.isIdleTimerDisabled = true
  }
}
