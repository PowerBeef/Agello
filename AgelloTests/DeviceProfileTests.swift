import XCTest

@testable import Agello

final class DeviceProfileTests: XCTestCase {
  func testDefaultMaxTokens() {
    // Calibrated: 8K for everyday chat on all supported (8 GB+) devices.
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e4b, memoryBytes: 8_000_000_000), 8192)
    XCTAssertEqual(DeviceProfile.defaultMaxTokens(model: .e4b, memoryBytes: 6_000_000_000), 4096)
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

  func testCurrentDeviceReadsMemory() {
    XCTAssertGreaterThan(DeviceProfile.current.physicalMemoryBytes, 0)
    XCTAssertGreaterThan(DeviceProfile.current.memoryGB, 0)
  }
}
