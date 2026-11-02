import Dispatch

/// The system's low-memory signal: on the Mac, the kernel's memory-pressure levels.
final class MemoryPressureMonitor {
  private let source: any DispatchSourceMemoryPressure

  /// Calls `onPressure` on the main actor at each warning or critical event while the monitor
  /// lives. An event can carry both flags: critical wins.
  init(onPressure: @escaping @MainActor (MemoryPressureLevel) -> Void) {
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    self.source = source
    source.setEventHandler { [weak source] in
      guard let event = source?.data else { return }
      let level: MemoryPressureLevel = event.contains(.critical) ? .critical : .warning
      MainActor.assumeIsolated { onPressure(level) }
    }
    source.activate()
  }

  deinit {
    source.cancel()
  }
}
