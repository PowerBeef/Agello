import XCTest

@testable import Agello

final class DeviceProfileTests: XCTestCase {
  func testDefaultMaxTokens() {
    // No longer a setting: 32K with 12 GB (the iPhone floor). The smaller values only serve the
    // iPhone app run on a Mac with less memory.
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e4b, memoryBytes: 12_291_719_168), 32_768)
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e4b, memoryBytes: 8_000_000_000), 16_384)
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e4b, memoryBytes: 6_000_000_000), 4096)
  }

  /// The hardware floor (2026-11-10): 12 GB iPhones, which report 12.3 GB.
  func testHardwareFloor() {
    let iPhoneFloor: UInt64 = 11_000_000_000
    XCTAssertTrue(DeviceProfile.meetsFloor(memoryBytes: 12_291_719_168, minimum: iPhoneFloor))
    XCTAssertFalse(DeviceProfile.meetsFloor(memoryBytes: 8_000_000_000, minimum: iPhoneFloor))
    XCTAssertTrue(DeviceProfile.isSupportedDevice)
  }

  /// A launch starts from the defaults and keeps one saved choice, Think (2026-11-11: the
  /// Advanced screen is gone, so what was saved from it must not keep applying unseen).
  func testLaunchKeepsOnlyThink() {
    XCTAssertEqual(InferenceOptions().thinkingBudget, 4_096)
    XCTAssertEqual(InferenceOptions.launch(saved: nil), InferenceOptions())
    var saved = InferenceOptions()
    saved.enableThinking = true
    saved.thinkingBudget = 1_024
    saved.maxNumTokensOverride = 32_768
    saved.enableSpeculativeDecoding = false
    saved.enableVision = false
    saved.enableAudio = false
    saved.visualDetail = .fast
    saved.samplerPreset = .creative
    saved.systemPrompt = "Answer in pirate speak."
    saved.maxOutputTokens = 64
    var expected = InferenceOptions()
    expected.enableThinking = true
    XCTAssertEqual(InferenceOptions.launch(saved: saved), expected)
    saved.enableThinking = false
    XCTAssertEqual(InferenceOptions.launch(saved: saved), InferenceOptions())
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
    // No limit reported: the standard window.
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

  /// Mac finding (T3): the runtime keeps the chat's conversation across a helper at a peak cost
  /// of one copy of its KV cache (917.5 MB at a 32,000-token window, the runtime's own count).
  func testHelpersKeepTheConversationWhenMemoryAllows() {
    func keeps(_ tokens: Int, _ available: UInt64) -> Bool {
      DeviceProfile.keepsConversationAcrossHelpers(maxNumTokens: tokens, availableBytes: available)
    }
    // 8K: 28,672 × 8,192 = 0.23 GB, plus the 0.4 GB stop threshold.
    XCTAssertTrue(keeps(8_192, 634_881_024))
    XCTAssertFalse(keeps(8_192, 634_881_023))
    XCTAssertTrue(keeps(32_768, 1_400_000_000))
    XCTAssertFalse(keeps(32_768, 1_300_000_000))
    // Not reported: keep.
    XCTAssertTrue(keeps(32_768, 0))
    XCTAssertEqual(DeviceProfile.kvBytesPerToken * 32_000, 917_504_000)
  }

  /// The largest window worth loading follows the app's memory limit (32,000 at 6.5 GB or more).
  func testLargestWindowByMemoryLimit() {
    XCTAssertEqual(DeviceProfile.maxContextTokens(model: .e4b, appMemoryLimitBytes: 5_500_000_000), 16_384)
    XCTAssertEqual(DeviceProfile.maxContextTokens(model: .e4b, appMemoryLimitBytes: 8_590_000_000), 32_000)
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e4b, memoryBytes: 8_589_934_592), 16_384)
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e4b, memoryBytes: 12_291_719_168), 32_768)
  }

  /// A warning stops a reply only near exhaustion and releases the embedder; the chat model stays.
  func testMemoryPolicy() {
    XCTAssertEqual(MemoryPolicy.action(level: .warning), [.stopReplyIfExhausted, .releaseEmbedder])
  }

  func testCurrentDeviceReadsMemory() {
    XCTAssertGreaterThan(DeviceProfile.current.physicalMemoryBytes, 0)
    XCTAssertGreaterThan(DeviceProfile.current.memoryGB, 0)
  }
}
