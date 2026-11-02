import os

/// What iOS lets the app allocate (``MemoryProbe``'s per-platform half).
extension MemoryProbe {
  /// Bytes the app can still allocate before hitting its jetsam limit.
  static func availableBytes() -> UInt64 {
    UInt64(os_proc_available_memory())
  }

  /// The app's memory limit (what jetsam enforces), or nil where the OS doesn't report it
  /// (simulator). Footprint + still-available = the limit, independent of current usage.
  static func appMemoryLimitBytes() -> UInt64? {
    let available = availableBytes()
    return available > 0 ? footprintBytes() + available : nil
  }
}
