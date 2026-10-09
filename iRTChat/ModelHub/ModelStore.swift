import Foundation

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

  override init() {
    super.init()
    // Retired preference from the two-model era.
    UserDefaults.standard.removeObject(forKey: "activeModelID")
    BackgroundDownloads.delegate.store = self
    refreshStates()
    reattachRunningDownload()
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

  nonisolated static func modelsDirectory() throws -> URL {
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

  /// Free space required beyond the file itself (model loading, caches, OS).
  nonisolated static let storageMargin: Int64 = 500_000_000

  /// Whether `availableBytes` (nil = unknown) can hold `spec`.
  nonisolated static func hasRoom(for spec: ModelSpec, availableBytes: Int64?) -> Bool {
    guard let availableBytes else { return true }
    return availableBytes >= spec.sizeBytes + storageMargin
  }

  private func availableStorageBytes() -> Int64? {
    guard let dir = try? Self.modelsDirectory() else { return nil }
    return (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
      .volumeAvailableCapacityForImportantUsage
  }

  func localURL(for spec: ModelSpec) -> URL? {
    try? Self.modelsDirectory().appendingPathComponent(spec.fileName)
  }

  func isDownloaded(_ spec: ModelSpec) -> Bool {
    guard let url = localURL(for: spec) else { return false }
    guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
    else { return false }
    return size == spec.sizeBytes
  }

  func refreshStates() {
    removeUnknownModelFiles()
    for spec in ModelCatalog.all {
      if case .downloading = states[spec.id] { continue }
      // Resume data arrives asynchronously after a pause; without it,
      // Resume simply restarts the download.
      if case .paused = states[spec.id] { continue }
      states[spec.id] = isDownloaded(spec) ? .ready : .notDownloaded
    }
  }

  // MARK: - Actions

  func startDownload(_ spec: ModelSpec) {
    if let current = downloadingSpec {
      if current.id == spec.id { return }
      // One download at a time: pause (keeping resume data) rather than
      // abandoning the other model in a stuck "Downloading" state.
      pauseDownload(current)
    }
    if resumeData[spec.id] == nil, !Self.hasRoom(for: spec, availableBytes: availableStorageBytes())
    {
      let needed = ByteCountFormatter.string(
        fromByteCount: spec.sizeBytes + Self.storageMargin, countStyle: .file)
      states[spec.id] = .failed(message: "Not enough storage. \(needed) free space is needed.")
      return
    }
    downloadingSpec = spec
    states[spec.id] = .downloading(progress: 0)
    let task: URLSessionDownloadTask
    if let data = resumeData[spec.id] {
      task = session.downloadTask(withResumeData: data)
    } else {
      task = session.downloadTask(with: spec.downloadURL)
    }
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
    guard downloadingSpec?.id == spec.id, let task = activeTask else { return }
    let progress: Double
    if case .downloading(let p) = states[spec.id] { progress = p } else { progress = 0 }
    // Release the slot now (a new download may start immediately); the
    // resume data arrives asynchronously and only touches this model's entry.
    activeTask = nil
    downloadingSpec = nil
    states[spec.id] = .paused(progress: progress)
    task.cancel { [weak self] data in
      guard let data else { return }
      Task { @MainActor in self?.resumeData[spec.id] = data }
    }
  }

  func cancelDownload(_ spec: ModelSpec) {
    if downloadingSpec?.id == spec.id {
      activeTask?.cancel()
      activeTask = nil
      downloadingSpec = nil
    }
    resumeData[spec.id] = nil
    states[spec.id] = isDownloaded(spec) ? .ready : .notDownloaded
  }

  func deleteModel(_ spec: ModelSpec) {
    cancelDownload(spec)
    if let url = localURL(for: spec) {
      try? FileManager.default.removeItem(at: url)
    }
    states[spec.id] = .notDownloaded
  }

  /// Delete `.litertlm` files that are no longer in the catalog (e.g. after
  /// switching model variants), except one being downloaded right now.
  private func removeUnknownModelFiles() {
    guard let dir = try? Self.modelsDirectory() else { return }
    let known = Set(ModelCatalog.all.map(\.fileName))
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    for file in files
    where file.hasSuffix(".litertlm") && !known.contains(file)
      && file != downloadingSpec?.fileName
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

  @discardableResult
  nonisolated static func placeDownloadedFile(
    from location: URL, fileName: String, expectedSize: Int64, in directory: URL
  ) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(fileName)
    if FileManager.default.fileExists(atPath: destination.path) {
      try FileManager.default.removeItem(at: destination)
    }
    try FileManager.default.moveItem(at: location, to: destination)
    let size =
      (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? -1
    guard size == expectedSize else {
      try? FileManager.default.removeItem(at: destination)
      throw ModelStoreError.sizeMismatch(expected: expectedSize, actual: size)
    }
    return destination
  }
}

enum ModelStoreError: Error, LocalizedError, Equatable {
  case sizeMismatch(expected: Int64, actual: Int64)
  case httpStatus(Int)

  var errorDescription: String? {
    switch self {
    case .sizeMismatch(let expected, let actual):
      return
        "Downloaded file failed verification (got \(actual) bytes, expected \(expected)). Please retry."
    case .httpStatus(let code):
      return "The download server returned HTTP \(code). Please retry later."
    }
  }
}

// MARK: - Background session

/// The app's one background download session (its identifier must be
/// unique per process), forwarding callbacks to the current ``ModelStore``.
enum BackgroundDownloads {
  static let identifier = "com.patricedery.irtchat.models"

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
    // Move SYNCHRONOUSLY: the temp file is only guaranteed to exist for the
    // duration of this callback. This runs on the session's background queue.
    let rawID = downloadTask.taskDescription ?? ""
    let spec = ModelID(rawValue: rawID).map(ModelCatalog.spec(for:))
    var placementError: Error?
    if let spec, let directory = try? Self.modelsDirectory() {
      do {
        try Self.validateResponse(downloadTask.response)
        try Self.placeDownloadedFile(
          from: location, fileName: spec.fileName, expectedSize: spec.sizeBytes,
          in: directory)
      } catch {
        placementError = error
      }
    } else {
      placementError = ChatError.underlying(message: "Download finished for an unknown model.")
    }
    // Publish the outcome on the main actor.
    Task { @MainActor [weak store] in
      guard let self = store, let spec else { return }
      // Only touch state if this task is still the in-flight download (or
      // none is tracked yet, right after a relaunch).
      guard self.downloadingSpec == nil || self.downloadingSpec?.id == spec.id else { return }
      self.resumeData[spec.id] = nil
      self.activeTask = nil
      self.downloadingSpec = nil
      if let placementError {
        self.states[spec.id] = .failed(message: placementError.localizedDescription)
      } else {
        self.states[spec.id] = .ready
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
      if let resume { self.resumeData[spec.id] = resume }
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
