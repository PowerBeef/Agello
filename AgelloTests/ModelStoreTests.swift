import XCTest

@testable import Agello

/// Regression tests for the download-finishing path: the temp file must be
/// moved synchronously and size-verified (async hops let the system delete it).
final class ModelStoreTests: XCTestCase {
  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("ModelStoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  func testPlaceDownloadedFileMovesAndVerifies() throws {
    let source = scratch.appendingPathComponent("CFNetworkDownload_tmp.tmp")
    try Data(repeating: 0xAB, count: 1024).write(to: source)
    let models = scratch.appendingPathComponent("Models", isDirectory: true)

    let placed = try ModelStore.placeDownloadedFile(
      from: source, fileName: "model.litertlm", expectedSize: 1024, in: models)

    XCTAssertEqual(placed.lastPathComponent, "model.litertlm")
    XCTAssertTrue(FileManager.default.fileExists(atPath: placed.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
  }

  func testPlaceDownloadedFileRejectsWrongSizeAndCleansUp() throws {
    let source = scratch.appendingPathComponent("partial.tmp")
    try Data(repeating: 0x00, count: 100).write(to: source)
    let models = scratch.appendingPathComponent("Models", isDirectory: true)

    XCTAssertThrowsError(
      try ModelStore.placeDownloadedFile(
        from: source, fileName: "model.litertlm", expectedSize: 1024, in: models)
    ) { error in
      XCTAssertEqual(
        error as? ModelStoreError, .sizeMismatch(expected: 1024, actual: 100))
    }
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: models.appendingPathComponent("model.litertlm").path))
  }

  func testPlaceDownloadedFileMissingSourceThrows() throws {
    let models = scratch.appendingPathComponent("Models", isDirectory: true)
    XCTAssertThrowsError(
      try ModelStore.placeDownloadedFile(
        from: scratch.appendingPathComponent("gone.tmp"),
        fileName: "model.litertlm", expectedSize: 10, in: models))
  }

  func testPlaceDownloadedFileReplacesExisting() throws {
    let models = scratch.appendingPathComponent("Models", isDirectory: true)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    try Data(repeating: 0x00, count: 5).write(
      to: models.appendingPathComponent("model.litertlm"))
    let source = scratch.appendingPathComponent("new.tmp")
    try Data(repeating: 0xFF, count: 8).write(to: source)

    let placed = try ModelStore.placeDownloadedFile(
      from: source, fileName: "model.litertlm", expectedSize: 8, in: models)
    let data = try Data(contentsOf: placed)
    XCTAssertEqual(data, Data(repeating: 0xFF, count: 8))
  }

  // MARK: - Download hygiene (audit #9)

  func testModelsDirectoryIsExcludedFromBackup() throws {
    let dir = try ModelStore.modelsDirectory()
    let values = try dir.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
  }

  /// The first load writes the engine cache beside the file (2.4 GB per context size for
  /// E4B on Google's binary): a download that leaves no room for it can't be used.
  func testStorageCheckCountsTheEngineCache() {
    let spec = ModelCatalog.e4b
    XCTAssertTrue(ModelStore.hasRoom(for: spec, availableBytes: nil))
    let needed = spec.sizeBytes + spec.engineCacheBytes + ModelStore.storageMargin
    XCTAssertTrue(ModelStore.hasRoom(for: spec, availableBytes: needed))
    XCTAssertFalse(ModelStore.hasRoom(for: spec, availableBytes: needed - 1))
    XCTAssertFalse(
      ModelStore.hasRoom(for: spec, availableBytes: spec.sizeBytes + ModelStore.storageMargin))
  }

  /// The right size isn't enough: a file whose bytes differ is removed, not used.
  func testPlaceDownloadedFileChecksTheSHA256() throws {
    let models = scratch.appendingPathComponent("Models", isDirectory: true)
    let data = Data("model bytes".utf8)
    let good = scratch.appendingPathComponent("good.tmp")
    try data.write(to: good)
    let digest = try ModelStore.sha256(of: good)
    try ModelStore.placeDownloadedFile(
      from: good, fileName: "model.litertlm", expectedSize: Int64(data.count),
      expectedSHA256: digest, in: models)

    let swapped = scratch.appendingPathComponent("swapped.tmp")
    try Data("MODEL BYTES".utf8).write(to: swapped)
    XCTAssertThrowsError(
      try ModelStore.placeDownloadedFile(
        from: swapped, fileName: "model.litertlm", expectedSize: Int64(data.count),
        expectedSHA256: digest, in: models)
    ) { error in
      XCTAssertEqual(error as? ModelStoreError, .checksumMismatch)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: models.appendingPathComponent("model.litertlm").path))
  }

  func testSHA256MatchesAKnownValue() throws {
    let file = scratch.appendingPathComponent("abc.txt")
    try Data("abc".utf8).write(to: file)
    XCTAssertEqual(
      try ModelStore.sha256(of: file),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  /// A paused download's progress survives a relaunch with its resume data.
  func testResumeDataReportsHowFarTheDownloadGot() throws {
    let plist: [String: Any] = ["NSURLSessionResumeBytesReceived": NSNumber(value: Int64(915_181_568))]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
    XCTAssertEqual(
      ModelStore.progress(ofResumeData: data, size: ModelCatalog.e4b.sizeBytes), 0.25, accuracy: 0.001)
    XCTAssertEqual(ModelStore.progress(ofResumeData: Data("junk".utf8), size: 100), 0)
  }

  func testErrorPagesAreRejected() throws {
    let url = ModelCatalog.e4b.downloadURL
    let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
    let missing = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)
    XCTAssertNoThrow(try ModelStore.validateResponse(ok))
    XCTAssertThrowsError(try ModelStore.validateResponse(missing)) { error in
      XCTAssertEqual(error as? ModelStoreError, .httpStatus(404))
    }
  }

  /// After the switch to E4B only, the old E2B file (2.6 GB) must be removed.
  @MainActor
  func testRetiredModelFilesAreRemoved() throws {
    let retired = try ModelStore.modelsDirectory().appendingPathComponent("gemma-4-E2B-it.litertlm")
    try Data(repeating: 0, count: 16).write(to: retired)
    _ = ModelStore()
    XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
  }
}
