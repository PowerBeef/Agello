import Foundation

private enum LinkedFolderCodingKeys: String, CodingKey {
  case projectID, folderName, bookmarkData, lastSyncedAt, syncedFiles
}

/// Persists security-scoped folder bookmarks per project so users can link a local or iCloud Drive
/// folder once and re-sync its supported documents into the project's ``KnowledgeBase``.
enum FolderBookmarks {
  /// Modification date and byte count used to detect changed files during folder re-sync.
  struct FileFingerprint: Codable, Equatable, Sendable {
    var modifiedAt: Date?
    var byteCount: Int64
  }

  struct LinkedFolder: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { projectID }
    let projectID: UUID
    var folderName: String
    var bookmarkData: Data
    var lastSyncedAt: Date?
    var syncedFiles: [String: FileFingerprint]

    init(
      projectID: UUID, folderName: String, bookmarkData: Data, lastSyncedAt: Date? = nil,
      syncedFiles: [String: FileFingerprint] = [:]
    ) {
      self.projectID = projectID
      self.folderName = folderName
      self.bookmarkData = bookmarkData
      self.lastSyncedAt = lastSyncedAt
      self.syncedFiles = syncedFiles
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: LinkedFolderCodingKeys.self)
      projectID = try container.decode(UUID.self, forKey: .projectID)
      folderName = try container.decode(String.self, forKey: .folderName)
      bookmarkData = try container.decode(Data.self, forKey: .bookmarkData)
      lastSyncedAt = try container.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
      syncedFiles =
        try container.decodeIfPresent([String: FileFingerprint].self, forKey: .syncedFiles) ?? [:]
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: LinkedFolderCodingKeys.self)
      try container.encode(projectID, forKey: .projectID)
      try container.encode(folderName, forKey: .folderName)
      try container.encode(bookmarkData, forKey: .bookmarkData)
      try container.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
      try container.encode(syncedFiles, forKey: .syncedFiles)
    }
  }

  static let defaultsKey = "projectFolderBookmarks.v1"
  static let maxFilesPerSync = 25
  static let supportedExtensions: Set<String> = [
    "pdf", "txt", "md", "markdown", "csv", "tsv", "json", "swift", "py", "js", "ts", "html", "xml",
  ]

  static func all(defaults: UserDefaults = .standard) -> [LinkedFolder] {
    guard let data = defaults.data(forKey: defaultsKey),
      let list = try? JSONDecoder().decode([LinkedFolder].self, from: data)
    else { return [] }
    return list
  }

  static func folder(for projectID: UUID, defaults: UserDefaults = .standard) -> LinkedFolder? {
    all(defaults: defaults).first { $0.projectID == projectID }
  }

  static func fingerprint(for url: URL) -> FileFingerprint {
    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    return FileFingerprint(
      modifiedAt: values?.contentModificationDate,
      byteCount: Int64(values?.fileSize ?? 0))
  }

  /// Creates and stores a security-scoped bookmark for `folderURL` linked to `projectID`.
  /// `lastSyncedAt` stays nil until a sync actually succeeds via ``markSynced(for:at:syncedFiles:defaults:)``.
  @discardableResult
  static func save(
    folderURL: URL, for projectID: UUID, defaults: UserDefaults = .standard
  ) throws -> LinkedFolder {
    let accessed = folderURL.startAccessingSecurityScopedResource()
    defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }
    let data = try folderURL.bookmarkData(
      options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    let entry = LinkedFolder(
      projectID: projectID,
      folderName: folderURL.lastPathComponent.isEmpty ? "Linked Folder" : folderURL.lastPathComponent,
      bookmarkData: data,
      lastSyncedAt: nil,
      syncedFiles: [:])
    var list = all(defaults: defaults)
    if let idx = list.firstIndex(where: { $0.projectID == projectID }) {
      list[idx] = entry
    } else {
      list.append(entry)
    }
    persist(list, defaults: defaults)
    return entry
  }

  static func markSynced(
    for projectID: UUID, at date: Date = Date(),
    syncedFiles: [String: FileFingerprint]? = nil,
    defaults: UserDefaults = .standard
  ) {
    var list = all(defaults: defaults)
    guard let idx = list.firstIndex(where: { $0.projectID == projectID }) else { return }
    list[idx].lastSyncedAt = date
    if let syncedFiles {
      list[idx].syncedFiles = syncedFiles
    }
    persist(list, defaults: defaults)
  }

  static func forgetSyncedFile(
    _ name: String, for projectID: UUID, defaults: UserDefaults = .standard
  ) {
    var list = all(defaults: defaults)
    guard let idx = list.firstIndex(where: { $0.projectID == projectID }) else { return }
    guard list[idx].syncedFiles.removeValue(forKey: name) != nil else { return }
    persist(list, defaults: defaults)
  }

  static func remove(for projectID: UUID, defaults: UserDefaults = .standard) {
    var list = all(defaults: defaults)
    list.removeAll { $0.projectID == projectID }
    persist(list, defaults: defaults)
  }

  /// Resolves a stored folder bookmark and enumerates supported regular files (capped at
  /// ``maxFilesPerSync``) inside a security-scoped access block.
  static func withSupportedFiles<T: Sendable>(
    for projectID: UUID, defaults: UserDefaults = .standard,
    markSyncedOnReturn: Bool = true,
    work: @Sendable ([URL]) async throws -> T
  ) async throws -> T? {
    guard let entry = folder(for: projectID, defaults: defaults) else { return nil }
    var stale = false
    let url = try URL(
      resolvingBookmarkData: entry.bookmarkData,
      options: [],
      relativeTo: nil,
      bookmarkDataIsStale: &stale)
    if stale {
      refreshBookmarkData(for: projectID, folderURL: url, defaults: defaults)
    }
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let files = collectSupportedFiles(in: url)
    let output = try await work(files)
    if markSyncedOnReturn {
      markSynced(for: projectID, defaults: defaults)
    }
    return output
  }

  private static func refreshBookmarkData(
    for projectID: UUID, folderURL: URL, defaults: UserDefaults
  ) {
    let accessed = folderURL.startAccessingSecurityScopedResource()
    defer { if accessed { folderURL.stopAccessingSecurityScopedResource() } }
    guard
      let data = try? folderURL.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
    else { return }
    var list = all(defaults: defaults)
    guard let idx = list.firstIndex(where: { $0.projectID == projectID }) else { return }
    list[idx].bookmarkData = data
    persist(list, defaults: defaults)
  }

  static func collectSupportedFiles(in folderURL: URL, limit: Int = maxFilesPerSync) -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: folderURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [] }
    var urls: [URL] = []
    for case let item as URL in enumerator {
      let values = try? item.resourceValues(forKeys: [.isRegularFileKey])
      guard values?.isRegularFile == true else { continue }
      let ext = item.pathExtension.lowercased()
      guard supportedExtensions.contains(ext) else { continue }
      urls.append(item)
      if urls.count >= limit { break }
    }
    return urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
  }

  private static func persist(_ list: [LinkedFolder], defaults: UserDefaults) {
    if let encoded = try? JSONEncoder().encode(list) {
      defaults.set(encoded, forKey: defaultsKey)
    }
  }

  struct SyncedFile: Sendable {
    let document: ExtractedDocument
    let fingerprint: FileFingerprint
  }

  struct SyncOutcome: Sendable {
    var synced: [SyncedFile]
    var unchangedFingerprints: [String: FileFingerprint]
    var failed: [(name: String, reason: String)]
    var hitLimit: Bool

    var errorSummary: String? {
      guard !failed.isEmpty else { return nil }
      let preview = failed.prefix(2).map { "\($0.name): \($0.reason)" }.joined(separator: " ")
      let extra = failed.count > 2 ? " (+\(failed.count - 2) more)" : ""
      return preview + extra
    }

    var statusSummary: String? {
      if !synced.isEmpty {
        let count = synced.count
        var text =
          count == 1
          ? String(localized: "Synced 1 file.")
          : String(localized: "Synced \(count) files.")
        if hitLimit {
          text += " " + String(localized: "Showing the first \(FolderBookmarks.maxFilesPerSync) files.")
        }
        return text
      }
      return failed.isEmpty ? String(localized: "Folder is up to date.") : nil
    }
  }

  /// Scans a project's linked folder and extracts any new or modified supported files.
  static func scanChanges(
    for projectID: UUID, existingSizes: [String: Int64],
    priorFingerprints: [String: FileFingerprint], defaults: UserDefaults = .standard
  ) async throws -> SyncOutcome? {
    try await withSupportedFiles(
      for: projectID, defaults: defaults, markSyncedOnReturn: false
    ) { urls -> SyncOutcome in
      var synced: [SyncedFile] = []
      var unchanged: [String: FileFingerprint] = [:]
      var failed: [(name: String, reason: String)] = []
      for url in urls {
        try Task.checkCancellation()
        let fileName = url.lastPathComponent
        let fingerprint = fingerprint(for: url)
        let unchangedKnown = priorFingerprints[fileName] == fingerprint && existingSizes[fileName] != nil
        let unchangedLegacy = priorFingerprints[fileName] == nil && existingSizes[fileName] == fingerprint.byteCount
        if unchangedKnown || unchangedLegacy {
          unchanged[fileName] = fingerprint
          continue
        }
        do {
          let doc = try await DocumentIngestor.extract(from: url)
          synced.append(SyncedFile(document: doc, fingerprint: fingerprint))
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          failed.append((name: fileName, reason: error.localizedDescription))
        }
      }
      return SyncOutcome(
        synced: synced, unchangedFingerprints: unchanged, failed: failed,
        hitLimit: urls.count >= maxFilesPerSync)
    }
  }
}
