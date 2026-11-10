import XCTest

@testable import Agello

final class DeviceProfileTests: XCTestCase {
  func testDefaultMaxTokens() {
    // No longer a setting: 32K with 12 GB (iPhone 17 Pro, 16 GB Macs), 16K on 8 GB devices.
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e4b, memoryBytes: 12_291_719_168), 32_768)
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e4b, memoryBytes: 8_000_000_000), 16_384)
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e4b, memoryBytes: 6_000_000_000), 4096)
  }

  /// Think's budget is 4,096 tokens by default on every device (2026-11-10); a budget saved at
  /// the old 1,024 moves once.
  func testThinkBudgetDefault() {
    XCTAssertEqual(InferenceOptions().thinkingBudget, 4_096)
    XCTAssertEqual(InferenceOptions.launch(saved: nil, budgetMigrated: true).thinkingBudget, 4_096)
    var saved = InferenceOptions()
    saved.thinkingBudget = 1_024
    saved.maxNumTokensOverride = 32_768
    let moved = InferenceOptions.launch(saved: saved, budgetMigrated: false)
    XCTAssertEqual(moved.thinkingBudget, 4_096)
    XCTAssertNil(moved.maxNumTokensOverride)
    // Chosen after the move, or by hand: kept.
    XCTAssertEqual(InferenceOptions.launch(saved: saved, budgetMigrated: true).thinkingBudget, 1_024)
    saved.thinkingBudget = 2_048
    XCTAssertEqual(InferenceOptions.launch(saved: saved, budgetMigrated: false).thinkingBudget, 2_048)
  }

  /// 32K by default where the device has 12 GB (2026-11-09), stepping down to 16K below 5.1 GB
  /// left at load and to 8K below 3.5 GB.
  func testLargeContextStepsDownWithTheRoomAtLoad() {
    XCTAssertEqual(DeviceProfile.contextTokens(standard: 32_768, roomBytes: 8_000_000_000), 32_768)
    XCTAssertEqual(DeviceProfile.contextTokens(standard: 32_768, roomBytes: 5_100_000_000), 32_768)
    XCTAssertEqual(DeviceProfile.contextTokens(standard: 32_768, roomBytes: 5_000_000_000), 16_384)
    XCTAssertEqual(DeviceProfile.contextTokens(standard: 32_768, roomBytes: 3_380_000_000), 8_192)
    XCTAssertEqual(DeviceProfile.contextTokens(standard: 32_768, roomBytes: nil), 32_768)
  }

  /// 16K when memory allows (2026-11-02): the memory suite's 3.5 GB envelope left 3.38 GB at load
  /// and went over the limit at 16K; its 4.0 GB envelope left 3.75 GB and passed.
  func testContextFollowsTheRoomAtLoad() {
    XCTAssertEqual(DeviceProfile.contextTokens(standard: 16_384, roomBytes: 3_380_000_000), 8_192)
    XCTAssertEqual(DeviceProfile.contextTokens(standard: 16_384, roomBytes: 3_750_000_000), 16_384)
    XCTAssertEqual(DeviceProfile.contextTokens(standard: 16_384, roomBytes: 3_500_000_000), 16_384)
    XCTAssertEqual(DeviceProfile.contextTokens(standard: 16_384, roomBytes: 0), 8_192)
    // No limit reported (simulator): the standard window. A Mac's working set leaves plenty.
    XCTAssertEqual(DeviceProfile.contextTokens(standard: 16_384, roomBytes: nil), 16_384)
    XCTAssertEqual(DeviceProfile.contextTokens(standard: 16_384, roomBytes: 5_300_000_000), 16_384)
    // A smaller standard window never grows.
    XCTAssertEqual(DeviceProfile.contextTokens(standard: 4_096, roomBytes: 1_000_000_000), 4_096)
  }

  func testLongContextCeilingFollowsAppMemoryLimit() {
    // 32,000: the most positions LiteRT-LM allocates for these files.
    XCTAssertEqual(DeviceProfile.maxContextTokens(model: .e4b, appMemoryLimitBytes: 8_600_000_000), 32_000)
    XCTAssertEqual(DeviceProfile.maxContextTokens(model: .e4b, appMemoryLimitBytes: 6_500_000_000), 32_000)
    XCTAssertEqual(DeviceProfile.maxContextTokens(model: .e4b, appMemoryLimitBytes: 5_000_000_000), 16_384)
    XCTAssertEqual(DeviceProfile.maxContextTokens(model: .e4b, appMemoryLimitBytes: nil), 16_384)
  }

  /// Device finding: iOS sends memory warnings long before it terminates the
  /// app (E4B kept working with ~0.8 GB left), so replies stop only when
  /// memory is nearly exhausted.
  func testLowMemoryStopThreshold() {
    XCTAssertFalse(DeviceProfile.shouldStopForMemory(availableBytes: 800_000_000))
    XCTAssertFalse(DeviceProfile.shouldStopForMemory(availableBytes: 400_000_000))
    XCTAssertTrue(DeviceProfile.shouldStopForMemory(availableBytes: 399_999_999))
    // 0 = not reported (simulator): never stop.
    XCTAssertFalse(DeviceProfile.shouldStopForMemory(availableBytes: 0))
  }

  /// Mac finding (T3): our runtime keeps the chat's conversation across a
  /// helper at a peak cost of one copy of its KV cache; Google's wipes it.
  func testHelpersKeepTheConversationWhenMemoryAllows() {
    func keeps(_ runtime: Bool, _ tokens: Int, _ available: UInt64) -> Bool {
      DeviceProfile.keepsConversationAcrossHelpers(
        runtimeKeepsSessions: runtime, maxNumTokens: tokens, availableBytes: available)
    }
    // 8K: 28,672 × 8,192 = 0.23 GB, plus the 0.4 GB stop threshold.
    XCTAssertTrue(keeps(true, 8_192, 634_881_024))
    XCTAssertFalse(keeps(true, 8_192, 634_881_023))
    XCTAssertTrue(keeps(true, 32_768, 1_400_000_000))
    XCTAssertFalse(keeps(true, 32_768, 1_300_000_000))
    // Not reported (the Mac): keep.
    XCTAssertTrue(keeps(true, 32_768, 0))
    // Google's runtime wipes it whatever the memory.
    XCTAssertFalse(keeps(false, 8_192, 0))
    XCTAssertFalse(keeps(false, 8_192, 8_000_000_000))
  }

  /// Agello for Mac's classes (docs/MAC.md, M3): the limit is Metal's working set, about 5.5 GB
  /// on an 8 GB Mac and 11 GB or more on 16 GB (12.7 GB on the M6); chat is 16K on 8 GB and 32K
  /// on 16 GB.
  func testMacMemoryClasses() {
    XCTAssertEqual(DeviceProfile.maxContextTokens(model: .e4b, appMemoryLimitBytes: 5_500_000_000), 16_384)
    XCTAssertEqual(DeviceProfile.maxContextTokens(model: .e4b, appMemoryLimitBytes: 11_000_000_000), 32_000)
    XCTAssertEqual(DeviceProfile.maxContextTokens(model: .e4b, appMemoryLimitBytes: 12_713_115_648), 32_000)
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e4b, memoryBytes: 8_589_934_592), 16_384)
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e4b, memoryBytes: 17_179_869_184), 32_768)
  }

  /// The Mac's available memory: the system's, within the working set less the footprint.
  func testMacAvailableMemory() {
    let gb: UInt64 = 1_000_000_000
    // Plenty free, but the app is near its working set: the headroom counts.
    XCTAssertEqual(
      DeviceProfile.macAvailableBytes(systemAvailable: 6 * gb, footprint: 10 * gb, appLimit: 11 * gb), gb)
    // A busy Mac: the system's free memory counts.
    XCTAssertEqual(
      DeviceProfile.macAvailableBytes(systemAvailable: 2 * gb, footprint: 2 * gb, appLimit: 11 * gb), 2 * gb)
    // Over the working set reads as nearly nothing (stop), never as "not reported".
    let over = DeviceProfile.macAvailableBytes(systemAvailable: 3 * gb, footprint: 12 * gb, appLimit: 11 * gb)
    XCTAssertEqual(over, 1)
    XCTAssertTrue(DeviceProfile.shouldStopForMemory(availableBytes: over))
    // The system's figure missing: the headroom alone; no limit either: not reported.
    XCTAssertEqual(DeviceProfile.macAvailableBytes(systemAvailable: 0, footprint: gb, appLimit: 5 * gb), 4 * gb)
    XCTAssertEqual(DeviceProfile.macAvailableBytes(systemAvailable: 0, footprint: gb, appLimit: nil), 0)
    // A helper beside a 32K chat needs its KV cache (0.92 GB) above the stop.
    XCTAssertTrue(
      DeviceProfile.keepsConversationAcrossHelpers(
        runtimeKeepsSessions: true, maxNumTokens: 32_000,
        availableBytes: DeviceProfile.macAvailableBytes(
          systemAvailable: 2 * gb, footprint: 2 * gb, appLimit: 11 * gb)))
    XCTAssertFalse(
      DeviceProfile.keepsConversationAcrossHelpers(
        runtimeKeepsSessions: true, maxNumTokens: 32_000,
        availableBytes: DeviceProfile.macAvailableBytes(
          systemAvailable: 1 * gb, footprint: 2 * gb, appLimit: 11 * gb)))
  }

  /// A warning stops a reply only near exhaustion and releases the embedder, as on iPhone;
  /// critical pressure (the Mac's) also unloads E4B when nothing uses it.
  func testMemoryPolicy() {
    let warning = MemoryPolicy.action(level: .warning, isBusy: false)
    XCTAssertEqual(warning, [.stopReplyIfExhausted, .releaseEmbedder])
    XCTAssertEqual(MemoryPolicy.action(level: .warning, isBusy: true), warning)
    XCTAssertEqual(
      MemoryPolicy.action(level: .critical, isBusy: false),
      [.stopReplyIfExhausted, .releaseEmbedder, .unloadChatModel])
    XCTAssertEqual(MemoryPolicy.action(level: .critical, isBusy: true), warning)
  }

  func testCurrentDeviceReadsMemory() {
    XCTAssertGreaterThan(DeviceProfile.current.physicalMemoryBytes, 0)
    XCTAssertGreaterThan(DeviceProfile.current.memoryGB, 0)
  }
}
