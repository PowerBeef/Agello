import Darwin
import Foundation

/// Where LiteRT-LM keeps compiled GPU programs and GPU-format weights.
///
/// Our runtime keys the weights by content, so every context size shares one
/// copy (Mac: 2.2 GB for 4K, 8K and 16K; a new size loads in 1.2–1.4 s, a
/// first load compiles for about 7.5 s): one folder for the chat model,
/// `kv-all-<build id>`, and one for the embedder, `embedding-<build id>`.
///
/// LiteRT-LM's cache keys ignore which runtime build wrote them, and a program
/// cache from another build can't be trusted. So the folders carry the build's
/// id (`litert_lm_get_build_info`), and everything else in the cache root is
/// deleted at the next load: other builds' folders, and the per-size folders
/// and flat files of earlier versions.
enum EngineCache {
  /// LiteRT-LM's value for "don't cache" (the benchmark's one-off engine).
  static let disabled = ":nocache"

  /// The loaded runtime's build id.
  static let runtimeBuildID: String = runtimeBuildInfo()?["build_id"] ?? "unknown"

  static func folder(build: String = runtimeBuildID) -> String { "kv-all-\(build)" }

  static func embeddingFolder(build: String = runtimeBuildID) -> String { "embedding-\(build)" }

  /// `litert_lm_get_build_info`, looked up at run time.
  static func runtimeBuildInfo() -> [String: String]? {
    typealias GetBuildInfo = @convention(c) () -> UnsafePointer<CChar>?
    guard let handle = dlopen(nil, RTLD_NOW), let address = dlsym(handle, "litert_lm_get_build_info"),
      let text = unsafeBitCast(address, to: GetBuildInfo.self)()
    else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8))) as? [String: String]
  }

  /// What to delete from the cache root: everything but this build's two folders.
  static func entriesToDelete(_ names: [String], build: String = runtimeBuildID) -> [String] {
    let kept = [folder(build: build), embeddingFolder(build: build)]
    return names.filter { !kept.contains($0) }
  }

  /// The chat model's cache folder: created, marked as just used (`scripts/storage.sh` reads
  /// which build is current from it), and everything that isn't this build's deleted.
  static func directory(root: URL? = nil, build: String = runtimeBuildID) throws -> String {
    let root = try root ?? defaultRoot()
    let files = FileManager.default
    let names = (try? files.contentsOfDirectory(atPath: root.path)) ?? []
    for name in entriesToDelete(names, build: build) {
      do {
        try files.removeItem(at: root.appendingPathComponent(name))
        Log.engine.info("engine cache: removed \(name, privacy: .public)")
      } catch {
        Log.engine.error("engine cache: couldn't remove \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
      }
    }
    let dir = root.appendingPathComponent(folder(build: build), isDirectory: true)
    try files.createDirectory(at: dir, withIntermediateDirectories: true)
    try files.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
    return dir.path
  }

  /// The embedder's cache folder.
  static func embeddingDirectory(root: URL? = nil, build: String = runtimeBuildID) throws -> String {
    let dir = try (root ?? defaultRoot()).appendingPathComponent(
      embeddingFolder(build: build), isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.path
  }

  /// Library/Caches persists across launches (unlike tmp), so compiled GPU
  /// kernels survive restarts and warm loads stay fast.
  private static func defaultRoot() throws -> URL {
    // A root given from outside (`AGELLO_ENGINE_CACHE_DIR`), for development tools on a Mac
    // (docs/CLI.md). It must be a folder of its own: other builds' folders in it are deleted.
    if let path = ProcessInfo.processInfo.environment["AGELLO_ENGINE_CACHE_DIR"], !path.isEmpty {
      return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }
    return try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    .appendingPathComponent("com.patricedery.agello.litertlm", isDirectory: true)
  }
}
