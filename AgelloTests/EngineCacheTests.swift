import XCTest

@testable import Agello

final class EngineCacheTests: XCTestCase {
  private func entry(_ name: String, directory: Bool = true, minutesAgo: Double) -> EngineCache.Entry {
    EngineCache.Entry(
      name: name, isDirectory: directory, modified: Date(timeIntervalSinceNow: -minutesAgo * 60))
  }

  func testKeepsTheCurrentSizeAndTheLastOther() {
    let entries = [
      entry("kv-8192", minutesAgo: 30), entry("kv-4096", minutesAgo: 10),
      entry("kv-16384", minutesAgo: 60), entry("kv-2048", minutesAgo: 90),
    ]
    let deleted = EngineCache.entriesToDelete(entries, current: "kv-8192", keep: 2)
    XCTAssertEqual(Set(deleted), ["kv-16384", "kv-2048"])
  }

  func testCurrentCountsAsNewestEvenWhenItsFolderIsOld() {
    let entries = [entry("kv-1024", minutesAgo: 500), entry("kv-8192", minutesAgo: 1), entry("kv-4096", minutesAgo: 2)]
    XCTAssertEqual(EngineCache.entriesToDelete(entries, current: "kv-1024", keep: 2), ["kv-4096"])
  }

  func testANewSizeKeepsOnlyTheNewestOther() {
    let entries = [entry("kv-8192", minutesAgo: 5), entry("kv-4096", minutesAgo: 50)]
    XCTAssertEqual(EngineCache.entriesToDelete(entries, current: "kv-16384", keep: 2), ["kv-4096"])
  }

  func testRemovesFlatFilesFromBeforeFoldersButKeepsTheEmbedder() {
    let entries = [
      entry("gemma-4-E4B-it-fp16-rope.litertlm_1_2_mldrift_weight_cache.bin", directory: false, minutesAgo: 1),
      entry("embeddinggemma-2-text-270m.litertlm.text_encoder_1_2_mldrift_program_cache.bin", directory: false, minutesAgo: 1),
      entry("embedding", minutesAgo: 100),
      entry("kv-8192", minutesAgo: 3),
    ]
    let deleted = EngineCache.entriesToDelete(entries, current: "kv-8192", keep: 2)
    XCTAssertEqual(deleted.count, 2)
    XCTAssertFalse(deleted.contains("embedding"))
    XCTAssertFalse(deleted.contains("kv-8192"))
  }

  func testKeepOneLeavesOnlyTheCurrentSize() {
    let entries = [entry("kv-8192", minutesAgo: 1), entry("kv-4096", minutesAgo: 2)]
    XCTAssertEqual(EngineCache.entriesToDelete(entries, current: "kv-16384", keep: 1).sorted(), ["kv-4096", "kv-8192"])
  }

  func testDirectoryCreatesTheFolderAndEvictsOnDisk() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("EngineCacheTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([1]).write(to: root.appendingPathComponent("legacy_mldrift_weight_cache.bin"))
    let embedding = try EngineCache.embeddingDirectory(root: root)

    _ = try EngineCache.directory(maxNumTokens: 4_096, root: root)
    Thread.sleep(forTimeInterval: 0.05)
    _ = try EngineCache.directory(maxNumTokens: 8_192, root: root)
    Thread.sleep(forTimeInterval: 0.05)
    let dir = try EngineCache.directory(maxNumTokens: 16_384, root: root)

    let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    XCTAssertEqual(names, ["kv-16384", "kv-8192", "embedding"])
    XCTAssertEqual(dir, root.appendingPathComponent("kv-16384").path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: embedding))
  }
}
