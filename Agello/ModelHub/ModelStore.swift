import AppleArchive
import CryptoKit
import Foundation
import Network
import System

/// Downloads and stores `.litertlm` model files in Application Support.
/// Downloads run in a background `URLSession`: they continue when the app
/// is in the background (or suspended) and support pause/resume.
@Observable
@MainActor
final class ModelStore: NSObject {
  enum DownloadState: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case paused(progress: Double)
    case ready
    case failed(message: String)
  }

  private(set) var states: [ModelID: DownloadState] = [
    .e4b: .notDownloaded, .embeddingGemma: .notDownloaded,
  ]

  /// The one chat model (Gemma 4 E4B).
  let activeModelID: ModelID = .e4b

  var activeSpec: ModelSpec { ModelCatalog.e4b }
  var activeSpecDownloaded: Bool { isDownloaded(activeSpec) }

  @ObservationIgnored
  private var session: URLSession { BackgroundDownloads.session }
  @ObservationIgnored
  private var activeTask: URLSessionDownloadTask?
  @ObservationIgnored
  private var downloadingSpec: ModelSpec?
  @ObservationIgnored
  private var resumeData: [ModelID: Data] = [:]
  /// Downloads waiting for the current one (one at a time).
  @ObservationIgnored
  private var queue: [ModelSpec] = []
  /// Called when a download finishes and the model is ready to load (e.g.
  /// to index files attached before the embedding model arrived).
  @ObservationIgnored
  var onModelReady: ((ModelID) -> Void)?
  /// On a cellular or other metered network, or in Low Data Mode, right now.
  private(set) var onExpensiveNetwork = false
  /// Downloads told to wait for Wi-Fi that haven't received anything yet.
  private(set) var waitingForWiFi: Set<ModelID> = []
  @ObservationIgnored private let pathMonitor = NWPathMonitor()
  /// The user's choice for the running (or held) download: false waits for Wi-Fi.
  @ObservationIgnored private var wantsCellular = true
  /// A download held for Wi-Fi with its resume data, no task running (see ``resumeAction``).
  @ObservationIgnored private var heldForWiFi: ModelID?

  /// Files larger than this ask before downloading over a cellular or metered network.
  nonisolated static let cellularConsentBytes: Int64 = 200_000_000

  override init() {
    super.init()
    // Retired preference from the two-model era.
    UserDefaults.standard.removeObject(forKey: "activeModelID")
    // Models given from outside: what's there is ready, and nothing else starts.
    guard Self.externalModelsDirectory == nil else {
      refreshStates()
      return
    }
    BackgroundDownloads.delegate.store = self
    for spec in ModelCatalog.all { resumeData[spec.id] = Self.savedResumeData(for: spec.id) }
    refreshStates()
    reattachRunningDownload()
    pathMonitor.pathUpdateHandler = { [weak self] path in
      let expensive = path.isExpensive || path.isConstrained
      Task { @MainActor in self?.networkChanged(expensive: expensive) }
    }
    pathMonitor.start(queue: DispatchQueue(label: "agello.network-path"))
  }

  /// Whether downloading `spec` now should ask first (a large file over a metered network).
  func needsCellularConsent(for spec: ModelSpec) -> Bool {
    onExpensiveNetwork && spec.sizeBytes > Self.cellularConsentBytes && !isDownloaded(spec)
  }

  /// After a relaunch, a download may still be running in the background
  /// session: show its progress and keep pause/cancel working.
  private func reattachRunningDownload() {
    session.getAllTasks { [weak self] tasks in
      let running = tasks.compactMap { $0 as? URLSessionDownloadTask }
        .filter { $0.state == .running || $0.state == .suspended }
      guard let task = running.first,
        let id = task.taskDescription.flatMap(ModelID.init(rawValue:))
      else { return }
      let expected = task.countOfBytesExpectedToReceive
      let progress = expected > 0 ? Double(task.countOfBytesReceived) / Double(expected) : 0
      Task { @MainActor in
        guard let self, self.downloadingSpec == nil, self.states[id] != .ready else { return }
        self.downloadingSpec = ModelCatalog.spec(for: id)
        self.activeTask = task
        self.states[id] = .downloading(progress: progress)
        if task.state == .suspended { task.resume() }
      }
    }
  }

  // MARK: - Paths

  /// A models folder given from outside (`AGELLO_MODELS_DIR`), for development tools that run
  /// the engine on a Mac with models already on disk (docs/CLI.md). The store then only reads
  /// it: no download, no deletion, no cleanup of files it doesn't know. Never active in Release.
  nonisolated static let externalModelsDirectory: URL? = {
    #if DEBUG || BENCH
      guard let path = ProcessInfo.processInfo.environment["AGELLO_MODELS_DIR"], !path.isEmpty else { return nil }
      return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    #else
      return nil
    #endif
  }()

  nonisolated static func modelsDirectory() throws -> URL {
    if let externalModelsDirectory { return externalModelsDirectory }
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
      create: true
    )
    var dir = base.appendingPathComponent("Models", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // Multi-GB, re-downloadable: keep out of iCloud/iTunes backups
    // (directory exclusion covers every model file inside it).
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? dir.setResourceValues(values)
    return dir
  }

  /// Free space required beyond the file and its engine cache (loading, the OS).
  nonisolated static let storageMargin: Int64 = 500_000_000

  /// Disk `spec` needs: the file, the engine cache its first load writes, and a margin.
  nonisolated static func requiredBytes(for spec: ModelSpec) -> Int64 {
    spec.sizeBytes + spec.engineCacheBytes + storageMargin
  }

  /// Whether `availableBytes` (nil = unknown) can hold `spec`.
  nonisolated static func hasRoom(for spec: ModelSpec, availableBytes: Int64?) -> Bool {
    guard let availableBytes else { return true }
    return availableBytes >= requiredBytes(for: spec)
  }

  private func availableStorageBytes() -> Int64? {
    guard let dir = try? Self.modelsDirectory() else { return nil }
    return (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
      .volumeAvailableCapacityForImportantUsage
  }

  func localURL(for spec: ModelSpec) -> URL? {
    try? Self.modelsDirectory().appendingPathComponent(
      spec.extractedDirectoryName ?? spec.fileName,
      isDirectory: spec.extractedDirectoryName != nil)
  }

  func isDownloaded(_ spec: ModelSpec) -> Bool {
    guard let url = localURL(for: spec) else { return false }
    if spec.extractedDirectoryName != nil {
      return EmbeddingBundleLayout.isAvailable(at: url)
    }
    guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
    else { return false }
    // A models folder given from outside (development tools) may hold a variant of a catalog
    // file, such as a model whose graph was edited: any file there counts.
    if Self.externalModelsDirectory != nil { return size > 0 }
    return size == spec.sizeBytes
  }

  func refreshStates() {
    removeUnknownModelFiles()
    for spec in ModelCatalog.all {
      if case .downloading = states[spec.id] { continue }
      // Resume data arrives asynchronously after a pause; without it,
      // Resume simply restarts the download.
      if case .paused = states[spec.id] { continue }
      if isDownloaded(spec) {
        states[spec.id] = .ready
      } else if let data = resumeData[spec.id] {
        // Paused (or interrupted) in an earlier run: resume where it stopped.
        states[spec.id] = .paused(progress: Self.progress(ofResumeData: data, size: spec.sizeBytes))
      } else {
        states[spec.id] = .notDownloaded
      }
    }
  }

  // MARK: - Network policy

  enum ResumeAction: Equatable {
    /// Resume from the saved data.
    case resume
    /// Keep the data and wait for an unmetered network.
    case hold
    /// Start over: the saved data can only replay its original request's network policy.
    case restart
  }

  /// What to do with saved resume data. It replays the original request, network policy
  /// included, so a download first started on Wi-Fi (allowed on cellular) resumed under "Wait
  /// for Wi-Fi" kept using cellular, and a Wi-Fi-only one never ran when "Download now" was
  /// chosen on cellular (2026-11-16).
  nonisolated static func resumeAction(
    wantsCellular: Bool, resumeAllowsCellular: Bool, onExpensiveNetwork: Bool
  ) -> ResumeAction {
    guard onExpensiveNetwork else { return .resume }
    if !wantsCellular { return .hold }
    return resumeAllowsCellular ? .resume : .restart
  }

  /// The network policy of the request behind a model's saved resume data (true when unknown:
  /// downloads allowed cellular before it was recorded).
  private func resumeAllowsCellular(_ id: ModelID) -> Bool {
    UserDefaults.standard.object(forKey: "resumeAllowsCellular.\(id.rawValue)") as? Bool ?? true
  }

  private func setRequestAllowsCellular(_ allows: Bool?, for id: ModelID) {
    let key = "resumeAllowsCellular.\(id.rawValue)"
    if let allows { UserDefaults.standard.set(allows, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
  }

  private func networkChanged(expensive: Bool) {
    onExpensiveNetwork = expensive
    if !expensive, let id = heldForWiFi {
      // Wi-Fi again: the held download resumes.
      heldForWiFi = nil
      downloadingSpec = nil
      startDownload(ModelCatalog.spec(for: id), overCellular: false)
    } else if expensive, !wantsCellular, let spec = downloadingSpec, activeTask != nil,
      resumeAllowsCellular(spec.id)
    {
      // A download told to wait for Wi-Fi whose request allows cellular: hold it.
      pauseDownload(spec)
      hold(spec, progress: 0)
    }
  }

  private func hold(_ spec: ModelSpec, progress: Double) {
    heldForWiFi = spec.id
    downloadingSpec = spec
    states[spec.id] = .downloading(progress: progress)
    waitingForWiFi.insert(spec.id)
  }

  // MARK: - Actions

  /// Download `spec`; `overCellular` false waits for Wi-Fi when the network is metered (see
  /// ``needsCellularConsent(for:)``).
  func startDownload(_ spec: ModelSpec, overCellular: Bool = true) {
    if let folder = Self.externalModelsDirectory {
      states[spec.id] = .failed(message: "\(spec.fileName) isn't in \(folder.path).")
      return
    }
    if let current = downloadingSpec {
      if current.id == spec.id { return }
      // One download at a time: pause (keeping resume data) rather than
      // abandoning the other model in a stuck "Downloading" state.
      pauseDownload(current)
    }
    if resumeData[spec.id] == nil, !Self.hasRoom(for: spec, availableBytes: availableStorageBytes())
    {
      let needed = ByteCountFormatter.string(
        fromByteCount: Self.requiredBytes(for: spec), countStyle: .file)
      states[spec.id] = .failed(message: "Not enough storage. \(needed) free space is needed.")
      return
    }
    downloadingSpec = spec
    wantsCellular = overCellular
    var saved = resumeData[spec.id]
    if let data = saved {
      switch Self.resumeAction(
        wantsCellular: overCellular, resumeAllowsCellular: resumeAllowsCellular(spec.id),
        onExpensiveNetwork: onExpensiveNetwork)
      {
      case .hold:
        return hold(spec, progress: Self.progress(ofResumeData: data, size: spec.sizeBytes))
      case .restart:
        keepResumeData(nil, for: spec.id)
        saved = nil
      case .resume:
        break
      }
    }
    states[spec.id] = .downloading(progress: 0)
    let task: URLSessionDownloadTask
    if let data = saved {
      task = session.downloadTask(withResumeData: data)
    } else {
      var request = URLRequest(url: spec.downloadURL)
      request.allowsExpensiveNetworkAccess = overCellular
      request.allowsConstrainedNetworkAccess = overCellular
      setRequestAllowsCellular(overCellular, for: spec.id)
      task = session.downloadTask(with: request)
    }
    if !overCellular, onExpensiveNetwork { waitingForWiFi.insert(spec.id) }
    // Readable from any thread in delegate callbacks (see below).
    task.taskDescription = spec.id.rawValue
    activeTask = task
    task.resume()
  }

  /// Download `spec` unless it's already here, downloading, or queued; waits
  /// for any other download instead of pausing it.
  func ensureDownloaded(_ spec: ModelSpec) {
    guard !isDownloaded(spec), downloadingSpec?.id != spec.id,
      !queue.contains(where: { $0.id == spec.id })
    else { return }
    if downloadingSpec == nil {
      startDownload(spec)
    } else {
      queue.append(spec)
    }
  }

  /// Start the next queued download, if the slot is free.
  private func startNextQueued() {
    guard downloadingSpec == nil, !queue.isEmpty else { return }
    let next = queue.removeFirst()
    if !isDownloaded(next) { startDownload(next) } else { startNextQueued() }
  }

  func pauseDownload(_ spec: ModelSpec) {
    if heldForWiFi == spec.id {
      heldForWiFi = nil
      downloadingSpec = nil
      waitingForWiFi.remove(spec.id)
      let progress = resumeData[spec.id].map { Self.progress(ofResumeData: $0, size: spec.sizeBytes) } ?? 0
      states[spec.id] = .paused(progress: progress)
      return
    }
    guard downloadingSpec?.id == spec.id, let task = activeTask else { return }
    let progress: Double
    if case .downloading(let p) = states[spec.id] { progress = p } else { progress = 0 }
    // Release the slot now (a new download may start immediately); the
    // resume data arrives asynchronously and only touches this model's entry.
    activeTask = nil
    downloadingSpec = nil
    states[spec.id] = .paused(progress: progress)
    waitingForWiFi.remove(spec.id)
    task.cancel { [weak self] data in
      guard let data else { return }
      Task { @MainActor in self?.keepResumeData(data, for: spec.id) }
    }
  }

  func cancelDownload(_ spec: ModelSpec) {
    if heldForWiFi == spec.id { heldForWiFi = nil }
    setRequestAllowsCellular(nil, for: spec.id)
    if downloadingSpec?.id == spec.id {
      activeTask?.cancel()
      activeTask = nil
      downloadingSpec = nil
    }
    waitingForWiFi.remove(spec.id)
    keepResumeData(nil, for: spec.id)
    states[spec.id] = isDownloaded(spec) ? .ready : .notDownloaded
  }

  // MARK: - Resume data (kept across launches)

  /// Keep (or drop) where a download stopped, on disk too, so it resumes after a relaunch
  /// instead of starting the 3.7 GB again.
  func keepResumeData(_ data: Data?, for id: ModelID) {
    resumeData[id] = data
    guard let url = try? Self.resumeDataURL(for: id) else { return }
    if let data {
      try? data.write(to: url, options: .atomic)
    } else {
      try? FileManager.default.removeItem(at: url)
    }
  }

  nonisolated static func resumeDataURL(for id: ModelID) throws -> URL {
    try modelsDirectory().appendingPathComponent("\(id.rawValue).resume")
  }

  nonisolated static func savedResumeData(for id: ModelID) -> Data? {
    (try? resumeDataURL(for: id)).flatMap { try? Data(contentsOf: $0) }
  }

  /// How far a download got, from its resume data (0 when it doesn't say).
  nonisolated static func progress(ofResumeData data: Data, size: Int64) -> Double {
    guard size > 0,
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
      let received = (plist["NSURLSessionResumeBytesReceived"] as? NSNumber)?.int64Value
    else { return 0 }
    return min(1, Double(received) / Double(size))
  }

  func deleteModel(_ spec: ModelSpec) {
    guard Self.externalModelsDirectory == nil else { return }
    cancelDownload(spec)
    if let url = localURL(for: spec) {
      try? FileManager.default.removeItem(at: url)
    }
    states[spec.id] = .notDownloaded
  }

  /// Delete `.litertlm` files that are no longer in the catalog (e.g. after
  /// switching model variants), except one being downloaded right now.
  private func removeUnknownModelFiles() {
    guard Self.externalModelsDirectory == nil, let dir = try? Self.modelsDirectory() else { return }
    let known = Set(ModelCatalog.all.map(\.fileName))
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    // Staged downloads or extractions left by an interrupted check go too (unverified).
    let staging = downloadingSpec.map { Self.stagedName($0.fileName) }
    for file in files
    where (file.hasSuffix(".litertlm") && !known.contains(file) && file != downloadingSpec?.fileName)
      || (file.hasSuffix(".partial") && file != staging)
      || file.hasSuffix(".extracting")
    {
      try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
    }
  }

  // MARK: - File placement (synchronous, thread-safe, unit-tested)

  /// Move a finished download into place and verify its size.
  /// Must run synchronously inside `didFinishDownloadingTo` (the system may
  /// delete `location` as soon as that callback returns).
  ///
  /// - Throws: the underlying `FileManager` error, or
  ///   `ModelStoreError.sizeMismatch` (partial/corrupt file is removed).
  /// Reject error pages (e.g. HTTP 404/5xx bodies saved as the "model").
  nonisolated static func validateResponse(_ response: URLResponse?) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200...299).contains(http.statusCode) else {
      throw ModelStoreError.httpStatus(http.statusCode)
    }
  }

  /// Stage, then verify and install (tests; the download path runs the two apart).
  @discardableResult
  nonisolated static func placeDownloadedFile(
    from location: URL, fileName: String, expectedSize: Int64, expectedSHA256: String? = nil,
    extractToDirectoryName: String? = nil,
    validateExtractedDirectory: ((URL) -> Bool)? = nil,
    in directory: URL
  ) throws -> URL {
    let staged = try stageDownloadedFile(from: location, fileName: fileName, in: directory)
    return try installStagedFile(
      staged, fileName: fileName, expectedSize: expectedSize, expectedSHA256: expectedSHA256,
      extractToDirectoryName: extractToDirectoryName,
      validateExtractedDirectory: validateExtractedDirectory, in: directory)
  }

  /// A finished download's name until its size and SHA-256 are checked: the final name exists only
  /// for a verified file, so ``isDownloaded(_:)`` (size only) never trusts an unchecked one. The
  /// check used to run after the move to the final name, and an interruption left an unchecked
  /// model there (2026-11-16).
  nonisolated static func stagedName(_ fileName: String) -> String { fileName + ".partial" }

  /// Move a finished download to its staging name. Must run synchronously inside
  /// `didFinishDownloadingTo` (the system may delete `location` once that callback returns).
  @discardableResult
  nonisolated static func stageDownloadedFile(from location: URL, fileName: String, in directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let staged = directory.appendingPathComponent(stagedName(fileName))
    if FileManager.default.fileExists(atPath: staged.path) {
      try FileManager.default.removeItem(at: staged)
    }
    try FileManager.default.moveItem(at: location, to: staged)
    return staged
  }

  /// Check a staged download's size and SHA-256, then give it its final name (or extract an
  /// Apple Archive into `extractToDirectoryName`), replacing an older copy; a file that fails
  /// is removed. About 3 s for E4B: run it off the session's queue.
  @discardableResult
  nonisolated static func installStagedFile(
    _ staged: URL, fileName: String, expectedSize: Int64, expectedSHA256: String?,
    extractToDirectoryName: String? = nil,
    validateExtractedDirectory: ((URL) -> Bool)? = nil,
    in directory: URL
  ) throws -> URL {
    let size = (try FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? Int64) ?? -1
    guard size == expectedSize else {
      try? FileManager.default.removeItem(at: staged)
      throw ModelStoreError.sizeMismatch(expected: expectedSize, actual: size)
    }
    // The right size can still be the wrong bytes (a damaged or swapped file).
    if let expectedSHA256, try sha256(of: staged) != expectedSHA256.lowercased() {
      try? FileManager.default.removeItem(at: staged)
      throw ModelStoreError.checksumMismatch
    }
    if let dirName = extractToDirectoryName {
      let extracting = directory.appendingPathComponent(dirName + ".extracting", isDirectory: true)
      if FileManager.default.fileExists(atPath: extracting.path) {
        try? FileManager.default.removeItem(at: extracting)
      }
      do {
        try extractAppleArchive(from: staged, to: extracting)
        if let validateExtractedDirectory, !validateExtractedDirectory(extracting) {
          throw ModelStoreError.archiveExtractionFailed
        }
      } catch {
        try? FileManager.default.removeItem(at: extracting)
        try? FileManager.default.removeItem(at: staged)
        throw error is ModelStoreError ? error : ModelStoreError.archiveExtractionFailed
      }
      let destination = directory.appendingPathComponent(dirName, isDirectory: true)
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.moveItem(at: extracting, to: destination)
      try? FileManager.default.removeItem(at: staged)
      return destination
    }
    let destination = directory.appendingPathComponent(fileName)
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: staged, to: destination)
    return destination
  }

  /// Extract a compressed Apple Archive (`.aar`) into `destination` using Apple's streaming
  /// `AppleArchive` framework (constant memory, zero third-party dependencies).
  nonisolated static func extractAppleArchive(from archiveURL: URL, to destination: URL) throws {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    guard let archivePath = FilePath(archiveURL), let destPath = FilePath(destination) else {
      throw ModelStoreError.archiveExtractionFailed
    }
    guard
      let readStream = ArchiveByteStream.fileStream(
        path: archivePath, mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644)
      )
    else {
      throw ModelStoreError.archiveExtractionFailed
    }
    defer { try? readStream.close() }

    guard let decompressStream = ArchiveByteStream.decompressionStream(readingFrom: readStream) else {
      throw ModelStoreError.archiveExtractionFailed
    }
    defer { try? decompressStream.close() }

    guard let decodeStream = ArchiveStream.decodeStream(readingFrom: decompressStream) else {
      throw ModelStoreError.archiveExtractionFailed
    }
    defer { try? decodeStream.close() }

    guard
      let extractStream = ArchiveStream.extractStream(
        extractingTo: destPath, flags: [.ignoreOperationNotPermitted]
      )
    else {
      throw ModelStoreError.archiveExtractionFailed
    }
    defer { try? extractStream.close() }

    _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
  }

  /// Hex SHA-256 of a file, read in 8 MB pieces (about 3 s for E4B's 3.7 GB on a recent iPhone).
  nonisolated static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 8 << 20) }),
      !chunk.isEmpty
    {
      hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

enum ModelStoreError: Error, LocalizedError, Equatable {
  case sizeMismatch(expected: Int64, actual: Int64)
  case checksumMismatch
  case archiveExtractionFailed
  case httpStatus(Int)

  var errorDescription: String? {
    switch self {
    case .sizeMismatch(let expected, let actual):
      return
        "Downloaded file failed verification (got \(actual) bytes, expected \(expected)). Please retry."
    case .checksumMismatch:
      return "Downloaded file failed verification (its checksum doesn't match). Please retry."
    case .archiveExtractionFailed:
      return "Downloaded model bundle could not be unpacked. Please retry."
    case .httpStatus(let code):
      return "The download server returned HTTP \(code). Please retry later."
    }
  }
}

// MARK: - Background session

/// The app's one background download session (its identifier must be
/// unique per process), forwarding callbacks to the current ``ModelStore``.
enum BackgroundDownloads {
  static let identifier = "com.patricedery.agello.models"

  static let delegate = DownloadDelegate()

  static let session: URLSession = {
    let config = URLSessionConfiguration.background(withIdentifier: identifier)
    config.isDiscretionary = false  // start now, not when iOS sees fit
    config.sessionSendsLaunchEvents = true
    config.timeoutIntervalForRequest = 60
    return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
  }()

  /// Set by the app delegate when iOS relaunches the app for session events.
  @MainActor static var completionHandler: (() -> Void)?
}

final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  /// The store receiving callbacks (the latest created; only one in the app).
  weak var store: ModelStore?

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    ModelStore.finishDownload(downloadTask, at: location, store: store)
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    store?.urlSession(
      session, downloadTask: downloadTask, didWriteData: bytesWritten,
      totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    store?.urlSession(session, task: task, didCompleteWithError: error)
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    Task { @MainActor in
      BackgroundDownloads.completionHandler?()
      BackgroundDownloads.completionHandler = nil
    }
  }
}

// MARK: - Download callbacks (called off the main actor)

extension ModelStore {
  /// Place a finished download. Static: the file must be moved even if no
  /// store exists yet (the app was relaunched in the background).
  nonisolated static func finishDownload(
    _ downloadTask: URLSessionDownloadTask, at location: URL, store: ModelStore?
  ) {
    // Stage SYNCHRONOUSLY: the temp file is only guaranteed to exist for the
    // duration of this callback. This runs on the session's background queue.
    let rawID = downloadTask.taskDescription ?? ""
    let spec = ModelID(rawValue: rawID).map(ModelCatalog.spec(for:))
    let directory = try? Self.modelsDirectory()
    let staged: Result<URL, Error> = Result {
      guard let spec, let directory else {
        throw ChatError.underlying(message: "Download finished for an unknown model.")
      }
      try Self.validateResponse(downloadTask.response)
      return try Self.stageDownloadedFile(from: location, fileName: spec.fileName, in: directory)
    }
    // Verify off the session's queue (the hash takes seconds), then publish on the main actor.
    DispatchQueue.global(qos: .utility).async {
      let placementError: Error?
      do {
        let file = try staged.get()
        if let spec, let directory {
          try Self.installStagedFile(
            file, fileName: spec.fileName, expectedSize: spec.sizeBytes, expectedSHA256: spec.sha256,
            extractToDirectoryName: spec.extractedDirectoryName,
            validateExtractedDirectory: spec.extractedDirectoryName != nil
              ? { EmbeddingBundleLayout.isAvailable(at: $0) } : nil,
            in: directory)
        }
        placementError = nil
      } catch {
        placementError = error
      }
      Self.publishDownload(spec, error: placementError, store: store)
    }
  }

  private nonisolated static func publishDownload(_ spec: ModelSpec?, error placementError: Error?, store: ModelStore?) {
    Task { @MainActor [weak store] in
      guard let self = store, let spec else { return }
      // Only touch state if this task is still the in-flight download (or
      // none is tracked yet, right after a relaunch).
      guard self.downloadingSpec == nil || self.downloadingSpec?.id == spec.id else { return }
      self.keepResumeData(nil, for: spec.id)
      self.waitingForWiFi.remove(spec.id)
      self.activeTask = nil
      self.downloadingSpec = nil
      if let placementError {
        self.states[spec.id] = .failed(message: placementError.localizedDescription)
        Haptics.announce(placementError.localizedDescription)
      } else {
        self.states[spec.id] = .ready
        Haptics.success()
        Haptics.announce(String(localized: "\(spec.displayName) is ready"))
        self.onModelReady?(spec.id)
      }
      self.startNextQueued()
    }
  }

  nonisolated func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesExpectedToWrite > 0,
      let id = downloadTask.taskDescription.flatMap(ModelID.init(rawValue:))
    else { return }
    let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    Task { @MainActor [weak self] in
      // Ignore late callbacks from a paused/cancelled task.
      guard let self, self.downloadingSpec?.id == id else { return }
      self.waitingForWiFi.remove(id)
      self.states[id] = .downloading(progress: progress)
    }
  }

  nonisolated func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    guard let error else { return }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
    let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    let id = task.taskDescription.flatMap(ModelID.init(rawValue:))
    Task { @MainActor [weak self] in
      guard let self, let spec = self.downloadingSpec, spec.id == id else { return }
      // No resume data: a later Retry starts over (stale resume data would fail again).
      self.keepResumeData(resume, for: spec.id)
      self.waitingForWiFi.remove(spec.id)
      self.activeTask = nil
      self.downloadingSpec = nil
      let progress: Double
      if case .downloading(let p) = self.states[spec.id] { progress = p } else { progress = 0 }
      if resume != nil {
        self.states[spec.id] = .paused(progress: progress)
      } else {
        self.states[spec.id] = .failed(message: error.localizedDescription)
      }
      self.startNextQueued()
    }
  }
}
