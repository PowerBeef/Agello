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

  /// Whether a device with `memoryBytes` of physical memory may run the app, given the
  /// platform's floor (``Platform/minimumMemoryBytes``).
  static func meetsFloor(memoryBytes: UInt64, minimum: UInt64) -> Bool {
    memoryBytes >= minimum
  }

  /// Whether this device may run the app. `AGELLO_SIMULATE_MEMORY_GB` (UI tests) stands in for
  /// the device's memory in this check only.
  static var isSupportedDevice: Bool {
    let simulated = ProcessInfo.processInfo.environment["AGELLO_SIMULATE_MEMORY_GB"].flatMap(Double.init)
    let memory = simulated.map { UInt64($0 * 1_000_000_000) } ?? ProcessInfo.processInfo.physicalMemory
    return meetsFloor(memoryBytes: memory, minimum: Platform.minimumMemoryBytes)
  }

  // MARK: - Policy (pure)

  /// Free memory below which a running reply is stopped to avoid being
  /// terminated by the system. Measured: E4B kept working with ~0.8 GB left,
  /// so iOS memory warnings alone (sent much earlier) are not a reason to stop.
  static let lowMemoryStopBytes: UInt64 = 400_000_000

  static func shouldStopForMemory(availableBytes: UInt64) -> Bool {
    availableBytes > 0 && availableBytes < lowMemoryStopBytes
  }

  /// E4B's KV cache per position on the published 32K file (24 INT8 caches): 0.47 GB at 16K.
  static let kvBytesPerToken: UInt64 = 28_672

  /// E4B v2 ring-KV cache costs: 8,192 B/tok for the 4 global layers plus 31.5 MiB fixed local
  /// sliding-window rings (`1,536` slots across 20 local layers).
  static let ringKvBytesPerToken: UInt64 = 8_192
  static let ringKvFixedBytes: UInt64 = 33_030_144

  /// Export window at or above which a model file uses ring-buffer local caches (v2 128K artifact).
  static let ringKvExportWindowThreshold = 65_536

  /// Positions mapped per sparse KV step (4,096) for a helper running beside detached main heaps.
  static let sparseHelperStepPositions: UInt64 = 4_096

  /// Whether a helper (title, memory, search planning, summary, dictation)
  /// runs beside the chat's conversation instead of replacing it.
  ///
  /// With Metal 4 sparse KV mapping snapshots (`copyBufferMappingsFromBuffer:`) on ring-KV models
  /// (`exportWindow >= 65_536`), the global KV heaps are detached in place without duplication:
  /// only the fixed local rings (31.5 MiB) plus one 4K sparse step (~32 MiB) for the helper are
  /// needed above ``lowMemoryStopBytes``. On older non-ring models (`exportWindow == nil` or
  /// `<= 32_768`), this bounds one copy of `usedTokens`.
  /// `availableBytes` 0 means not reported: keep.
  static func keepsConversationAcrossHelpers(
    usedTokens: Int, availableBytes: UInt64, exportWindow: Int? = nil
  ) -> Bool {
    guard availableBytes > 0 else { return true }
    let copy: UInt64
    if let exportWindow, exportWindow >= ringKvExportWindowThreshold {
      copy = ringKvFixedBytes + ringKvBytesPerToken * sparseHelperStepPositions
    } else {
      copy = kvBytesPerToken * UInt64(max(0, usedTokens))
    }
    return availableBytes >= copy + lowMemoryStopBytes
  }

  /// The chat context, no longer a setting (2026-11-02). On our runtime decode hardly depends on
  /// the window (iPhone 17 Pro, cooled: 39 / 42 / 42 tok/s at 8K / 16K / 32K), and 16K peaks at
  /// 1.9 GB. Devices with
  /// ``memoryForLargeContextBytes`` take ``largeContextTokens``; a load short of memory steps
  /// down (``contextTokens(standard:roomBytes:)``).
  static let standardContextTokens = 16_384

  /// The window of devices with ``memoryForLargeContextBytes``: a fixed 64K (the maintainer's
  /// choice, 2026-11-14; PERFORMANCE.md, "The window: a fixed 64K with sparse KV caches"; 32K
  /// from 2026-11-09). The model file caps it: the published file allocates 32,000 positions
  /// (``ContextBudget/allocatedPositions(requested:exportWindow:)``), a file opened to 128K all
  /// 65,536. Our runtime's caches cost only what a chat fills (sparse KV), so a short chat at 64K
  /// holds less than one at 32K did (0.86 against 1.09 GB on the M6) and a 44K prompt peaks at
  /// 1.8 GB there.
  static let largeContextTokens = 65_536

  /// Physical memory that takes ``largeContextTokens``: the 12 GB iPhones (iPhone 17 Pro) and
  /// Macs with 16 GB. 8 GB devices keep ``standardContextTokens``.
  static let memoryForLargeContextBytes: UInt64 = 11_000_000_000

  /// Think's default reasoning budget, on every device (the maintainer's choice, 2026-11-10;
  /// 12 GB devices had it since 2026-11-09): with 1,024 tokens a coding plan was cut mid-word.
  /// It's a ceiling, and no longer a setting (2026-11-11). At 16K the reply reserve grows from 5,120 to 5,461
  /// tokens (``ContextBudget/replyReserve(maxNumTokens:thinkingBudget:)``); at 8K it doesn't.
  static let defaultThinkingBudget = 4_096

  /// Room the app needs left as it loads to take ``largeContextTokens``:
  /// calibrated for sparse 64K KV caches + MSL 4.1 FlashAttention (which cut peak footprint by
  /// ~740 MB vs. dense 32K, peaking at ~1.68 GB on short chats and ~2.04 GB on 5.2K PDFs),
  /// leaving 700 MB headroom above ``roomForStandardContextBytes`` (3.5 GB).
  static let roomForLargeContextBytes: UInt64 = 4_200_000_000

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

  /// The KV-cache size (`maxNumTokens`). iPhones have 12 GB (the floor since 2026-11-10);
  /// smaller values only apply to the iPhone app run on an 8 GB Mac, and to the simulator.
  static func defaultMaxTokens(model: ModelID, memoryBytes: UInt64) -> Int {
    if memoryBytes >= memoryForLargeContextBytes { return largeContextTokens }
    return memoryBytes >= 7_000_000_000 ? standardContextTokens : 4_096
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
