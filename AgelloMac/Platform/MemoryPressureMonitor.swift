import Dispatch

/// The system's low-memory signal: on the Mac, the kernel's memory-pressure warnings.
final class MemoryPressureMonitor {
  private let source: any DispatchSourceMemoryPressure

  /// Calls `onWarning` on the main actor at each warning or critical event while the monitor
  /// lives.
  init(onWarning: @escaping @MainActor () -> Void) {
    source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    source.setEventHandler {
      MainActor.assumeIsolated { onWarning() }
    }
    source.activate()
  }

  deinit {
    source.cancel()
  }
}
