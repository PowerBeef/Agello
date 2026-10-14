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

  func testStorageCheckRequiresFileSizePlusMargin() {
    let spec = ModelCatalog.e4b
    XCTAssertTrue(ModelStore.hasRoom(for: spec, availableBytes: nil))
    XCTAssertTrue(
      ModelStore.hasRoom(for: spec, availableBytes: spec.sizeBytes + ModelStore.storageMargin))
    XCTAssertFalse(ModelStore.hasRoom(for: spec, availableBytes: spec.sizeBytes))
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
