import AppleArchive
import System
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

  /// The final name appears only once the file is verified: a staged download, or one that fails
  /// its check, never sits there (2026-11-16).
  func testOnlyAVerifiedFileGetsItsFinalName() throws {
    let models = scratch.appendingPathComponent("Models", isDirectory: true)
    let final = models.appendingPathComponent("model.litertlm")
    let good = Data(repeating: 0xAB, count: 64)
    let source = scratch.appendingPathComponent("download.tmp")
    try good.write(to: source)
    let staged = try ModelStore.stageDownloadedFile(from: source, fileName: "model.litertlm", in: models)
    XCTAssertEqual(staged.lastPathComponent, "model.litertlm.partial")
    XCTAssertFalse(FileManager.default.fileExists(atPath: final.path))
    let hash = try ModelStore.sha256(of: staged)
    try ModelStore.installStagedFile(staged, fileName: "model.litertlm", expectedSize: 64, expectedSHA256: hash, in: models)
    XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))

    // A wrong file at the right size leaves the verified one in place and no staged copy.
    try Data(repeating: 0xCD, count: 64).write(to: source)
    let bad = try ModelStore.stageDownloadedFile(from: source, fileName: "model.litertlm", in: models)
    XCTAssertThrowsError(
      try ModelStore.installStagedFile(bad, fileName: "model.litertlm", expectedSize: 64, expectedSHA256: hash, in: models))
    XCTAssertEqual(try Data(contentsOf: final), good)
    XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
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

  /// The first load writes the engine cache beside the file (about 2.4 GB for E4B): a download
  /// that leaves no room for it can't be used.
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
    // The swapped file never reaches the final name; the verified copy stays (since 2026-11-16).
    XCTAssertEqual(try Data(contentsOf: models.appendingPathComponent("model.litertlm")), data)
    XCTAssertFalse(FileManager.default.fileExists(atPath: models.appendingPathComponent("model.litertlm.partial").path))
  }

  func testSHA256MatchesAKnownValue() throws {
    let file = scratch.appendingPathComponent("abc.txt")
    try Data("abc".utf8).write(to: file)
    XCTAssertEqual(
      try ModelStore.sha256(of: file),
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  /// A paused download's progress survives a relaunch with its resume data.
  /// Resume data replays its request's network policy: "Wait for Wi-Fi" holds it on a metered
  /// network, and "Download now" restarts a Wi-Fi-only one there (2026-11-16).
  func testResumeFollowsTheChosenNetworkPolicy() {
    typealias A = ModelStore.ResumeAction
    let cases: [(wants: Bool, allows: Bool, expensive: Bool, expected: A)] = [
      (true, true, false, .resume), (true, false, false, .resume),
      (false, true, false, .resume), (false, false, false, .resume),
      (false, true, true, .hold), (false, false, true, .hold),
      (true, true, true, .resume), (true, false, true, .restart),
    ]
    for c in cases {
      XCTAssertEqual(
        ModelStore.resumeAction(wantsCellular: c.wants, resumeAllowsCellular: c.allows, onExpensiveNetwork: c.expensive),
        c.expected, "wants \(c.wants), allows \(c.allows), expensive \(c.expensive)")
    }
  }

  func testResumeDataReportsHowFarTheDownloadGot() throws {
    let plist: [String: Any] = ["NSURLSessionResumeBytesReceived": NSNumber(value: ModelCatalog.e4b.sizeBytes / 4)]
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

  /// An Apple Archive download verifies size + SHA-256 first, extracts atomically into its target
  /// directory, removes the staged `.partial`, and leaves any verified bundle untouched on failure.
  func testAppleArchiveBundleVerifiesAndExtractsAtomically() throws {
    let sourceDir = scratch.appendingPathComponent("bundle-src", isDirectory: true)
    let nested = sourceDir.appendingPathComponent("text_encoder.aimodel", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try Data("mlirb-payload".utf8).write(to: nested.appendingPathComponent("main.mlirb"))
    try Data("table-payload".utf8).write(to: sourceDir.appendingPathComponent("embed_tokens.bin"))
    try Data("tok-payload".utf8).write(to: sourceDir.appendingPathComponent("tokenizer.model"))

    let archiveURL = scratch.appendingPathComponent("bundle.aar")
    try Self.writeTestAppleArchive(from: sourceDir, to: archiveURL)
    let archiveSize = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: archiveURL.path)[.size] as? Int64)
    let archiveHash = try ModelStore.sha256(of: archiveURL)

    let models = scratch.appendingPathComponent("Models", isDirectory: true)
    let installed = try ModelStore.placeDownloadedFile(
      from: archiveURL,
      fileName: "embeddinggemma-2-text-270m-ane.aar",
      expectedSize: archiveSize,
      expectedSHA256: archiveHash,
      extractToDirectoryName: CoreAIEmbedder.bundleDirectoryName,
      validateExtractedDirectory: { CoreAIEmbedder.isAvailable(at: $0) },
      in: models)

    XCTAssertEqual(installed.lastPathComponent, CoreAIEmbedder.bundleDirectoryName)
    XCTAssertTrue(CoreAIEmbedder.isAvailable(at: installed))
    XCTAssertEqual(
      try Data(contentsOf: installed.appendingPathComponent("text_encoder.aimodel/main.mlirb")),
      Data("mlirb-payload".utf8))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: models.appendingPathComponent("embeddinggemma-2-text-270m-ane.aar.partial").path))

    // A corrupt archive with matching size + hash still fails extraction without clobbering.
    let junk = scratch.appendingPathComponent("junk.aar")
    try Data("not-an-apple-archive".utf8).write(to: junk)
    let junkHash = try ModelStore.sha256(of: junk)
    XCTAssertThrowsError(
      try ModelStore.placeDownloadedFile(
        from: junk,
        fileName: "embeddinggemma-2-text-270m-ane.aar",
        expectedSize: 20,
        expectedSHA256: junkHash,
        extractToDirectoryName: CoreAIEmbedder.bundleDirectoryName,
        validateExtractedDirectory: { CoreAIEmbedder.isAvailable(at: $0) },
        in: models)
    ) { error in
      XCTAssertEqual(error as? ModelStoreError, .archiveExtractionFailed)
    }
    XCTAssertTrue(CoreAIEmbedder.isAvailable(at: installed))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: models.appendingPathComponent("\(CoreAIEmbedder.bundleDirectoryName).extracting").path))
  }

  private static func writeTestAppleArchive(from sourceDir: URL, to archiveURL: URL) throws {
    let destPath = try XCTUnwrap(FilePath(archiveURL))
    let srcPath = try XCTUnwrap(FilePath(sourceDir))
    let writeStream = try XCTUnwrap(
      ArchiveByteStream.fileStream(
        path: destPath, mode: .writeOnly, options: [.create, .truncate],
        permissions: FilePermissions(rawValue: 0o644)))
    defer { try? writeStream.close() }
    let compressStream = try XCTUnwrap(
      ArchiveByteStream.compressionStream(using: .lzfse, writingTo: writeStream))
    defer { try? compressStream.close() }
    let encodeStream = try XCTUnwrap(ArchiveStream.encodeStream(writingTo: compressStream))
    defer { try? encodeStream.close() }
    let keySet = try XCTUnwrap(ArchiveHeader.FieldKeySet("TYP,PAT,MOD,DAT,SIZ"))
    try encodeStream.writeDirectoryContents(archiveFrom: srcPath, keySet: keySet)
  }
}
