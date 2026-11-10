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
    DeviceProfile(
      physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
      appMemoryLimitBytes: MemoryProbe.appMemoryLimitBytes())
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

  /// The Mac's counterpart of iOS's available memory, which the stop above and
  /// ``keepsConversationAcrossHelpers(runtimeKeepsSessions:maxNumTokens:availableBytes:)`` read:
  /// what the system could hand out without swapping (`systemAvailable`, 0 when not reported),
  /// within the app's limit (Metal's working set) less its footprint. Nothing left reads as 1,
  /// since 0 means "not reported".
  static func macAvailableBytes(systemAvailable: UInt64, footprint: UInt64, appLimit: UInt64?) -> UInt64 {
    guard let appLimit else { return systemAvailable }
    let headroom = appLimit > footprint ? appLimit - footprint : 0
    let available = systemAvailable == 0 ? headroom : min(systemAvailable, headroom)
    return max(available, 1)
  }

  /// E4B's KV cache per token of context (24 INT8 caches): 0.47 GB at 16K.
  static let kvBytesPerToken: UInt64 = 28_672

  /// Whether a helper (title, memory, search planning, summary, dictation)
  /// runs beside the chat's conversation instead of replacing it.
  /// - Google's LiteRT-LM (v0.18.0) loses the conversation whenever another
  ///   one runs (its restore leaves the helper's cache in the GPU buffers),
  ///   so the chat must be reseeded.
  /// - Ours (a runtime with a build id) keeps it: the runtime copies its KV
  ///   cache aside while the helper runs and restores it in about 0.1 s
  ///   (2.9 s to reseed 8K tokens of history on the Mac). The copy (0.47 GB
  ///   at 16K) lives while the helper runs (the engine restores the chat as
  ///   soon as the helper ends), so it needs that much memory above
  ///   ``lowMemoryStopBytes``.
  /// `availableBytes` 0 means not reported: keep. (The iPhone app on a Mac
  /// reports its physical memory.)
  static func keepsConversationAcrossHelpers(
    runtimeKeepsSessions: Bool, maxNumTokens: Int, availableBytes: UInt64
  ) -> Bool {
    guard runtimeKeepsSessions else { return false }
    guard availableBytes > 0 else { return true }
    let peak = kvBytesPerToken * UInt64(max(0, maxNumTokens))
    return availableBytes >= peak + lowMemoryStopBytes
  }

  /// The chat context, no longer a setting (2026-11-02). On our runtime decode hardly depends on
  /// the window (iPhone 17 Pro, cooled: 39 / 42 / 42 tok/s at 8K / 16K / 32K; on Google's v0.18.0
  /// it fell 39 → 34 → 27), and 16K peaks at 1.9 GB. Devices with
  /// ``memoryForLargeContextBytes`` take ``largeContextTokens``; a load short of memory steps
  /// down (``contextTokens(standard:roomBytes:)``).
  static let standardContextTokens = 16_384

  /// The window of devices with ``memoryForLargeContextBytes`` (the maintainer's choice,
  /// 2026-11-09): 32,768 requested, 32,000 allocated, the most the model file holds
  /// (``ContextBudget/allocatedPositions(requested:)``). It peaks at about 3.5 GB, 1.6 GB more
  /// than 16K.
  static let largeContextTokens = 32_768

  /// Physical memory that takes ``largeContextTokens``: the 12 GB iPhones (iPhone 17 Pro) and
  /// Macs with 16 GB. 8 GB devices keep ``standardContextTokens``.
  static let memoryForLargeContextBytes: UInt64 = 11_000_000_000

  /// Think's default reasoning budget, on every device (the maintainer's choice, 2026-11-10;
  /// 12 GB devices had it since 2026-11-09): with 1,024 tokens a coding plan was cut mid-word.
  /// It's a ceiling, and it stays a setting. At 16K the reply reserve grows from 5,120 to 5,461
  /// tokens (``ContextBudget/replyReserve(maxNumTokens:thinkingBudget:)``); at 8K it doesn't.
  static let defaultThinkingBudget = 4_096
  /// The default until 2026-11-10: a budget saved at it moves to the new one, once.
  static let previousThinkingBudget = 1_024

  /// Room the app needs left as it loads to take ``largeContextTokens``:
  /// ``roomForStandardContextBytes`` plus the 1.6 GB more a 32K engine peaks at. The memory
  /// suite's 6.0 GB envelope (5.98 GB left at load) passed every step with 1.3 GB to spare
  /// (iPhone 17 Pro, 2026-11-10); nothing between 5.1 and 6.0 GB is measured.
  static let roomForLargeContextBytes: UInt64 = 5_100_000_000

  /// The window of a load with less than ``roomForStandardContextBytes`` left.
  static let reducedContextTokens = 8_192

  /// Room the app needs left as it loads to take the standard window. A 16K engine holds about
  /// 0.8 GB more than an 8K one (iPhone 17 Pro: 1.92 against 1.13 GB). With 3.38 GB left at load
  /// (the memory suite at 3.5 GB usable, an 8 GB iPhone under heavy pressure), a 16K load, an
  /// image and a 2K-token prompt went over the limit; with 3.75 GB (4.0 GB usable) every step
  /// passed, and at 8K every step passed at 3.5 GB (2026-11-02).
  static let roomForStandardContextBytes: UInt64 = 3_500_000_000

  /// The window a load takes: `standard`, stepping down to ``standardContextTokens`` when the app
  /// has less than ``roomForLargeContextBytes`` left and to ``reducedContextTokens`` below
  /// ``roomForStandardContextBytes`` (`roomBytes`, nil where no limit is reported).
  static func contextTokens(standard: Int, roomBytes: UInt64?) -> Int {
    guard let roomBytes else { return standard }
    if roomBytes < roomForStandardContextBytes { return min(standard, reducedContextTokens) }
    if roomBytes < roomForLargeContextBytes { return min(standard, standardContextTokens) }
    return standard
  }

  /// The KV-cache size (`maxNumTokens`). Supported devices (iPhone 15 Pro and later, Macs with
  /// 8 GB) all have 8 GB+; smaller values only apply to the simulator.
  static func defaultMaxTokens(model: ModelID, memoryBytes: UInt64) -> Int {
    if memoryBytes >= memoryForLargeContextBytes { return largeContextTokens }
    return memoryBytes >= 7_000_000_000 ? standardContextTokens : 4_096
  }

  /// Largest context worth loading for long inputs (files, web passages).
  /// Measured E4B peak at 32K with a third of it filled: 3.6 GB; 16K stays
  /// within the ~3.5 GB worst case simulated for 8 GB iPhones. On a Mac the
  /// limit is Metal's working set: about 5.5 GB with 8 GB of memory (16K), 11 GB
  /// and up with 16 GB (32K).
  static func maxContextTokens(model: ModelID, appMemoryLimitBytes: UInt64?) -> Int {
    guard let limit = appMemoryLimitBytes else { return 16_384 }
    return limit >= 6_500_000_000 ? ContextBudget.maxAllocatedPositions : 16_384
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
