import Foundation
import XCTest

@testable import Agello

/// Regression tests for Wave 1 P0-19 (`ModelStore` pause/cancel/verify/failed state machine)
/// and P0-20 (`AutomationRegistry` slug collision detection & emoji-only deduplication).
final class Wave1RegressionTests: XCTestCase {
  private var scratch: URL!
  private var defaultsSuiteName: String!
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    try super.setUpWithError()
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("Wave1RegressionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defaultsSuiteName = "Wave1RegressionTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
  }

  override func tearDownWithError() throws {
    if let suite = defaultsSuiteName {
      defaults?.removePersistentDomain(forName: suite)
    }
    if let scratch {
      try? FileManager.default.removeItem(at: scratch)
    }
    try super.tearDownWithError()
  }

  // MARK: - ModelStore P0-19 state machine

  @MainActor
  private func makeIsolatedStore() -> ModelStore {
    let modelsDir = scratch.appendingPathComponent("Models", isDirectory: true)
    try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
    return ModelStore(modelsDirectoryOverride: modelsDir, defaults: defaults, usesBackgroundSession: false)
  }

  private func makeResumeData(bytesReceived: Int64) throws -> Data {
    let plist: [String: Any] = ["NSURLSessionResumeBytesReceived": NSNumber(value: bytesReceived)]
    return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
  }

  @MainActor
  func testPauseThenCancelCannotResurrectPausedState() async throws {
    let store = makeIsolatedStore()
    let spec = ModelCatalog.e4b
    var pendingPauseCallback: (@Sendable (Data?) -> Void)?

    store.downloadLauncher = { _, _, _, _ in }
    store.pauseHandler = { _, completion in
      pendingPauseCallback = completion
    }

    store.startDownload(spec)
    XCTAssertEqual(store.states[spec.id], .downloading(progress: 0))

    store.pauseDownload(spec)
    XCTAssertTrue(store.isPausing(spec.id))
    XCTAssertTrue(store.isPausing(spec.id.rawValue))
    if case .paused = store.states[spec.id] {
      // Expected
    } else {
      XCTFail("Expected .paused immediately after pauseDownload, got \(String(describing: store.states[spec.id]))")
    }

    // Cancel BEFORE the async URLSession pause callback delivers resumeData.
    store.cancelDownload(spec)
    XCTAssertFalse(store.isPausing(spec.id))
    XCTAssertEqual(store.states[spec.id], .notDownloaded)

    // Delayed resumeData lands after Cancel: must be ignored and never resurrect .paused.
    let resumeBytes = try makeResumeData(bytesReceived: spec.sizeBytes / 2)
    let callback = try XCTUnwrap(pendingPauseCallback)
    callback(resumeBytes)
    await Task.yield()
    await Task.yield()

    XCTAssertFalse(store.isPausing(spec.id))
    XCTAssertEqual(store.states[spec.id], .notDownloaded)
    store.refreshStates()
    XCTAssertEqual(store.states[spec.id], .notDownloaded)
  }

  @MainActor
  func testPauseThenImmediateResumeWaitsForResumeDataWithoutRestartingFromZero() async throws {
    let store = makeIsolatedStore()
    let spec = ModelCatalog.e4b
    var launches: [(resumeData: Data?, overCellular: Bool)] = []
    var pendingPauseCallback: (@Sendable (Data?) -> Void)?

    store.downloadLauncher = { _, saved, cellular, _ in
      launches.append((saved, cellular))
    }
    store.pauseHandler = { _, completion in
      pendingPauseCallback = completion
    }

    store.startDownload(spec, overCellular: true)
    XCTAssertEqual(launches.count, 1)
    XCTAssertNil(launches[0].resumeData)

    store.pauseDownload(spec)
    XCTAssertTrue(store.isPausing(spec.id))

    // Tap Resume immediately while pause is still producing resumeData.
    store.startDownload(spec, overCellular: true)
    // Must NOT restart from 0% before resumeData arrives.
    XCTAssertEqual(launches.count, 1)

    // Pause finishes and delivers resumeData -> queued Resume launches WITH that resumeData.
    let resumeBytes = try makeResumeData(bytesReceived: spec.sizeBytes / 4)
    let callback = try XCTUnwrap(pendingPauseCallback)
    callback(resumeBytes)
    await Task.yield()
    await Task.yield()

    XCTAssertFalse(store.isPausing(spec.id))
    XCTAssertEqual(launches.count, 2)
    XCTAssertEqual(launches[1].resumeData, resumeBytes)
    if case .downloading(let progress) = store.states[spec.id] {
      XCTAssertEqual(progress, 0.25, accuracy: 0.01)
    } else {
      XCTFail("Expected .downloading after deferred resume, got \(String(describing: store.states[spec.id]))")
    }
  }

  @MainActor
  func testCancelDuringVerificationAbortsCleanlyAndNeverMarksReady() throws {
    let store = makeIsolatedStore()
    let spec = ModelCatalog.e4b
    var capturedToken: UUID?
    var readyCallbacks: [ModelID] = []

    store.onModelReady = { readyCallbacks.append($0) }
    store.downloadLauncher = { _, _, _, description in
      capturedToken = ModelStore.parseTaskDescription(description)?.token
    }

    store.startDownload(spec)
    let token = try XCTUnwrap(capturedToken)

    XCTAssertTrue(store.beginVerification(for: spec, token: token))
    XCTAssertTrue(store.isVerifying(spec.id))
    XCTAssertTrue(store.isVerifying(spec.id.rawValue))

    // Pausing during SHA-256 verification must be a safe no-op.
    store.pauseDownload(spec)
    XCTAssertTrue(store.isVerifying(spec.id))

    // Cancelling during verification invalidates the token and clears verifying state.
    store.cancelDownload(spec)
    XCTAssertFalse(store.isVerifying(spec.id))
    XCTAssertTrue(store.isTokenCancelled(token))
    XCTAssertEqual(store.states[spec.id], .notDownloaded)

    // Even if a file landed right at the race boundary, late publishVerification must abort & clean up.
    if let finalURL = store.localURL(for: spec) {
      try Data(repeating: 0xAA, count: 16).write(to: finalURL)
    }
    store.publishVerification(for: spec, token: token, error: nil, cancelled: false)

    XCTAssertEqual(store.states[spec.id], .notDownloaded)
    XCTAssertTrue(readyCallbacks.isEmpty)
    if let finalURL = store.localURL(for: spec) {
      XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
    }
  }

  func testInstallStagedFileHonorsCancellationAndRemovesStagedFile() throws {
    let models = scratch.appendingPathComponent("VerifyCancel", isDirectory: true)
    let source = scratch.appendingPathComponent("download.tmp")
    let payload = Data(repeating: 0x42, count: 1024)
    try payload.write(to: source)
    let staged = try ModelStore.stageDownloadedFile(from: source, fileName: "model.litertlm", in: models)
    let expectedHash = try ModelStore.sha256(of: staged)

    XCTAssertThrowsError(
      try ModelStore.installStagedFile(
        staged, fileName: "model.litertlm", expectedSize: Int64(payload.count),
        expectedSHA256: expectedHash, in: models, isCancelled: { true })
    ) { error in
      XCTAssertTrue(error is CancellationError, "Expected CancellationError, got \(error)")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: models.appendingPathComponent("model.litertlm").path))
  }

  @MainActor
  func testRefreshStatesPreservesFailedState() throws {
    let store = makeIsolatedStore()
    let spec = ModelCatalog.e4b
    var capturedToken: UUID?

    store.downloadLauncher = { _, _, _, description in
      capturedToken = ModelStore.parseTaskDescription(description)?.token
    }

    store.startDownload(spec)
    let token = try XCTUnwrap(capturedToken)
    store.beginVerification(for: spec, token: token)
    store.publishVerification(for: spec, token: token, error: ModelStoreError.checksumMismatch)

    let expectedError = ModelStoreError.checksumMismatch.localizedDescription
    XCTAssertEqual(store.states[spec.id], .failed(message: expectedError))

    // Returning to ModelLibraryView calls refreshStates(); .failed must NOT be clobbered.
    store.refreshStates()
    XCTAssertEqual(store.states[spec.id], .failed(message: expectedError))
  }

  // MARK: - AutomationRegistry P0-20 slug collision & deduplication

  func testSlugIsDeterministicForEmojiOnlyNamesAndDistinct() {
    let first = RegisteredShortcut.slug(from: "⚡️🏠")
    let second = RegisteredShortcut.slug(from: "⚡️🏠")
    let different = RegisteredShortcut.slug(from: "🚀")

    XCTAssertFalse(first.isEmpty)
    XCTAssertEqual(first, second)
    XCTAssertNotEqual(first, different)
  }

  func testRegisterRejectsEmptyDuplicateAndSlugCollisionWithoutOverwriting() throws {
    let registry = AutomationRegistry(defaults: defaults)

    XCTAssertThrowsError(try registry.register(RegisteredShortcut(name: "   ", summary: ""))) { error in
      XCTAssertEqual(error as? AutomationRegistry.RegistrationError, .emptyName)
    }

    let original = try registry.register(RegisteredShortcut(name: "Work: Notes", summary: "Original"))
    XCTAssertEqual(original.id, "work_notes")
    XCTAssertEqual(registry.shortcuts.count, 1)

    // Case-insensitive duplicate name rejected.
    XCTAssertThrowsError(
      try registry.register(RegisteredShortcut(name: "work: notes", summary: "Duplicate"))
    ) { error in
      XCTAssertEqual(error as? AutomationRegistry.RegistrationError, .duplicateName(existing: "Work: Notes"))
    }

    // Distinct name that folds to the same slug rejected instead of silently overwriting.
    XCTAssertThrowsError(
      try registry.register(RegisteredShortcut(name: "Work - Notes", summary: "Colliding"))
    ) { error in
      XCTAssertEqual(error as? AutomationRegistry.RegistrationError, .slugCollision(existing: "Work: Notes"))
    }
    XCTAssertEqual(registry.shortcuts.count, 1)
    XCTAssertEqual(registry.shortcuts.first?.summary, "Original")

    // Long names sharing the first 40 slug chars also report a collision instead of overwriting.
    let prefix = String(repeating: "a", count: 40)
    _ = try registry.register(RegisteredShortcut(name: "\(prefix) one", summary: "First long"))
    XCTAssertThrowsError(
      try registry.register(RegisteredShortcut(name: "\(prefix) two", summary: "Second long"))
    ) { error in
      XCTAssertEqual(
        error as? AutomationRegistry.RegistrationError, .slugCollision(existing: "\(prefix) one"))
    }
  }

  func testRegisterPreventsDuplicateEmojiOnlyShortcuts() throws {
    let registry = AutomationRegistry(defaults: defaults)

    let first = try registry.register(RegisteredShortcut(name: "⚡️🏠", summary: "Home"))
    XCTAssertFalse(first.id.isEmpty)
    XCTAssertThrowsError(
      try registry.register(RegisteredShortcut(name: "⚡️🏠", summary: "Duplicate home"))
    ) { error in
      XCTAssertEqual(error as? AutomationRegistry.RegistrationError, .duplicateName(existing: "⚡️🏠"))
    }
    XCTAssertEqual(registry.shortcuts.count, 1)

    _ = try registry.register(RegisteredShortcut(name: "🚀", summary: "Launch"))
    XCTAssertEqual(registry.shortcuts.count, 2)
  }

  func testUpsertDisambiguatesCollidingSlugsAndDeduplicatesEmojiNames() {
    let registry = AutomationRegistry(defaults: defaults)

    registry.upsert(RegisteredShortcut(name: "Work: Notes", summary: "First"))
    registry.upsert(RegisteredShortcut(name: "Work - Notes", summary: "Second"))
    XCTAssertEqual(registry.shortcuts.count, 2)
    XCTAssertEqual(registry.shortcuts[0].name, "Work: Notes")
    XCTAssertEqual(registry.shortcuts[1].name, "Work - Notes")
    XCTAssertNotEqual(registry.shortcuts[0].id, registry.shortcuts[1].id)

    // Updating an existing item in place (e.g. toggling enabled) keeps its ID and count.
    var toggled = registry.shortcuts[0]
    toggled.enabled = false
    registry.upsert(toggled)
    XCTAssertEqual(registry.shortcuts.count, 2)
    XCTAssertEqual(registry.shortcuts[0].enabled, false)

    // Emoji-only upserts deduplicate rather than appending random-UUID duplicates.
    registry.upsert(RegisteredShortcut(name: "⚡️🏠", summary: "V1"))
    registry.upsert(RegisteredShortcut(name: "⚡️🏠", summary: "V2"))
    let emojiEntries = registry.shortcuts.filter { $0.name == "⚡️🏠" }
    XCTAssertEqual(emojiEntries.count, 1)
    XCTAssertEqual(emojiEntries.first?.summary, "V2")
  }
}
