import UIKit

/// The system's low-memory signal: on iOS, the app's memory warning.
final class MemoryPressureMonitor {
  private let observer: NSObjectProtocol

  /// Calls `onPressure` on the main actor at each warning while the monitor lives. iOS has no
  /// stronger level to report.
  init(onPressure: @escaping @MainActor (MemoryPressureLevel) -> Void) {
    observer = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { _ in
      MainActor.assumeIsolated { onPressure(.warning) }
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(observer)
  }
}
