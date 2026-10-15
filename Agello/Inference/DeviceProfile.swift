import Foundation

/// Device capability profile. All decisions are pure functions of memory
/// sizes so they stay unit-testable; ``current`` reads the real device.
struct DeviceProfile: Sendable, Equatable {
  let physicalMemoryBytes: UInt64
  /// The app's memory limit (what jetsam enforces), or nil where the OS
  /// doesn't report it (simulator).
  let appMemoryLimitBytes: UInt64?

  init(physicalMemoryBytes: UInt64, appMemoryLimitBytes: UInt64? = nil) {
    self.physicalMemoryBytes = physicalMemoryBytes
    self.appMemoryLimitBytes = appMemoryLimitBytes
  }

  static var current: DeviceProfile {
    let available = MemoryProbe.availableBytes()
    return DeviceProfile(
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
      // Footprint + still-available = the limit, independent of current usage.
      appMemoryLimitBytes: available > 0 ? MemoryProbe.footprintBytes() + available : nil)
  }

  var memoryGB: Double { Double(physicalMemoryBytes) / 1_000_000_000.0 }

  // MARK: - Policy (pure)

  /// Free memory below which a running reply is stopped to avoid being
  /// terminated by the system. Measured: E4B kept working with ~0.8 GB left,
  /// so iOS memory warnings alone (sent much earlier) are not a reason to stop.
  static let lowMemoryStopBytes: UInt64 = 400_000_000

  static func shouldStopForMemory(availableBytes: UInt64) -> Bool {
    availableBytes > 0 && availableBytes < lowMemoryStopBytes
  }

  /// E4B's KV cache per token of context (24 INT8 caches): 0.47 GB at 16K.
  static let kvBytesPerToken: UInt64 = 28_672

  /// Whether a helper (title, memory, search planning, summary, dictation)
  /// runs beside the chat's conversation instead of replacing it.
  /// - Google's LiteRT-LM (v0.18.0) wipes the conversation whenever another
  ///   one runs, so the chat must be reseeded.
  /// - Ours (a runtime with a build id) keeps it: the runtime copies its KV
  ///   cache aside while the helper runs and restores it in about 0.1 s
  ///   (2.9 s to reseed 8K tokens of history on the Mac). Measured on the Mac
  ///   at 16K: +0.47 GB while the helper runs (one copy of the cache), none
  ///   afterwards, so it needs that much memory above ``lowMemoryStopBytes``.
  /// `availableBytes` 0 means not reported (the Mac): keep.
  static func keepsConversationAcrossHelpers(
    runtimeKeepsSessions: Bool, maxNumTokens: Int, availableBytes: UInt64
  ) -> Bool {
    guard runtimeKeepsSessions else { return false }
    guard availableBytes > 0 else { return true }
    let peak = kvBytesPerToken * UInt64(max(0, maxNumTokens))
    return availableBytes >= peak + lowMemoryStopBytes
  }

  /// Everyday chat context. Calibrated on iPhone 17 Pro: a larger KV cache
  /// slows *every* reply (E4B decode 43 → 38 → 34 → 27 tok/s at 4K → 8K →
  /// 16K → 32K), so chat stays at 8K and long inputs use ``maxContextTokens``.
  static let standardContextTokens = 8_192

  /// Default KV-cache size (`maxNumTokens`). Supported devices (iPhone 15 Pro
  /// and later) all have 8 GB+; smaller values only apply to the simulator.
  static func defaultMaxTokens(model: ModelID, memoryBytes: UInt64) -> Int {
    memoryBytes >= 7_000_000_000 ? standardContextTokens : 4_096
  }

  /// Largest context worth loading for long inputs (files, web passages).
  /// Measured E4B peak at 32K with a third of it filled: 3.6 GB; 16K stays
  /// within the ~3.5 GB worst case simulated for 8 GB iPhones.
  static func maxContextTokens(model: ModelID, appMemoryLimitBytes: UInt64?) -> Int {
    guard let limit = appMemoryLimitBytes else { return 16_384 }
    return limit >= 6_500_000_000 ? 32_768 : 16_384
  }

  func maxContextTokens(model: ModelID) -> Int {
    Self.maxContextTokens(model: model, appMemoryLimitBytes: appMemoryLimitBytes)
  }

  func defaultMaxTokens(model: ModelID) -> Int {
    Self.defaultMaxTokens(model: model, memoryBytes: physicalMemoryBytes)
  }

  /// Human-readable capability summary for Settings.
  var summary: String {
    var parts = [String(format: "%.0f GB RAM", memoryGB)]
    if let appMemoryLimitBytes {
      parts.append(String(format: "app limit %.1f GB", Double(appMemoryLimitBytes) / 1e9))
    }
    return parts.joined(separator: " · ")
  }
}
