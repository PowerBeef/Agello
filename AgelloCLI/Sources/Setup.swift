import Foundation

/// Where the command line reads and writes, decided before the engine's code first asks: the
/// shared code reads these from the environment (the hooks in ``ModelStore``, ``EngineCache``,
/// ``ReplyTrace``), so they're set first thing.
enum Setup {
  static let modelsDefault = "~/Models/agello"
  static let cacheDefault = "~/Models/agello/cache/agello-cli"

  /// A run's records when `--out` isn't given: build/cli/runs/<time>-<label>.jsonl.
  static func defaultRunFile(label: String) -> String {
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    return "build/cli/runs/\(stamp)-\(label).jsonl"
  }

  /// Sets the environment from the options, and returns what was chosen (for `env` and records).
  /// A bench run keeps its traces beside its records.
  @discardableResult
  static func prepare(_ arguments: inout Arguments, command: String) -> [String: String] {
    let models = expand(arguments.value("models") ?? modelsDefault)
    // One cache root per runtime build: the engine deletes other builds' folders in its root,
    // and two builds compared in turn should each load warm.
    let cache = expand(arguments.value("cache") ?? cacheDefault) + "/" + EngineCache.runtimeBuildID
    var tracesDefault = "build/cli/traces"
    if command == "bench" {
      // Decided here, once: the bench reads the same option again.
      let out = arguments.value("out") ?? defaultRunFile(label: arguments.peek("label") ?? "arm")
      arguments.restore("out", out)
      tracesDefault = (out as NSString).deletingPathExtension + ".traces"
    }
    let traces = expand(arguments.value("trace-dir") ?? tracesDefault)
    setenv("AGELLO_MODELS_DIR", models, 1)
    setenv("AGELLO_ENGINE_CACHE_DIR", cache, 1)
    setenv("AGELLO_TRACE_DIR", traces, 1)
    if let limit = arguments.value("memory-limit") { setenv(CommandLineMemory.variable, limit, 1) }
    if let pressure = arguments.value("memory-pressure") { setenv("AGELLO_CLI_MEMORY_PRESSURE", pressure, 1) }
    try? FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
    let log = (traces as NSString).deletingLastPathComponent + "/runtime.log"
    if !arguments.flag("verbose") { Console.quietRuntime(logPath: log) }
    return ["models": models, "engineCache": cache, "traces": traces, "runtimeLog": log]
  }

  static func expand(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
  }
}
