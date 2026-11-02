import UIKit

/// The system's low-memory signal: on iOS, the app's memory warning.
final class MemoryPressureMonitor {
  private let observer: NSObjectProtocol

  /// Calls `onWarning` on the main actor at each warning while the monitor lives.
  init(onWarning: @escaping @MainActor () -> Void) {
    observer = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { onWarning() }
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(observer)
  }
}
