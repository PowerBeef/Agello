import Dispatch
import Foundation
import Synchronization

/// The system's low-memory signal: on the Mac, the kernel's memory-pressure events.
///
/// This Mac's pressure comes from everything it runs, not from the engine, so by default the
/// events are only counted (a record says how many came during a reply). With
/// `AGELLO_CLI_MEMORY_PRESSURE=real` they reach the app as the iPhone's memory warning does.
final class MemoryPressureMonitor {
  private let source: any DispatchSourceMemoryPressure
  /// Events since the process started: warnings, and those that were critical.
  static let events = Mutex<(warnings: Int, critical: Int)>((0, 0))

  init(onPressure: @escaping @MainActor (MemoryPressureLevel) -> Void) {
    let forwards = ProcessInfo.processInfo.environment["AGELLO_CLI_MEMORY_PRESSURE"] == "real"
    let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
    self.source = source
    source.setEventHandler { [weak source] in
      guard let event = source?.data else { return }
      let critical = event.contains(.critical)
      Self.events.withLock {
        $0.warnings += 1
        if critical { $0.critical += 1 }
      }
      if forwards { MainActor.assumeIsolated { onPressure(.warning) } }
    }
    source.activate()
  }

  deinit {
    source.cancel()
  }
}
