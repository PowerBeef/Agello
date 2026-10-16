import Foundation
import Synchronization

/// Whether the app may start GPU work now. iOS refuses GPU work from an app in the background,
/// except under a continued processing task that holds background GPU (``BackgroundWork``), so
/// loads, helpers and indexing check this before starting, and a model load interrupted by
/// backgrounding stops instead of falling back to the CPU for good.
enum GPUGate {
  private static let open = Mutex(true)

  static var isOpen: Bool { open.withLock { $0 } }

  static func set(_ isOpen: Bool) {
    open.withLock { $0 = isOpen }
  }

  /// The error work stopped by a closed gate reports.
  static let closedError = ChatError.underlying(
    message: String(localized: "Agello moved to the background; it will continue when you return."))
}
