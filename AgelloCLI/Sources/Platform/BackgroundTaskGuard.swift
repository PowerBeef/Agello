import Foundation

/// macOS twin of the iOS UIKit background-drain assertion (the CLI has no background suspension).
@MainActor
final class BackgroundTaskGuard {
  private init() {}

  static func begin(
    name: String,
    onExpire: @escaping @MainActor () -> Void = {}
  ) -> BackgroundTaskGuard {
    BackgroundTaskGuard()
  }

  func end() {}
}
