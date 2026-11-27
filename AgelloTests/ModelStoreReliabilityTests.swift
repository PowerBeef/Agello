import Foundation
import XCTest

@testable import Agello

/// Regression tests for background download reliability (`RT-P0-11`) and revision-keyed /
/// relaunch-safe `.resume` persistence (`RT-P1-19`).
final class ModelStoreReliabilityTests: XCTestCase {
  private var scratch: URL!
  private var modelsDir: URL!
  private var defaultsSuiteName: String!
  private var defaults: UserDefaults!

  override func setUpWithError() throws {
    try super.setUpWithError()
    scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("ModelStoreReliabilityTests-\(UUID().uuidString)", isDirectory: true)
    modelsDir = scratch.appendingPathComponent("Models", isDirectory: true)
    try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
    defaultsSuiteName = "ModelStoreReliabilityTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
  }

  override func tearDown() async throws {
    await MainActor.run { BackgroundDownloads.resetForTesting() }
    if let suite = defaultsSuiteName {
      defaults?.removePersistentDomain(forName: suite)
    }
    if let scratch {
      try? FileManager.default.removeItem(at: scratch)
    }
    try await super.tearDown()
  }

  private func makeTestSpec(
    id: ModelID = .e4b,
    fileName: String = "test-model.litertlm",
    payload: Data,
    revision: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  ) throws -> (spec: ModelSpec, sourceFile: URL) {
    let source = scratch.appendingPathComponent("download-\(UUID().uuidString).tmp")
    try payload.write(to: source)
    let digest = try ModelStore.sha256(of: source)
    let spec = ModelSpec(
      id: id,
      displayName: "Test Model",
      tagline: "Unit test fixture",
      repo: "PowerBeef02/test-model",
      fileName: fileName,
      sizeBytes: Int64(payload.count),
      revision: revision,
      sha256: digest,
      engineCacheBytes: 0
    )
    return (spec, source)
  }

  private func makeResumeData(
    bytesReceived: Int64, downloadURL: URL?, originalRequest: NSURLRequest? = nil
  ) throws -> Data {
    var plist: [String: Any] = ["NSURLSessionResumeBytesReceived": NSNumber(value: bytesReceived)]
    if let downloadURL {
      plist["NSURLSessionDownloadURL"] = downloadURL.absoluteString
    }
    if let originalRequest {
      plist["NSURLSessionResumeOriginalRequest"] = try NSKeyedArchiver.archivedData(
        withRootObject: originalRequest, requiringSecureCoding: true)
    }
    return try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
  }

  private func makeNetworkError(resumeData: Data?) -> NSError {
    var userInfo: [String: Any] = [NSLocalizedDescriptionKey: "The network connection was lost."]
    if let resumeData {
      userInfo[NSURLSessionDownloadTaskResumeData] = resumeData
    }
    return NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: userInfo)
  }

  @MainActor
  private func waitUntil(
    timeout: Duration = .seconds(5),
    condition: @MainActor () -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  // MARK: - RT-P0-11: Deferred completionHandler & active-staging protection

  @MainActor
  func testBackgroundCompletionHandlerWaitsForVerificationAndPublish() async throws {
    let payload = Data(repeating: 0x5A, count: 2048)
    let (spec, source) = try makeTestSpec(payload: payload)
    let store = ModelStore(
      modelsDirectoryOverride: modelsDir, defaults: defaults,
      usesBackgroundSession: false, catalog: [spec])

    var completionCalls = 0
    BackgroundDownloads.completionHandler = { completionCalls += 1 }
    XCTAssertTrue(BackgroundDownloads.hasActiveBackgroundTask)

    let enteredInstall = DispatchSemaphore(value: 0)
    let allowInstall = DispatchSemaphore(value: 0)
    let response = HTTPURLResponse(
      url: spec.downloadURL, statusCode: 200, httpVersion: nil, headerFields: nil)

    ModelStore.finishDownload(
      ModelStore.DownloadTarget(spec: spec, token: nil, directory: modelsDir),
      response: response, at: source, store: store
    ) {
      enteredInstall.signal()
      _ = allowInstall.wait(timeout: .now() + 5)
    }

    XCTAssertEqual(enteredInstall.wait(timeout: .now() + 5), .success)

    // System notifies that all URLSession events were delivered while SHA-256 is still running.
    BackgroundDownloads.handleSessionDidFinishEvents()
    try? await Task.sleep(for: .milliseconds(40))

    XCTAssertEqual(completionCalls, 0, "completionHandler must wait until verification finishes")
    XCTAssertTrue(BackgroundDownloads.hasActiveBackgroundTask)

    // Release verification: publishVerification completes, then completionHandler fires once.
    allowInstall.signal()
    let finished = await waitUntil { completionCalls == 1 && store.states[spec.id] == .ready }
    XCTAssertTrue(finished)
    XCTAssertEqual(completionCalls, 1)
    XCTAssertTrue(store.isDownloaded(spec))
    XCTAssertFalse(BackgroundDownloads.hasActiveBackgroundTask)
    XCTAssertTrue(BackgroundDownloads.coordinator.activeFiles(in: modelsDir).isEmpty)
  }

  @MainActor
  func testBackgroundCompletionHandlerWaitsForSessionEventsWhenVerificationFinishesFirst() async throws {
    let payload = Data(repeating: 0x33, count: 1024)
    let (spec, source) = try makeTestSpec(payload: payload)
    let store = ModelStore(
      modelsDirectoryOverride: modelsDir, defaults: defaults,
      usesBackgroundSession: false, catalog: [spec])

    var completionCalls = 0
    BackgroundDownloads.completionHandler = { completionCalls += 1 }

    let response = HTTPURLResponse(
      url: spec.downloadURL, statusCode: 200, httpVersion: nil, headerFields: nil)
    ModelStore.finishDownload(
      ModelStore.DownloadTarget(spec: spec, token: nil, directory: modelsDir),
      response: response, at: source, store: store)

    let verified = await waitUntil { store.states[spec.id] == .ready }
    XCTAssertTrue(verified)
    XCTAssertEqual(
      completionCalls, 0,
      "completionHandler must not fire before urlSessionDidFinishEvents(forBackgroundURLSession:)")

    BackgroundDownloads.handleSessionDidFinishEvents()
    let completed = await waitUntil { completionCalls == 1 }
    XCTAssertTrue(completed)
    XCTAssertEqual(completionCalls, 1)
    XCTAssertFalse(BackgroundDownloads.hasActiveBackgroundTask)
  }

  @MainActor
  func testBackgroundFinishInstallsAndFlushesCompletionWhenStoreIsNil() async throws {
    let payload = Data(repeating: 0x77, count: 1536)
    let (spec, source) = try makeTestSpec(payload: payload)

    // Pre-seed a stale resume file to verify background install clears it even with store == nil.
    let resume = try makeResumeData(bytesReceived: 512, downloadURL: spec.downloadURL)
    ModelStore.persistResumeData(resume, for: spec, in: modelsDir)
    let resumeFile = modelsDir.appendingPathComponent(ModelStore.resumeFileName(for: spec))
    XCTAssertTrue(FileManager.default.fileExists(atPath: resumeFile.path))

    var completionCalls = 0
    BackgroundDownloads.completionHandler = { completionCalls += 1 }

    let enteredInstall = DispatchSemaphore(value: 0)
    let allowInstall = DispatchSemaphore(value: 0)
    let response = HTTPURLResponse(
      url: spec.downloadURL, statusCode: 200, httpVersion: nil, headerFields: nil)

    ModelStore.finishDownload(
      ModelStore.DownloadTarget(spec: spec, token: nil, directory: modelsDir),
      response: response, at: source, store: nil
    ) {
      enteredInstall.signal()
      _ = allowInstall.wait(timeout: .now() + 5)
    }

    XCTAssertEqual(enteredInstall.wait(timeout: .now() + 5), .success)
    BackgroundDownloads.handleSessionDidFinishEvents()
    try? await Task.sleep(for: .milliseconds(40))
    XCTAssertEqual(completionCalls, 0)

    allowInstall.signal()
    let completed = await waitUntil { completionCalls == 1 }
    XCTAssertTrue(completed)

    let installed = modelsDir.appendingPathComponent(spec.fileName)
    XCTAssertEqual(try Data(contentsOf: installed), payload)
    XCTAssertFalse(FileManager.default.fileExists(atPath: resumeFile.path))
    XCTAssertFalse(BackgroundDownloads.hasActiveBackgroundTask)
  }

  @MainActor
  func testActiveStagingProtectsPartialFileBeforeBeginVerificationRuns() async throws {
    let payload = Data(repeating: 0x91, count: 2048)
    let (spec, source) = try makeTestSpec(payload: payload)
    let store = ModelStore(
      modelsDirectoryOverride: modelsDir, defaults: defaults,
      usesBackgroundSession: false, catalog: [spec])

    let allowInstall = DispatchSemaphore(value: 0)
    let response = HTTPURLResponse(
      url: spec.downloadURL, statusCode: 200, httpVersion: nil, headerFields: nil)

    // Run `finishDownload` synchronously, then immediately invoke `refreshStates()` BEFORE
    // yielding to `@MainActor` so `beginVerification` has not populated `verifyingIDs` yet.
    ModelStore.finishDownload(
      ModelStore.DownloadTarget(spec: spec, token: nil, directory: modelsDir),
      response: response, at: source, store: store
    ) {
      _ = allowInstall.wait(timeout: .now() + 5)
    }

    let stagedURL = modelsDir.appendingPathComponent(ModelStore.stagedName(spec.fileName))
    XCTAssertFalse(store.isVerifying(spec.id))
    XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
    XCTAssertTrue(
      BackgroundDownloads.coordinator.activeFiles(in: modelsDir).contains(stagedURL.lastPathComponent))

    // Simulates `.onAppear` / cold-launch `refreshStates()` -> `removeUnknownModelFiles()`.
    store.refreshStates()
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: stagedURL.path),
      "Active staged .partial must survive removeUnknownModelFiles() before beginVerification runs")
    XCTAssertEqual(store.states[spec.id], .downloading(progress: 1))

    allowInstall.signal()
    let ready = await waitUntil { store.states[spec.id] == .ready }
    XCTAssertTrue(ready)
    XCTAssertEqual(try Data(contentsOf: modelsDir.appendingPathComponent(spec.fileName)), payload)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
  }

  @MainActor
  func testRelaunchResumesVerificationOfSizeMatchingPartialAndCleansCorruptOrTruncated() async throws {
    let payload = Data(repeating: 0x4C, count: 2048)
    let (spec, _) = try makeTestSpec(payload: payload)
    let stagedURL = modelsDir.appendingPathComponent(ModelStore.stagedName(spec.fileName))

    // 1. Valid size-matching `.partial` left behind after background termination: relaunch recovers it.
    try payload.write(to: stagedURL)
    let recoveredStore = ModelStore(
      modelsDirectoryOverride: modelsDir, defaults: defaults,
      usesBackgroundSession: false, catalog: [spec])
    XCTAssertTrue(recoveredStore.isVerifying(spec.id))
    let recovered = await waitUntil { recoveredStore.states[spec.id] == .ready }
    XCTAssertTrue(recovered)
    XCTAssertEqual(try Data(contentsOf: modelsDir.appendingPathComponent(spec.fileName)), payload)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))

    // Remove installed file and test a size-matching CORRUPT `.partial`: fails cleanly and unlinks.
    try FileManager.default.removeItem(at: modelsDir.appendingPathComponent(spec.fileName))
    try Data(repeating: 0xEE, count: payload.count).write(to: stagedURL)
    let corruptStore = ModelStore(
      modelsDirectoryOverride: modelsDir, defaults: defaults,
      usesBackgroundSession: false, catalog: [spec])
    let failed = await waitUntil {
      if case .failed = corruptStore.states[spec.id] { return true }
      return false
    }
    XCTAssertTrue(failed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
    corruptStore.refreshStates()
    if case .failed = corruptStore.states[spec.id] {
      // Expected: stays failed and does not re-enter verification.
    } else {
      XCTFail("Expected .failed to persist after corrupt .partial cleanup")
    }

    // 3. Truncated (wrong-size) `.partial`: deleted immediately on refresh.
    try Data(repeating: 0x11, count: 64).write(to: stagedURL)
    let truncatedStore = ModelStore(
      modelsDirectoryOverride: modelsDir, defaults: defaults,
      usesBackgroundSession: false, catalog: [spec])
    XCTAssertEqual(truncatedStore.states[spec.id], .notDownloaded)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
  }

  // MARK: - RT-P1-19: Revision-keyed .resume files & relaunch-safe didCompleteWithError

  @MainActor
  func testResumeDataInvalidatesAcrossCatalogRevisionAndStaleURLMismatch() async throws {
    let payload = Data(repeating: 0x22, count: 2048)
    let (specV1, _) = try makeTestSpec(
      fileName: "model-v1.litertlm", payload: payload,
      revision: "1111111111111111111111111111111111111111")
    let (specV2, _) = try makeTestSpec(
      fileName: "model-v2.litertlm", payload: payload,
      revision: "2222222222222222222222222222222222222222")

    let resumeV1 = try makeResumeData(bytesReceived: 1024, downloadURL: specV1.downloadURL)
    let storeV1 = ModelStore(
      modelsDirectoryOverride: modelsDir, defaults: defaults,
      usesBackgroundSession: false, catalog: [specV1])
    storeV1.keepResumeData(resumeV1, for: specV1.id)
    let fileV1 = modelsDir.appendingPathComponent(ModelStore.resumeFileName(for: specV1))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileV1.path))

    // Also plant a legacy unkeyed `e4b.resume` file to verify it is cleaned up.
    let legacyResume = modelsDir.appendingPathComponent("\(specV1.id.rawValue).resume")
    try resumeV1.write(to: legacyResume)

    // Catalog updates to v2: stale v1 and legacy `.resume` files are ignored and deleted.
    let storeV2 = ModelStore(
      modelsDirectoryOverride: modelsDir, defaults: defaults,
      usesBackgroundSession: false, catalog: [specV2])
    XCTAssertEqual(storeV2.states[specV2.id], .notDownloaded)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileV1.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyResume.path))

    // Even if a `.resume` sits at v2's keyed filename, a mismatched NSURLSessionDownloadURL is rejected.
    let fileV2 = modelsDir.appendingPathComponent(ModelStore.resumeFileName(for: specV2))
    try resumeV1.write(to: fileV2)
    let storeV2Reloaded = ModelStore(
      modelsDirectoryOverride: modelsDir, defaults: defaults,
      usesBackgroundSession: false, catalog: [specV2])
    XCTAssertEqual(storeV2Reloaded.states[specV2.id], .notDownloaded)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileV2.path))
  }

  @MainActor
  func testDidCompleteWithErrorPersistsResumeDataWhenStoreIsNilAndOnRelaunch() async throws {
    let payload = Data(repeating: 0x66, count: 4096)
    let (spec, _) = try makeTestSpec(payload: payload)
    let resumeData = try makeResumeData(bytesReceived: 3072, downloadURL: spec.downloadURL)
    let networkError = makeNetworkError(resumeData: resumeData)

    // 1. Background error delivered before ModelStore exists (store == nil) and without taskDescription.
    ModelStore.handleTaskCompletion(
      taskDescription: nil, requestURL: spec.downloadURL, error: networkError,
      in: modelsDir, catalog: [spec], store: nil)

    let resumeFile = modelsDir.appendingPathComponent(ModelStore.resumeFileName(for: spec))
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: resumeFile.path),
      "Resume data must be persisted synchronously even when store == nil")

    let coldStore = ModelStore(
      modelsDirectoryOverride: modelsDir, defaults: defaults,
      usesBackgroundSession: false, catalog: [spec])
    if case .paused(let progress) = coldStore.states[spec.id] {
      XCTAssertEqual(progress, 0.75, accuracy: 0.01)
    } else {
      XCTFail("Expected .paused(0.75) after cold relaunch, got \(String(describing: coldStore.states[spec.id]))")
    }

    // 2. Background error delivered when store exists but downloadingSpec == nil (failed task not reattached).
    try FileManager.default.removeItem(at: resumeFile)
    let relaunchStore = ModelStore(
      modelsDirectoryOverride: modelsDir, defaults: defaults,
      usesBackgroundSession: false, catalog: [spec])
    XCTAssertEqual(relaunchStore.states[spec.id], .notDownloaded)

    var completionCalls = 0
    BackgroundDownloads.completionHandler = { completionCalls += 1 }
    let desc = ModelStore.taskDescription(for: spec.id, token: UUID())
    ModelStore.handleTaskCompletion(
      taskDescription: desc, requestURL: spec.downloadURL, error: networkError,
      in: modelsDir, catalog: [spec], store: relaunchStore)
    BackgroundDownloads.handleSessionDidFinishEvents()

    let handled = await waitUntil { completionCalls == 1 }
    XCTAssertTrue(handled)
    if case .paused(let progress) = relaunchStore.states[spec.id] {
      XCTAssertEqual(progress, 0.75, accuracy: 0.01)
    } else {
      XCTFail("Expected .paused(0.75) on relaunch error, got \(String(describing: relaunchStore.states[spec.id]))")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: resumeFile.path))

    // 3. Resume data pointing to a stale URL is rejected rather than persisted.
    try FileManager.default.removeItem(at: resumeFile)
    let staleURL = try XCTUnwrap(URL(string: "https://huggingface.co/PowerBeef02/old/resolve/deadbeef/old.litertlm"))
    let staleResume = try makeResumeData(bytesReceived: 2048, downloadURL: staleURL)
    let staleError = makeNetworkError(resumeData: staleResume)
    ModelStore.handleTaskCompletion(
      taskDescription: desc, requestURL: spec.downloadURL, error: staleError,
      in: modelsDir, catalog: [spec], store: nil)
    XCTAssertFalse(FileManager.default.fileExists(atPath: resumeFile.path))
  }

  @MainActor
  func testRedirectedResumeDataMatchesOriginalRequestAndResolvesSpec() async throws {
    let payload = Data(repeating: 0x55, count: 4096)
    let (specV1, _) = try makeTestSpec(
      fileName: "model-v1.litertlm", payload: payload,
      revision: "1111111111111111111111111111111111111111")
    let (specV2, _) = try makeTestSpec(
      fileName: "model-v2.litertlm", payload: payload,
      revision: "2222222222222222222222222222222222222222")
    let cdnURL = try XCTUnwrap(
      URL(string: "https://cas-bridge.xethub.hf.co/xet-bridge-us/signed-blob?token=ephemeral"))

    let redirectedResume = try makeResumeData(
      bytesReceived: 2048, downloadURL: cdnURL,
      originalRequest: NSURLRequest(url: specV1.downloadURL))
    let redirectedMutableResume = try makeResumeData(
      bytesReceived: 2048, downloadURL: cdnURL,
      originalRequest: NSMutableURLRequest(url: specV1.downloadURL))

    // Both immutable and mutable archived NSURLRequest decode to the original catalog URL.
    XCTAssertEqual(ModelStore.resumeDataURLString(from: redirectedResume), specV1.downloadURL.absoluteString)
    XCTAssertEqual(ModelStore.resumeDataURLString(from: redirectedMutableResume), specV1.downloadURL.absoluteString)
    XCTAssertTrue(ModelStore.isResumeData(redirectedResume, compatibleWith: specV1))
    XCTAssertTrue(ModelStore.isResumeData(redirectedMutableResume, compatibleWith: specV1))
    XCTAssertFalse(ModelStore.isResumeData(redirectedResume, compatibleWith: specV2))

    // `resolveSpec` matches via archived `NSURLSessionResumeOriginalRequest` even without taskDescription/requestURL.
    let resolved = ModelStore.resolveSpec(
      taskDescription: nil, requestURL: nil, resumeData: redirectedResume, catalog: [specV1])
    XCTAssertEqual(resolved?.spec.id, specV1.id)

    // Background error with 302-redirected CDN URL persists and reloads as `.paused(0.5)`.
    let networkError = makeNetworkError(resumeData: redirectedResume)
    ModelStore.handleTaskCompletion(
      taskDescription: nil, requestURL: nil, error: networkError,
      in: modelsDir, catalog: [specV1], store: nil)
    let fileV1 = modelsDir.appendingPathComponent(ModelStore.resumeFileName(for: specV1))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileV1.path))

    let storeV1 = ModelStore(
      modelsDirectoryOverride: modelsDir, defaults: defaults,
      usesBackgroundSession: false, catalog: [specV1])
    if case .paused(let progress) = storeV1.states[specV1.id] {
      XCTAssertEqual(progress, 0.5, accuracy: 0.01)
    } else {
      XCTFail("Expected .paused(0.5) for 302-redirected HF resume data, got \(String(describing: storeV1.states[specV1.id]))")
    }

    // Stale v1 redirected resume data planted under v2's filename is still rejected by originalRequest mismatch.
    let fileV2 = modelsDir.appendingPathComponent(ModelStore.resumeFileName(for: specV2))
    try redirectedResume.write(to: fileV2)
    let storeV2 = ModelStore(
      modelsDirectoryOverride: modelsDir, defaults: defaults,
      usesBackgroundSession: false, catalog: [specV2])
    XCTAssertEqual(storeV2.states[specV2.id], .notDownloaded)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileV2.path))
  }

  @MainActor
  func testLateBeginVerificationCannotClobberFinishedOrFailedState() async throws {
    let payload = Data(repeating: 0x3A, count: 2048)
    let (spec, _) = try makeTestSpec(payload: payload)
    let store = ModelStore(
      modelsDirectoryOverride: modelsDir, defaults: defaults,
      usesBackgroundSession: false, catalog: [spec])

    // 1. Deterministic reversed-order check: publishVerification + endStaging finish BEFORE beginVerification runs.
    let token = UUID()
    let lease = BackgroundDownloads.coordinator.beginStaging(ModelStore.stagingFiles(for: spec), in: modelsDir)
    store.publishVerification(for: spec, token: token, error: ModelStoreError.sizeMismatch(expected: 2048, actual: 64))
    BackgroundDownloads.coordinator.endStaging(lease, in: modelsDir)

    let expectedError = ModelStoreError.sizeMismatch(expected: 2048, actual: 64).localizedDescription
    XCTAssertEqual(store.states[spec.id], .failed(message: expectedError))
    XCTAssertFalse(
      store.beginVerification(for: spec, token: token, stagingID: lease.id),
      "Late beginVerification after endStaging must be rejected")
    XCTAssertFalse(store.isVerifying(spec.id))
    XCTAssertEqual(store.states[spec.id], .failed(message: expectedError))

    // Also verify late beginVerification cannot clobber `.ready` even without a stagingID.
    store.publishVerification(for: spec, token: nil, error: nil)
    XCTAssertEqual(store.states[spec.id], .ready)
    XCTAssertFalse(store.beginVerification(for: spec, token: nil))
    XCTAssertFalse(store.isVerifying(spec.id))
    XCTAssertEqual(store.states[spec.id], .ready)

    // 2. End-to-end fast sizeMismatch via finishDownload settles cleanly in `.failed` (never stuck verifying).
    let store2 = ModelStore(
      modelsDirectoryOverride: modelsDir, defaults: defaults,
      usesBackgroundSession: false, catalog: [spec])
    let badSource = scratch.appendingPathComponent("truncated.tmp")
    try Data(repeating: 0x01, count: 64).write(to: badSource)
    let response = HTTPURLResponse(
      url: spec.downloadURL, statusCode: 200, httpVersion: nil, headerFields: nil)
    ModelStore.finishDownload(
      ModelStore.DownloadTarget(spec: spec, token: nil, directory: modelsDir),
      response: response, at: badSource, store: store2)

    let failed = await waitUntil {
      if case .failed = store2.states[spec.id] { return !store2.isVerifying(spec.id) }
      return false
    }
    XCTAssertTrue(failed)
    for _ in 0..<5 { await Task.yield() }
    XCTAssertFalse(store2.isVerifying(spec.id))
    if case .failed = store2.states[spec.id] {
      // Expected
    } else {
      XCTFail("Expected .failed to stay settled, got \(String(describing: store2.states[spec.id]))")
    }
    XCTAssertTrue(BackgroundDownloads.coordinator.activeFiles(in: modelsDir).isEmpty)
  }
}
