import Foundation

/// Persists security-scoped folder bookmarks per project so users can link a local or iCloud Drive
/// folder once and re-sync its supported documents into the project's ``KnowledgeBase``.
enum FolderBookmarks {
  struct LinkedFolder: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { projectID }
    let projectID: UUID
    var folderName: String
    var bookmarkData: Data
    var lastSyncedAt: Date?
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

  /// Creates and stores a security-scoped bookmark for `folderURL` linked to `projectID`.
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
      lastSyncedAt: Date())
    var list = all(defaults: defaults)
    if let idx = list.firstIndex(where: { $0.projectID == projectID }) {
      list[idx] = entry
    } else {
      list.append(entry)
    }
    persist(list, defaults: defaults)
    return entry
  }

  static func markSynced(for projectID: UUID, at date: Date = Date(), defaults: UserDefaults = .standard) {
    var list = all(defaults: defaults)
    guard let idx = list.firstIndex(where: { $0.projectID == projectID }) else { return }
    list[idx].lastSyncedAt = date
    persist(list, defaults: defaults)
  }

  static func remove(for projectID: UUID, defaults: UserDefaults = .standard) {
    var list = all(defaults: defaults)
    list.removeAll { $0.projectID == projectID }
    persist(list, defaults: defaults)
  }

  /// Resolves a stored folder bookmark and enumerates supported regular files (non-recursive
  /// plus immediate children, capped at ``maxFilesPerSync``) inside a security-scoped access block.
  static func withSupportedFiles<T: Sendable>(
    for projectID: UUID, defaults: UserDefaults = .standard,
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
      _ = try? save(folderURL: url, for: projectID, defaults: defaults)
    }
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let files = collectSupportedFiles(in: url)
    let output = try await work(files)
    markSynced(for: projectID, defaults: defaults)
    return output
  }

  static func collectSupportedFiles(in folderURL: URL, limit: Int = maxFilesPerSync) -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: folderURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
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
}
