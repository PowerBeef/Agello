import Foundation
import OSLog
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

  /// How often, how long in all and how long at most something ran (a write to the chat, a
  /// markdown parse).
  private struct Work: Sendable {
    var count = 0
    var total = 0.0
    var longest = 0.0
  }

  /// The app's state at one moment of the reply.
  private struct Sample: Sendable {
    var seconds: Double
    var footprintBytes: UInt64
    var availableBytes: UInt64
    var thermalState: Int
    var chunks: Int
  }

  private struct Running: Sendable {
    var generation = UUID()
    var started = ContinuousClock.now
    var startedAt = Date.now
    var prompt = ""
    var settings: [String: Value] = [:]
    var events: [Event] = []
    var replyID: String?
    var once: Set<String> = []
    var telemetryBefore: String?
    var work: [String: Work] = [:]
    var samples: [Sample] = []
    var chunks = 0
  }

  /// The last trace written: helper tasks that follow a reply (its title, memories) are added
  /// to its file.
  private struct Finished: Sendable {
    var url: URL
    var ended = ContinuousClock.now
  }

  private static let running = Mutex<Running?>(nil)
  private static let finished = Mutex<Finished?>(nil)
  /// The same steps as events in Instruments (Points of Interest).
  private static let signposter = OSSignposter(subsystem: "com.patricedery.agello", category: .pointsOfInterest)

  /// A send starts: an unfinished trace (a send that was refused) is dropped.
  @MainActor
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
    let generation = trace.generation
    running.withLock { $0 = trace }
    mark("send")
    FrameMonitor.start()
    // The timeline: memory, heat and how far decoding is, once a second until the reply ends.
    Task.detached(priority: .utility) {
      while sample(generation) { try? await Task.sleep(for: .seconds(1)) }
    }
  }

  private static func sample(_ generation: UUID) -> Bool {
    let footprint = MemoryProbe.footprintBytes()
    let available = MemoryProbe.availableBytes()
    let thermal = ProcessInfo.processInfo.thermalState.rawValue
    return running.withLock { trace in
      guard trace?.generation == generation else { return false }
      let seconds = (ContinuousClock.now - trace!.started).seconds
      trace!.samples.append(
        Sample(
          seconds: seconds, footprintBytes: footprint, availableBytes: available, thermalState: thermal,
          chunks: trace!.chunks))
      return true
    }
  }

  /// The engine has streamed `chunks` pieces of the reply so far (it says so every few hundred).
  static func progress(chunks: Int) {
    guard isEnabled else { return }
    running.withLock { $0?.chunks = chunks }
  }

  /// Work of one kind since `started`: counted, summed, and the longest kept.
  static func measure(_ kind: String, since started: ContinuousClock.Instant) {
    guard isEnabled else { return }
    let seconds = (ContinuousClock.now - started).seconds
    running.withLock { trace in
      guard trace != nil else { return }
      var work = trace!.work[kind] ?? Work()
      work.count += 1
      work.total += seconds
      work.longest = max(work.longest, seconds)
      trace!.work[kind] = work
    }
  }

  /// Runs `body`, measured as `kind` while a reply is traced.
  static func timed<Result>(_ kind: String, _ body: () -> Result) -> Result {
    guard isEnabled else { return body() }
    let started = ContinuousClock.now
    defer { measure(kind, since: started) }
    return body()
  }

  /// A step of the reply in progress, with the time since the send and the app's memory.
  static func mark(_ name: String, _ values: [String: Value] = [:]) {
    guard isEnabled else { return }
    signposter.emitEvent("Reply step", "\(name, privacy: .public)")
    let footprint = MemoryProbe.footprintBytes()
    let available = MemoryProbe.availableBytes()
    let recorded = running.withLock { trace -> Bool in
      guard trace != nil else { return false }
      let seconds = (ContinuousClock.now - trace!.started).seconds
      trace!.events.append(
        Event(name: name, seconds: seconds, footprintBytes: footprint, availableBytes: available, values: values))
      return true
    }
    if !recorded { markAfter(name, values) }
  }

  /// A step after the reply ended (a title or memory helper, within two minutes): added to the
  /// reply's file under "after".
  private static func markAfter(_ name: String, _ values: [String: Value]) {
    guard let last = finished.withLock({ $0 }), ContinuousClock.now - last.ended < .seconds(120),
      let data = try? Data(contentsOf: last.url),
      var report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return }
    var entry: [String: Any] = ["name": name, "secondsAfter": (ContinuousClock.now - last.ended).seconds]
    for (key, value) in values { entry[key] = value.json }
    report["after"] = (report["after"] as? [[String: Any]] ?? []) + [entry]
    if let updated = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
      try? updated.write(to: last.url, options: .atomic)
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

  /// Part of a message bubble came on screen (its reasoning card, its answer): the first of each
  /// for the reply in progress counts.
  static func onScreen(_ id: UUID, _ part: String = "text") {
    guard isEnabled, running.withLock({ $0?.replyID == id.uuidString }) else { return }
    markOnce("first \(part) on screen")
  }

  /// The reply is over, however it ended (nil when it was removed, stopped before any text):
  /// writes the file. Reads the turn on the main actor, where it lives.
  @MainActor
  static func end(reply: ChatTurn?, error: String?, notice: String?) {
    guard isEnabled else { return }
    end(
      text: reply?.text ?? "", thought: reply?.thought ?? "", stats: reply?.stats,
      sources: reply?.parts.sources.map { "\($0.index) \($0.title) \($0.url ?? "")" } ?? [],
      frames: FrameMonitor.stop(), error: error, notice: notice)
  }

  static func end(
    text: String, thought: String, stats: GenerationStats?, sources: [String] = [], frames: [String: Double] = [:],
    error: String?, notice: String?
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
      "work": trace.work.mapValues { ["count": Double($0.count), "totalSeconds": $0.total, "longestSeconds": $0.longest] },
      "frames": frames,
      "timeline": trace.samples.map { sample -> [String: Any] in
        [
          "seconds": sample.seconds, "footprintGB": Double(sample.footprintBytes) / 1e9,
          "availableGB": Double(sample.availableBytes) / 1e9, "thermalState": sample.thermalState,
          "chunks": sample.chunks,
        ]
      },
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
    let url = folder.appendingPathComponent("\(stamp)-\(name).json")
    try? data.write(to: url, options: .atomic)
    finished.withLock { $0 = Finished(url: url) }
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
