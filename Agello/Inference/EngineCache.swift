import Darwin
import Foundation

/// Where LiteRT-LM keeps compiled GPU programs and GPU-format weights, kept
/// to a bounded size.
///
/// LiteRT-LM's GPU weight cache stores a full copy of the model's weights
/// (2.2 GB for E4B) for every context size an engine is created with, in one
/// file it never trims while the model file is unchanged (probe 14). So each
/// context size gets its own folder, and only the most recently used ones
/// stay. A cached size loads in under a second; an evicted one recompiles
/// once (~7.5 s for E4B).
///
/// LiteRT-LM's cache keys ignore which runtime build wrote them, and a program
/// cache from another build can't be trusted. Builds that report a build id
/// (ours, `litert_lm_get_build_info`) get folders of their own
/// (`kv-8192-<id>`, `embedding-<id>`); Google's keep the plain names. A
/// different build's folders are deleted on the next load.
enum EngineCache {
  /// Context sizes whose caches stay: the current one and the last other.
  static let keptContextSizes = 2
  /// LiteRT-LM's value for "don't cache" (the benchmark's one-off engine).
  static let disabled = ":nocache"
  /// The embedder's folder: one fixed configuration, never evicted.
  static let embeddingFolder = "embedding"

  /// The loaded runtime's build id, or nil for builds without one (Google's).
  static let runtimeBuildID: String? = runtimeBuildInfo()?["build_id"]

  static func folder(maxNumTokens: Int, build: String? = runtimeBuildID) -> String {
    build.map { "kv-\(maxNumTokens)-\($0)" } ?? "kv-\(maxNumTokens)"
  }

  static func embeddingFolder(build: String? = runtimeBuildID) -> String {
    build.map { "\(embeddingFolder)-\($0)" } ?? embeddingFolder
  }

  /// The build a context-size folder belongs to: nil for `kv-8192`, "abc" for `kv-8192-abc`.
  static func build(ofSizeFolder name: String) -> String? {
    let parts = name.split(separator: "-", maxSplits: 2)
    return parts.count == 3 ? String(parts[2]) : nil
  }

  /// `litert_lm_get_build_info`, looked up at run time: Google's binary doesn't have it.
  static func runtimeBuildInfo() -> [String: String]? {
    typealias GetBuildInfo = @convention(c) () -> UnsafePointer<CChar>?
    guard let handle = dlopen(nil, RTLD_NOW), let address = dlsym(handle, "litert_lm_get_build_info"),
      let text = unsafeBitCast(address, to: GetBuildInfo.self)()
    else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8))) as? [String: String]
  }

  struct Entry: Equatable {
    var name: String
    var isDirectory: Bool
    var modified: Date
  }

  /// What to delete from the cache root when `current` is about to be used:
  /// this build's context-size folders beyond the `keep` most recently used
  /// (`current` counts as the newest), and anything else except this build's
  /// embedder folder: other builds' folders, and the flat cache files from
  /// before per-size folders.
  static func entriesToDelete(
    _ entries: [Entry], current: String, keep: Int, build: String? = nil
  ) -> [String] {
    let sizeFolders = entries.filter {
      $0.isDirectory && $0.name.hasPrefix("kv-") && $0.name != current
        && Self.build(ofSizeFolder: $0.name) == build
    }
    .sorted { $0.modified > $1.modified }
    let keptOthers = Set(sizeFolders.prefix(max(0, keep - 1)).map(\.name))
    return entries.compactMap { entry in
      if entry.name == current || keptOthers.contains(entry.name) { return nil }
      if entry.isDirectory, entry.name == embeddingFolder(build: build) { return nil }
      return entry.name
    }
  }

  /// The cache folder for an engine with this context size: created, marked
  /// as just used, and the older caches beyond the limit deleted.
  static func directory(
    maxNumTokens: Int, root: URL? = nil, build: String? = runtimeBuildID
  ) throws -> String {
    let root = try root ?? defaultRoot()
    let files = FileManager.default
    let current = folder(maxNumTokens: maxNumTokens, build: build)
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
    let urls = (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))) ?? []
    let entries = urls.map { url -> Entry in
      let values = try? url.resourceValues(forKeys: keys)
      return Entry(
        name: url.lastPathComponent, isDirectory: values?.isDirectory ?? false,
        modified: values?.contentModificationDate ?? .distantPast)
    }
    for name in entriesToDelete(entries, current: current, keep: keptContextSizes, build: build) {
      do {
        try files.removeItem(at: root.appendingPathComponent(name))
        Log.engine.info("engine cache: removed \(name, privacy: .public)")
      } catch {
        Log.engine.error("engine cache: couldn't remove \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
      }
    }
    let dir = root.appendingPathComponent(current, isDirectory: true)
    try files.createDirectory(at: dir, withIntermediateDirectories: true)
    try files.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
    return dir.path
  }

  /// The embedder's cache folder.
  static func embeddingDirectory(root: URL? = nil, build: String? = runtimeBuildID) throws -> String {
    let dir = try (root ?? defaultRoot()).appendingPathComponent(
      embeddingFolder(build: build), isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
  }

  /// Library/Caches persists across launches (unlike tmp), so compiled GPU
  /// kernels survive restarts and warm loads stay fast.
  private static func defaultRoot() throws -> URL {
    try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    .appendingPathComponent("com.patricedery.agello.litertlm", isDirectory: true)
  }
}
