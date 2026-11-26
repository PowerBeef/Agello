import AppleArchive
import CryptoKit
import Foundation
import Network
import Synchronization
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
  /// Models currently running the post-download size/SHA-256/archive check.
  private(set) var verifyingIDs: Set<ModelID> = []
  /// Models waiting for `URLSessionDownloadTask.cancel(byProducingResumeData:)` to finish.
  private(set) var pausingIDs: Set<ModelID> = []
  @ObservationIgnored private let pathMonitor = NWPathMonitor()
  /// The user's choice for the running (or held) download: false waits for Wi-Fi.
  @ObservationIgnored private var wantsCellular = true
  /// A download held for Wi-Fi with its resume data, no task running (see ``resumeAction``).
  @ObservationIgnored private var heldForWiFi: ModelID?
  /// Per-model generation token for the active or pausing download task.
  @ObservationIgnored private var activeTokens: [ModelID: UUID] = [:]
  /// Models whose user tapped Resume before an in-flight Pause delivered its resume data.
  @ObservationIgnored private var pendingResume: [ModelID: Bool] = [:]
  private struct ProgressGate: Sendable {
    var token: UUID?
    var progress: Double
    var publishedAt: ContinuousClock.Instant
  }

  /// Cancelled download tokens checked synchronously by background verification workers.
  @ObservationIgnored private let cancelledTokens = Mutex<Set<UUID>>([])
  /// Throttles `didWriteData` progress hops before they touch `@MainActor` or `@Observable`.
  @ObservationIgnored private let progressGates = Mutex<[ModelID: ProgressGate]>([:])
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let modelsDirOverride: URL?
  @ObservationIgnored private let usesBackgroundSession: Bool
  /// Optional test seams (always `nil` in production).
  @ObservationIgnored var downloadLauncher: ((ModelSpec, Data?, Bool, String) -> Void)?
  @ObservationIgnored var pauseHandler: ((ModelID, @escaping @Sendable (Data?) -> Void) -> Void)?

  /// Files larger than this ask before downloading over a cellular or metered network.
  nonisolated static let cellularConsentBytes: Int64 = 200_000_000
  /// Minimum elapsed time or progress delta between published download progress ticks.
  nonisolated static let progressMinInterval: Duration = .milliseconds(100)
  nonisolated static let progressMinDelta: Double = 0.005

  override convenience init() {
    self.init(modelsDirectoryOverride: nil, defaults: .standard, usesBackgroundSession: true)
  }

  /// Isolated initializer for unit tests (keeps production `Models/` and `UserDefaults` untouched).
  init(
    modelsDirectoryOverride: URL?, defaults: UserDefaults = .standard,
    usesBackgroundSession: Bool = false
  ) {
    self.modelsDirOverride = modelsDirectoryOverride
    self.defaults = defaults
    self.usesBackgroundSession = usesBackgroundSession
    super.init()
    if usesBackgroundSession {
      // Retired preference from the two-model era.
      defaults.removeObject(forKey: "activeModelID")
    }
    // Models given from outside: what's there is ready, and nothing else starts.
    guard !usesExternalReadOnly else {
      refreshStates()
      return
    }
    if usesBackgroundSession {
      BackgroundDownloads.delegate.store = self
    }
    for spec in ModelCatalog.all { resumeData[spec.id] = loadSavedResumeData(for: spec.id) }
    refreshStates()
    if usesBackgroundSession {
      reattachRunningDownload()
      pathMonitor.pathUpdateHandler = { [weak self] path in
        let expensive = path.isExpensive || path.isConstrained
        Task { @MainActor in self?.networkChanged(expensive: expensive) }
      }
      pathMonitor.start(queue: DispatchQueue(label: "agello.network-path"))
    }
  }

  private var usesExternalReadOnly: Bool {
    modelsDirOverride == nil && Self.externalModelsDirectory != nil
  }

  func isVerifying(_ id: ModelID) -> Bool { verifyingIDs.contains(id) }
  func isVerifying(_ id: String) -> Bool { ModelID(rawValue: id).map(verifyingIDs.contains) ?? false }
  func isPausing(_ id: ModelID) -> Bool { pausingIDs.contains(id) }
  func isPausing(_ id: String) -> Bool { ModelID(rawValue: id).map(pausingIDs.contains) ?? false }

  nonisolated func isTokenCancelled(_ token: UUID?) -> Bool {
    guard let token else { return false }
    return cancelledTokens.withLock { $0.contains(token) }
  }

  nonisolated func markTokenCancelled(_ token: UUID) {
    cancelledTokens.withLock { _ = $0.insert(token) }
  }

  /// Throttle high-frequency `URLSession` write callbacks to `>= 100 ms` or `>= 0.5%` delta while
  /// always preserving the first update and the exact final `1.0` update.
  nonisolated func shouldPublishProgress(
    for id: ModelID, token: UUID?, progress: Double, now: ContinuousClock.Instant = .now
  ) -> Bool {
    let clamped = min(1, max(0, progress))
    return progressGates.withLock { gates in
      guard let previous = gates[id], previous.token == token else {
        gates[id] = ProgressGate(token: token, progress: clamped, publishedAt: now)
        return true
      }
      if clamped >= 1 {
        guard previous.progress < 1 else { return false }
        gates[id] = ProgressGate(token: token, progress: 1, publishedAt: now)
        return true
      }
      let elapsed = previous.publishedAt.duration(to: now)
      let delta = abs(clamped - previous.progress)
      guard elapsed >= Self.progressMinInterval || delta >= Self.progressMinDelta else {
        return false
      }
      guard clamped != previous.progress else { return false }
      gates[id] = ProgressGate(token: token, progress: clamped, publishedAt: now)
      return true
    }
  }

  nonisolated func clearProgressGate(for id: ModelID) {
    progressGates.withLock { _ = $0.removeValue(forKey: id) }
  }

  nonisolated static func taskDescription(for id: ModelID, token: UUID) -> String {
    "\(id.rawValue)|\(token.uuidString)"
  }

  nonisolated static func parseTaskDescription(_ description: String?) -> (id: ModelID, token: UUID?)? {
    guard let description, !description.isEmpty else { return nil }
    let parts = description.split(separator: "|", maxSplits: 1)
    guard let id = ModelID(rawValue: String(parts[0])) else { return nil }
    let token = parts.count > 1 ? UUID(uuidString: String(parts[1])) : nil
    return (id, token)
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
        let parsed = Self.parseTaskDescription(task.taskDescription)
      else { return }
      let expected = task.countOfBytesExpectedToReceive
      let progress = expected > 0 ? Double(task.countOfBytesReceived) / Double(expected) : 0
      Task { @MainActor in
        guard let self, self.downloadingSpec == nil, self.states[parsed.id] != .ready else { return }
        self.downloadingSpec = ModelCatalog.spec(for: parsed.id)
        self.activeTask = task
        self.activeTokens[parsed.id] = parsed.token ?? UUID()
        self.clearProgressGate(for: parsed.id)
        self.states[parsed.id] = .downloading(progress: progress)
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

  private func modelsDirectoryURL() -> URL? {
    if let modelsDirOverride { return modelsDirOverride }
    return try? Self.modelsDirectory()
  }

  private func availableStorageBytes() -> Int64? {
    guard let dir = modelsDirectoryURL() else { return nil }
    return (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
      .volumeAvailableCapacityForImportantUsage
  }

  func localURL(for spec: ModelSpec) -> URL? {
    modelsDirectoryURL()?.appendingPathComponent(
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
    if usesExternalReadOnly { return size > 0 }
    return size == spec.sizeBytes
  }

  func refreshStates() {
    removeUnknownModelFiles()
    for spec in ModelCatalog.all {
      if verifyingIDs.contains(spec.id) || pausingIDs.contains(spec.id) { continue }
      if case .downloading = states[spec.id] { continue }
      if case .paused = states[spec.id] { continue }
      if isDownloaded(spec) {
        states[spec.id] = .ready
      } else if case .failed = states[spec.id] {
        // Keep visible failure feedback until the user retries or cancels.
        continue
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
    defaults.object(forKey: "resumeAllowsCellular.\(id.rawValue)") as? Bool ?? true
  }

  private func setRequestAllowsCellular(_ allows: Bool?, for id: ModelID) {
    let key = "resumeAllowsCellular.\(id.rawValue)"
    if let allows { defaults.set(allows, forKey: key) } else { defaults.removeObject(forKey: key) }
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
    clearProgressGate(for: spec.id)
    states[spec.id] = .downloading(progress: progress)
    waitingForWiFi.insert(spec.id)
  }

  // MARK: - Actions

  /// Download `spec`; `overCellular` false waits for Wi-Fi when the network is metered (see
  /// ``needsCellularConsent(for:)``).
  func startDownload(_ spec: ModelSpec, overCellular: Bool = true) {
    if usesExternalReadOnly, let folder = Self.externalModelsDirectory {
      states[spec.id] = .failed(message: "\(spec.fileName) isn't in \(folder.path).")
      return
    }
    if verifyingIDs.contains(spec.id) { return }
    cancelOtherPendingResumes(except: spec.id)
    if let current = downloadingSpec {
      if current.id == spec.id { return }
      // One download at a time: pause (keeping resume data) rather than
      // abandoning the other model in a stuck "Downloading" state.
      pauseDownload(current)
    }
    if pausingIDs.contains(spec.id) {
      // Wait for the in-flight pause to deliver resumeData before restarting so we don't lose progress.
      pendingResume[spec.id] = overCellular
      let progress: Double
      if case .paused(let p) = states[spec.id] { progress = p } else { progress = 0 }
      states[spec.id] = .downloading(progress: progress)
      return
    }
    if resumeData[spec.id] == nil, !Self.hasRoom(for: spec, availableBytes: availableStorageBytes())
    {
      let needed = ModelSpec.formatByteCount(Self.requiredBytes(for: spec))
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
    let token = UUID()
    activeTokens[spec.id] = token
    clearProgressGate(for: spec.id)
    let initialProgress = saved.map { Self.progress(ofResumeData: $0, size: spec.sizeBytes) } ?? 0
    states[spec.id] = .downloading(progress: initialProgress)
    if !overCellular, onExpensiveNetwork { waitingForWiFi.insert(spec.id) }
    let desc = Self.taskDescription(for: spec.id, token: token)
    if let downloadLauncher {
      if saved == nil { setRequestAllowsCellular(overCellular, for: spec.id) }
      downloadLauncher(spec, saved, overCellular, desc)
      return
    }
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
    // Readable from any thread in delegate callbacks (see below).
    task.taskDescription = desc
    activeTask = task
    task.resume()
  }

  private func cancelOtherPendingResumes(except id: ModelID) {
    for otherID in pendingResume.keys where otherID != id {
      pendingResume.removeValue(forKey: otherID)
      if case .downloading(let p) = states[otherID] {
        states[otherID] = .paused(progress: p)
      }
    }
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
    if verifyingIDs.contains(spec.id) { return }
    if pausingIDs.contains(spec.id) {
      pendingResume.removeValue(forKey: spec.id)
      if case .downloading(let p) = states[spec.id] {
        states[spec.id] = .paused(progress: p)
      }
      return
    }
    if heldForWiFi == spec.id {
      heldForWiFi = nil
      downloadingSpec = nil
      activeTokens.removeValue(forKey: spec.id)
      waitingForWiFi.remove(spec.id)
      let progress = resumeData[spec.id].map { Self.progress(ofResumeData: $0, size: spec.sizeBytes) } ?? 0
      states[spec.id] = .paused(progress: progress)
      return
    }
    guard downloadingSpec?.id == spec.id, activeTask != nil || pauseHandler != nil else { return }
    let progress: Double
    if case .downloading(let p) = states[spec.id] { progress = p } else { progress = 0 }
    let token = activeTokens[spec.id] ?? UUID()
    activeTokens[spec.id] = token
    let task = activeTask
    // Release the slot now (a new download may start immediately); the
    // resume data arrives asynchronously and is gated on `token`.
    activeTask = nil
    downloadingSpec = nil
    clearProgressGate(for: spec.id)
    waitingForWiFi.remove(spec.id)
    pausingIDs.insert(spec.id)
    states[spec.id] = .paused(progress: progress)
    if let pauseHandler {
      pauseHandler(spec.id) { [weak self] data in
        Task { @MainActor in
          self?.completePause(for: spec, token: token, resumeData: data)
        }
      }
    } else {
      task?.cancel { [weak self] data in
        Task { @MainActor in
          self?.completePause(for: spec, token: token, resumeData: data)
        }
      }
    }
  }

  func completePause(for spec: ModelSpec, token: UUID, resumeData data: Data?) {
    guard !isTokenCancelled(token), activeTokens[spec.id] == token else { return }
    pausingIDs.remove(spec.id)
    if let data {
      keepResumeData(data, for: spec.id)
    }
    if let wantsCellular = pendingResume.removeValue(forKey: spec.id) {
      activeTokens.removeValue(forKey: spec.id)
      startDownload(spec, overCellular: wantsCellular)
      return
    }
    activeTokens.removeValue(forKey: spec.id)
    if heldForWiFi != spec.id, case .paused(let current) = states[spec.id], let data {
      let savedProgress = Self.progress(ofResumeData: data, size: spec.sizeBytes)
      if savedProgress > current {
        states[spec.id] = .paused(progress: savedProgress)
      }
    }
  }

  func cancelDownload(_ spec: ModelSpec) {
    let wasActive = downloadingSpec?.id == spec.id
    if heldForWiFi == spec.id { heldForWiFi = nil }
    pendingResume.removeValue(forKey: spec.id)
    pausingIDs.remove(spec.id)
    verifyingIDs.remove(spec.id)
    if let token = activeTokens.removeValue(forKey: spec.id) {
      markTokenCancelled(token)
    }
    clearProgressGate(for: spec.id)
    setRequestAllowsCellular(nil, for: spec.id)
    if wasActive {
      activeTask?.cancel()
      activeTask = nil
      downloadingSpec = nil
    }
    queue.removeAll { $0.id == spec.id }
    waitingForWiFi.remove(spec.id)
    keepResumeData(nil, for: spec.id)
    states[spec.id] = isDownloaded(spec) ? .ready : .notDownloaded
    if wasActive { startNextQueued() }
  }

  // MARK: - Resume data (kept across launches)

  /// Keep (or drop) where a download stopped, on disk too, so it resumes after a relaunch
  /// instead of starting the 3.7 GB again.
  func keepResumeData(_ data: Data?, for id: ModelID) {
    resumeData[id] = data
    guard let url = resumeDataFileURL(for: id) else { return }
    if let data {
      if let dir = modelsDirectoryURL() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      }
      try? data.write(to: url, options: .atomic)
    } else {
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func resumeDataFileURL(for id: ModelID) -> URL? {
    modelsDirectoryURL()?.appendingPathComponent("\(id.rawValue).resume")
  }

  private func loadSavedResumeData(for id: ModelID) -> Data? {
    resumeDataFileURL(for: id).flatMap { try? Data(contentsOf: $0) }
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
    guard !usesExternalReadOnly else { return }
    cancelDownload(spec)
    if let url = localURL(for: spec) {
      try? FileManager.default.removeItem(at: url)
    }
    states[spec.id] = .notDownloaded
  }

  /// Delete `.litertlm` files that are no longer in the catalog (e.g. after
  /// switching model variants), except one being downloaded right now.
  private func removeUnknownModelFiles() {
    guard !usesExternalReadOnly, let dir = modelsDirectoryURL() else { return }
    let known = Set(ModelCatalog.all.map(\.fileName))
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    // Staged downloads or extractions left by an interrupted check go too (unverified).
    var activeIDs = verifyingIDs
    if let downloadingID = downloadingSpec?.id { activeIDs.insert(downloadingID) }
    let activeStaging = Set(activeIDs.map { Self.stagedName(ModelCatalog.spec(for: $0).fileName) })
    let activeExtracting = Set(
      activeIDs.compactMap { ModelCatalog.spec(for: $0).extractedDirectoryName.map { $0 + ".extracting" } })
    for file in files
    where (file.hasSuffix(".litertlm") && !known.contains(file) && file != downloadingSpec?.fileName)
      || (file.hasSuffix(".partial") && !activeStaging.contains(file))
      || (file.hasSuffix(".extracting") && !activeExtracting.contains(file))
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
    in directory: URL,
    isCancelled: () -> Bool = { false }
  ) throws -> URL {
    if isCancelled() {
      try? FileManager.default.removeItem(at: staged)
      throw CancellationError()
    }
    let size = (try FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? Int64) ?? -1
    guard size == expectedSize else {
      try? FileManager.default.removeItem(at: staged)
      throw ModelStoreError.sizeMismatch(expected: expectedSize, actual: size)
    }
    // The right size can still be the wrong bytes (a damaged or swapped file).
    if let expectedSHA256 {
      do {
        guard try sha256(of: staged, isCancelled: isCancelled) == expectedSHA256.lowercased() else {
          try? FileManager.default.removeItem(at: staged)
          throw ModelStoreError.checksumMismatch
        }
      } catch is CancellationError {
        try? FileManager.default.removeItem(at: staged)
        throw CancellationError()
      }
    }
    if isCancelled() {
      try? FileManager.default.removeItem(at: staged)
      throw CancellationError()
    }
    if let dirName = extractToDirectoryName {
      let extracting = directory.appendingPathComponent(dirName + ".extracting", isDirectory: true)
      if FileManager.default.fileExists(atPath: extracting.path) {
        try? FileManager.default.removeItem(at: extracting)
      }
      do {
        try extractAppleArchive(from: staged, to: extracting)
        if isCancelled() {
          try? FileManager.default.removeItem(at: extracting)
          try? FileManager.default.removeItem(at: staged)
          throw CancellationError()
        }
        if let validateExtractedDirectory, !validateExtractedDirectory(extracting) {
          throw ModelStoreError.archiveExtractionFailed
        }
      } catch is CancellationError {
        try? FileManager.default.removeItem(at: extracting)
        try? FileManager.default.removeItem(at: staged)
        throw CancellationError()
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
  nonisolated static func sha256(of url: URL, isCancelled: () -> Bool = { false }) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 8 << 20) }),
      !chunk.isEmpty
    {
      if isCancelled() { throw CancellationError() }
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
  @discardableResult
  func beginVerification(for spec: ModelSpec, token: UUID?) -> Bool {
    guard !isTokenCancelled(token) else { return false }
    if let token, let active = activeTokens[spec.id], active != token { return false }
    if downloadingSpec != nil, downloadingSpec?.id != spec.id { return false }
    verifyingIDs.insert(spec.id)
    waitingForWiFi.remove(spec.id)
    states[spec.id] = .downloading(progress: 1)
    return true
  }

  func publishVerification(
    for spec: ModelSpec, token: UUID?, error placementError: Error?, cancelled: Bool = false
  ) {
    if activeTokens[spec.id] == nil || activeTokens[spec.id] == token {
      verifyingIDs.remove(spec.id)
    }
    let wasCancelled = cancelled || isTokenCancelled(token)
    let tokenMismatch = token != nil && activeTokens[spec.id] != nil && activeTokens[spec.id] != token
    if wasCancelled || tokenMismatch {
      // If verification moved the file right as Cancel ran, remove it unless the model was already ready.
      if states[spec.id] != .ready, !usesExternalReadOnly, let url = localURL(for: spec) {
        try? FileManager.default.removeItem(at: url)
      }
      if activeTokens[spec.id] == nil, states[spec.id] != .ready {
        states[spec.id] = isDownloaded(spec) ? .ready : .notDownloaded
      }
      return
    }
    // Only touch state if this task is still active for `spec.id` (or untracked after a relaunch).
    guard activeTokens[spec.id] == nil || activeTokens[spec.id] == token else { return }
    if activeTokens[spec.id] == token { activeTokens.removeValue(forKey: spec.id) }
    clearProgressGate(for: spec.id)
    keepResumeData(nil, for: spec.id)
    waitingForWiFi.remove(spec.id)
    if downloadingSpec?.id == spec.id {
      activeTask = nil
      downloadingSpec = nil
    }
    if let placementError {
      states[spec.id] = .failed(message: placementError.localizedDescription)
      Haptics.announce(placementError.localizedDescription)
    } else {
      states[spec.id] = .ready
      Haptics.success()
      Haptics.announce(String(localized: "\(spec.displayName) is ready"))
      onModelReady?(spec.id)
    }
    startNextQueued()
  }

  /// Place a finished download. Static: the file must be moved even if no
  /// store exists yet (the app was relaunched in the background).
  nonisolated static func finishDownload(
    _ downloadTask: URLSessionDownloadTask, at location: URL, store: ModelStore?
  ) {
    // Stage SYNCHRONOUSLY: the temp file is only guaranteed to exist for the
    // duration of this callback. This runs on the session's background queue.
    let parsed = Self.parseTaskDescription(downloadTask.taskDescription)
    let spec = parsed.map { ModelCatalog.spec(for: $0.id) }
    let token = parsed?.token
    if let token, store?.isTokenCancelled(token) == true { return }
    let directory = try? Self.modelsDirectory()
    let staged: Result<URL, Error> = Result {
      guard let spec, let directory else {
        throw ChatError.underlying(message: "Download finished for an unknown model.")
      }
      try Self.validateResponse(downloadTask.response)
      return try Self.stageDownloadedFile(from: location, fileName: spec.fileName, in: directory)
    }
    if let spec, case .success = staged {
      Task { @MainActor [weak store] in
        _ = store?.beginVerification(for: spec, token: token)
      }
    }
    // Verify off the session's queue (the hash takes seconds), then publish on the main actor.
    DispatchQueue.global(qos: .utility).async { [weak store] in
      let isCancelled: () -> Bool = {
        guard let token, let store else { return false }
        return store.isTokenCancelled(token)
      }
      var placementError: Error?
      var cancelled = false
      do {
        let file = try staged.get()
        if isCancelled() {
          try? FileManager.default.removeItem(at: file)
          cancelled = true
        } else if let spec, let directory {
          try Self.installStagedFile(
            file, fileName: spec.fileName, expectedSize: spec.sizeBytes, expectedSHA256: spec.sha256,
            extractToDirectoryName: spec.extractedDirectoryName,
            validateExtractedDirectory: spec.extractedDirectoryName != nil
              ? { EmbeddingBundleLayout.isAvailable(at: $0) } : nil,
            in: directory,
            isCancelled: isCancelled)
        }
      } catch is CancellationError {
        cancelled = true
      } catch {
        placementError = error
      }
      Self.publishDownload(
        spec, token: token, error: placementError, cancelled: cancelled, store: store)
    }
  }

  private nonisolated static func publishDownload(
    _ spec: ModelSpec?, token: UUID?, error placementError: Error?, cancelled: Bool,
    store: ModelStore?
  ) {
    Task { @MainActor [weak store] in
      guard let self = store, let spec else { return }
      self.publishVerification(for: spec, token: token, error: placementError, cancelled: cancelled)
    }
  }

  nonisolated func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    guard totalBytesExpectedToWrite > 0,
      let parsed = Self.parseTaskDescription(downloadTask.taskDescription),
      !isTokenCancelled(parsed.token)
    else { return }
    let progress = min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    guard shouldPublishProgress(for: parsed.id, token: parsed.token, progress: progress) else {
      return
    }
    Task { @MainActor [weak self] in
      // Ignore late callbacks from a paused/cancelled/verifying task.
      guard let self, self.downloadingSpec?.id == parsed.id,
        !self.verifyingIDs.contains(parsed.id), !self.pausingIDs.contains(parsed.id),
        !self.isTokenCancelled(parsed.token),
        parsed.token == nil || self.activeTokens[parsed.id] == parsed.token
      else { return }
      if self.waitingForWiFi.contains(parsed.id) {
        self.waitingForWiFi.remove(parsed.id)
      }
      if self.states[parsed.id] != .downloading(progress: progress) {
        self.states[parsed.id] = .downloading(progress: progress)
      }
    }
  }

  nonisolated func urlSession(
    _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
  ) {
    guard let error else { return }
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return }
    let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    let parsed = Self.parseTaskDescription(task.taskDescription)
    Task { @MainActor [weak self] in
      guard let self, let parsed, let spec = self.downloadingSpec, spec.id == parsed.id,
        !self.isTokenCancelled(parsed.token),
        parsed.token == nil || self.activeTokens[spec.id] == parsed.token
      else { return }
      // No resume data: a later Retry starts over (stale resume data would fail again).
      self.activeTokens.removeValue(forKey: spec.id)
      self.clearProgressGate(for: spec.id)
      self.verifyingIDs.remove(spec.id)
      self.pausingIDs.remove(spec.id)
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
