import Foundation

/// Where the command line reads and writes, decided before the engine's code first asks: the
/// shared code reads these from the environment (the hooks in ``ModelStore``, ``EngineCache``,
/// ``ReplyTrace``), so they're set first thing.
enum Setup {
  static let modelsDefault = "~/Models/agello"
  static let cacheDefault = "~/Models/agello/cache/agello-cli"

  /// Sets the environment from the options, and returns what was chosen (for `env` and records).
  @discardableResult
  static func prepare(_ arguments: inout Arguments) -> [String: String] {
    let models = expand(arguments.value("models") ?? modelsDefault)
    // One cache root per runtime build: the engine deletes other builds' folders in its root,
    // and two builds compared in turn should each load warm.
    let build = EngineCache.runtimeBuildID ?? "no-build-id"
    let cache = expand(arguments.value("cache") ?? cacheDefault) + "/" + build
    let traces = expand(arguments.value("trace-dir") ?? "build/cli/traces")
    setenv("AGELLO_MODELS_DIR", models, 1)
    setenv("AGELLO_ENGINE_CACHE_DIR", cache, 1)
    setenv("AGELLO_TRACE_DIR", traces, 1)
    if let limit = arguments.value("memory-limit") { setenv(CommandLineMemory.variable, limit, 1) }
    if let pressure = arguments.value("memory-pressure") { setenv("AGELLO_CLI_MEMORY_PRESSURE", pressure, 1) }
    try? FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
    return ["models": models, "engineCache": cache, "traces": traces]
  }

  static func expand(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
  }
}
