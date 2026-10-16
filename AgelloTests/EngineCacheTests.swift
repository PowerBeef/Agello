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

  /// Before 32K meant 32,000, it made `kv-32768`: never keep it over a size still in use.
  func testFolderForASizeNoLongerAllocatedIsNeverKept() {
    let entries = [
      entry("kv-32768", minutesAgo: 1), entry("kv-8192", minutesAgo: 30), entry("kv-4096", minutesAgo: 60),
    ]
    XCTAssertEqual(
      Set(EngineCache.entriesToDelete(entries, current: "kv-16384", keep: 2)), ["kv-32768", "kv-4096"])
    XCTAssertEqual(EngineCache.contextSize(ofSizeFolder: "kv-32768"), 32_768)
    XCTAssertEqual(EngineCache.contextSize(ofSizeFolder: "kv-8192-abc"), 8_192)
    XCTAssertNil(EngineCache.contextSize(ofSizeFolder: "kv-all-abc"))
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
    let embedding = try EngineCache.embeddingDirectory(root: root, build: nil)

    _ = try EngineCache.directory(maxNumTokens: 4_096, root: root, build: nil)
    Thread.sleep(forTimeInterval: 0.05)
    _ = try EngineCache.directory(maxNumTokens: 8_192, root: root, build: nil)
    Thread.sleep(forTimeInterval: 0.05)
    let dir = try EngineCache.directory(maxNumTokens: 16_384, root: root, build: nil)

    let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    XCTAssertEqual(names, ["kv-16384", "kv-8192", "embedding"])
    XCTAssertEqual(dir, root.appendingPathComponent("kv-16384").path)
    XCTAssertTrue(FileManager.default.fileExists(atPath: embedding))
  }

  func testFolderNamesCarryTheBuild() {
    XCTAssertEqual(EngineCache.folder(maxNumTokens: 8_192, build: nil), "kv-8192")
    XCTAssertEqual(EngineCache.folder(maxNumTokens: 8_192, build: "e07a401c74c2"), "kv-all-e07a401c74c2")
    XCTAssertEqual(EngineCache.folder(maxNumTokens: 32_768, build: "e07a401c74c2"), "kv-all-e07a401c74c2")
    XCTAssertEqual(EngineCache.embeddingFolder(build: nil), "embedding")
    XCTAssertEqual(EngineCache.embeddingFolder(build: "dev"), "embedding-dev")
    XCTAssertNil(EngineCache.build(ofSizeFolder: "kv-8192"))
    XCTAssertEqual(EngineCache.build(ofSizeFolder: "kv-8192-e07a401c74c2"), "e07a401c74c2")
    XCTAssertEqual(EngineCache.build(ofSizeFolder: "kv-all-e07a401c74c2"), "e07a401c74c2")
  }

  func testAnotherBuildsFoldersAreDeleted() {
    let entries = [
      entry("kv-8192-aaa", minutesAgo: 30), entry("kv-4096-aaa", minutesAgo: 20),
      entry("kv-16384-aaa", minutesAgo: 40), entry("kv-8192", minutesAgo: 1),
      entry("kv-8192-bbb", minutesAgo: 2), entry("embedding", minutesAgo: 3),
      entry("embedding-aaa", minutesAgo: 50), entry("embedding-bbb", minutesAgo: 4),
    ]
    let deleted = EngineCache.entriesToDelete(entries, current: "kv-8192-aaa", keep: 2, build: "aaa")
    XCTAssertEqual(
      Set(deleted), ["kv-16384-aaa", "kv-8192", "kv-8192-bbb", "embedding", "embedding-bbb"])
  }

  func testGooglesBuildDeletesOurFolders() {
    let entries = [
      entry("kv-4096", minutesAgo: 10), entry("kv-8192-aaa", minutesAgo: 1),
      entry("embedding-aaa", minutesAgo: 1), entry("embedding", minutesAgo: 60),
    ]
    let deleted = EngineCache.entriesToDelete(entries, current: "kv-8192", keep: 2, build: nil)
    XCTAssertEqual(Set(deleted), ["kv-8192-aaa", "embedding-aaa"])
  }

  /// Our builds share one weight copy across sizes (T11): per-size folders
  /// of the same build, from before, go.
  func testOurBuildKeepsOneFolderForEverySize() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("EngineCacheTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("kv-8192-abc"), withIntermediateDirectories: true)
    _ = try EngineCache.directory(maxNumTokens: 16_384, root: root, build: "abc")
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    XCTAssertEqual(names, ["kv-all-abc"])
  }

  func testDirectoryForABuildReplacesAnotherBuildsCaches() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("EngineCacheTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try EngineCache.directory(maxNumTokens: 8_192, root: root, build: nil)
    _ = try EngineCache.embeddingDirectory(root: root, build: nil)
    let dir = try EngineCache.directory(maxNumTokens: 8_192, root: root, build: "abc")
    let embedding = try EngineCache.embeddingDirectory(root: root, build: "abc")

    XCTAssertEqual(dir, root.appendingPathComponent("kv-all-abc").path)
    XCTAssertEqual(embedding, root.appendingPathComponent("embedding-abc").path)
    // Google's embedder folder goes at the next load; every size shares our folder.
    let other = try EngineCache.directory(maxNumTokens: 4_096, root: root, build: "abc")
    XCTAssertEqual(other, dir)
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    XCTAssertEqual(names, ["kv-all-abc", "embedding-abc"])
  }
}
