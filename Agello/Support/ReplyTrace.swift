import Foundation
import Synchronization

/// One reply's path through the app, for the autonomous harness (docs/HARNESS.md): the settings
/// in effect, each step with its time and memory, why the reply ended, and the engine's
/// telemetry around it. Written as one JSON file per reply into Documents/traces, which the
/// harness pulls from the phone.
///
/// Off unless the app is launched with `--trace` (the bench driver does): nothing is kept and
/// nothing is written otherwise, and nothing is ever sent anywhere. Steps are recorded per stage,
/// never per token, so tracing doesn't move the speeds it reports.
enum ReplyTrace {
  static let isEnabled = ProcessInfo.processInfo.arguments.contains("--trace")
  static let kept = 40

  /// A value an event carries.
  enum Value: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    fileprivate var json: Any {
      switch self {
      case .string(let value): return value
      case .int(let value): return value
      case .double(let value): return value
      case .bool(let value): return value
      }
    }
  }

  private struct Event: Sendable {
    var name: String
    var seconds: Double
    var footprintBytes: UInt64
    var availableBytes: UInt64
    var values: [String: Value]
  }

  private struct Running: Sendable {
    var started = ContinuousClock.now
    var startedAt = Date.now
    var prompt = ""
    var settings: [String: Value] = [:]
    var events: [Event] = []
    var replyID: String?
    var once: Set<String> = []
    var telemetryBefore: String?
  }

  private static let running = Mutex<Running?>(nil)

  /// A send starts: an unfinished trace (a send that was refused) is dropped.
  static func begin(
    prompt: String, options: InferenceOptions, resolved: ResolvedInference?, search: Bool, tools: Bool
  ) {
    guard isEnabled else { return }
    var trace = Running()
    trace.prompt = prompt
    trace.settings = [
      "think": .bool(options.enableThinking), "thinkingBudget": .int(options.thinkingBudget),
      "search": .bool(search), "tools": .bool(tools),
      "sampler": .string(options.samplerPreset.rawValue),
      "speculativeDecoding": .bool(options.enableSpeculativeDecoding),
      "window": .int(resolved?.maxNumTokens ?? 0),
      "gpu": .bool(resolved?.useGPU ?? false),
      "runtimeBuild": .string(EngineCache.runtimeBuildID ?? "none"),
      "appVersion": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""),
      "optimized": .bool(isOptimizedBuild),
      "thermalState": .int(ProcessInfo.processInfo.thermalState.rawValue),
    ]
    trace.telemetryBefore = RuntimeTelemetry.snapshotJSON()
    running.withLock { $0 = trace }
    mark("send")
  }

  /// A step of the reply in progress, with the time since the send and the app's memory.
  static func mark(_ name: String, _ values: [String: Value] = [:]) {
    guard isEnabled else { return }
    let footprint = MemoryProbe.footprintBytes()
    let available = MemoryProbe.availableBytes()
    running.withLock { trace in
      guard trace != nil else { return }
      let seconds = (ContinuousClock.now - trace!.started).seconds
      trace!.events.append(
        Event(name: name, seconds: seconds, footprintBytes: footprint, availableBytes: available, values: values))
    }
  }

  /// A step that counts the first time only (the first token, the first text on screen).
  static func markOnce(_ name: String, _ values: [String: Value] = [:]) {
    guard isEnabled else { return }
    let isNew = running.withLock { trace in trace?.once.insert(name).inserted ?? false }
    if isNew { mark(name, values) }
  }

  /// The reply's placeholder exists: later steps and the file carry its ID.
  static func reply(id: UUID, sources: Int) {
    guard isEnabled else { return }
    running.withLock { $0?.replyID = id.uuidString }
    mark("reply", ["sources": .int(sources)])
  }

  /// A message bubble with text came on screen: the first one of the reply in progress counts.
  static func onScreen(_ id: UUID) {
    guard isEnabled, running.withLock({ $0?.replyID == id.uuidString }) else { return }
    markOnce("first text on screen")
  }

  /// The reply is over, however it ended (nil when it was removed, stopped before any text):
  /// writes the file. Reads the turn on the main actor, where it lives.
  @MainActor
  static func end(reply: ChatTurn?, error: String?, notice: String?) {
    guard isEnabled else { return }
    end(
      text: reply?.text ?? "", thought: reply?.thought ?? "", stats: reply?.stats,
      sources: reply?.parts.sources.map { "\($0.index) \($0.title) \($0.url ?? "")" } ?? [],
      error: error, notice: notice)
  }

  static func end(
    text: String, thought: String, stats: GenerationStats?, sources: [String] = [], error: String?, notice: String?
  ) {
    guard isEnabled, let trace = running.withLock({ trace in
      defer { trace = nil }
      return trace
    }) else { return }
    let ended = (ContinuousClock.now - trace.started).seconds
    var report: [String: Any] = [
      "schema": 1,
      "startedAt": ISO8601DateFormatter().string(from: trace.startedAt),
      "replyID": trace.replyID ?? "",
      "prompt": trace.prompt,
      "settings": trace.settings.mapValues(\.json),
      "events": trace.events.map { event -> [String: Any] in
        var entry: [String: Any] = [
          "name": event.name, "seconds": event.seconds,
          "footprintGB": Double(event.footprintBytes) / 1e9, "availableGB": Double(event.availableBytes) / 1e9,
        ]
        for (key, value) in event.values { entry[key] = value.json }
        return entry
      },
      "seconds": ended,
      "ended": endReason(stats: stats, error: error).rawValue,
      "text": text, "thought": thought, "sources": sources,
      "error": error ?? "", "notice": notice ?? "",
    ]
    if let stats, let data = try? JSONEncoder().encode(stats),
      let object = try? JSONSerialization.jsonObject(with: data)
    {
      report["stats"] = object
    }
    var engine: [String: Any] = [:]
    for (key, text) in [("before", trace.telemetryBefore), ("after", RuntimeTelemetry.snapshotJSON())] {
      if let text, let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) { engine[key] = object }
    }
    if !engine.isEmpty { report["engineTelemetry"] = engine }
    write(report, named: trace.replyID ?? UUID().uuidString, at: trace.startedAt)
  }

  /// Why a reply ended.
  enum EndReason: String, Sendable {
    /// The model finished its answer.
    case model
    /// The last round reached its output cap.
    case outputCap
    /// Stop, or a new chat, while it wrote.
    case stopped
    /// Available memory ran out.
    case memory
    /// The app left the foreground.
    case background
    /// The room for tool rounds ran out.
    case truncated
    case error
  }

  /// Pure, for unit tests: finished replies carry stats; the others are told apart by the error
  /// the app shows (none for Stop).
  static func endReason(stats: GenerationStats?, error: String?) -> EndReason {
    if let stats { return stats.reachedLimit == true ? .outputCap : .model }
    guard let error, !error.isEmpty else { return .stopped }
    if error.contains("free memory") { return .memory }
    if error.contains("background") { return .background }
    if error.contains("cut short") { return .truncated }
    return .error
  }

  static func directory() throws -> URL {
    let folder = try FileManager.default.url(
      for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("traces", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  private static func write(_ report: [String: Any], named name: String, at date: Date) {
    guard let folder = try? directory(),
      let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    else { return }
    let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
    try? data.write(to: folder.appendingPathComponent("\(stamp)-\(name).json"), options: .atomic)
    // The newest ``kept`` stay (names start with their time).
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    for old in names.dropLast(kept) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(old)) }
  }

  /// Asserts run only in unoptimized builds.
  private static var isOptimizedBuild: Bool {
    var optimized = true
    assert(
      {
        optimized = false
        return true
      }())
    return optimized
  }
}

extension Duration {
  fileprivate var seconds: Double {
    Double(components.seconds) + Double(components.attoseconds) / 1e18
  }
}
