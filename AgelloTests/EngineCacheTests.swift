import XCTest

@testable import Agello

final class EngineCacheTests: XCTestCase {
  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("EngineCacheTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  func testFolderNamesCarryTheBuild() {
    XCTAssertEqual(EngineCache.folder(build: "e07a401c74c2"), "kv-all-e07a401c74c2")
    XCTAssertEqual(EngineCache.embeddingFolder(build: "dev"), "embedding-dev")
    // The runtime the app links reports its build.
    XCTAssertNotEqual(EngineCache.runtimeBuildID, "unknown")
    XCTAssertEqual(EngineCache.folder(), "kv-all-\(EngineCache.runtimeBuildID)")
  }

  /// Everything that isn't this build's goes: another build's folders, the per-size folders of
  /// earlier versions (with and without a build), and the flat files from before folders.
  func testOnlyThisBuildsFoldersStay() {
    let names = [
      "kv-all-aaa", "embedding-aaa", "kv-all-bbb", "embedding-bbb", "kv-8192", "kv-8192-aaa", "embedding",
      "gemma-4-E4B-it-fp16-rope.litertlm_1_2_mldrift_weight_cache.bin",
    ]
    XCTAssertEqual(
      Set(EngineCache.entriesToDelete(names, build: "aaa")),
      [
        "kv-all-bbb", "embedding-bbb", "kv-8192", "kv-8192-aaa", "embedding",
        "gemma-4-E4B-it-fp16-rope.litertlm_1_2_mldrift_weight_cache.bin",
      ])
    XCTAssertEqual(EngineCache.entriesToDelete(["kv-all-aaa", "embedding-aaa"], build: "aaa"), [])
  }

  func testDirectoryCreatesTheFolderAndClearsTheRest() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data([1]).write(to: root.appendingPathComponent("legacy_mldrift_weight_cache.bin"))
    for old in ["kv-8192", "kv-16384-abc", "embedding", "kv-all-old", "embedding-old"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(old), withIntermediateDirectories: true)
    }
    let embedding = try EngineCache.embeddingDirectory(root: root, build: "abc")
    let dir = try EngineCache.directory(root: root, build: "abc")

    XCTAssertEqual(dir, root.appendingPathComponent("kv-all-abc").path)
    XCTAssertEqual(embedding, root.appendingPathComponent("embedding-abc").path)
    let names = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
    XCTAssertEqual(names, ["kv-all-abc", "embedding-abc"])
    // A second load finds its folder and deletes nothing.
    XCTAssertEqual(try EngineCache.directory(root: root, build: "abc"), dir)
    XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), names)
  }

  func testAnotherBuildReplacesTheCaches() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try EngineCache.directory(root: root, build: "abc")
    _ = try EngineCache.embeddingDirectory(root: root, build: "abc")
    _ = try EngineCache.directory(root: root, build: "def")
    XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["kv-all-def"])
  }
}
