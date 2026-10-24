import Darwin
import Foundation

/// Reply stats on our LiteRT-LM builds, without benchmark mode.
///
/// The per-reply stats (input and output tokens, decode speed) came from the conversation's
/// `BenchmarkInfo`, which needs the engine in benchmark mode. In our builds benchmark mode also
/// makes every GPU wait spin, about 29 ms of CPU per token on the M6 against 2 ms when the
/// waits sleep. Our builds record the same figures in their telemetry (`agello/telemetry`):
/// running totals of tokens prefilled and decoded (counters) and of the time spent in each
/// turn's prefill and decode (spans, level 2 and up). A reply's figures are the difference
/// between the totals taken before and after it. Google's binary has no telemetry, keeps
/// benchmark mode and reads `BenchmarkInfo` as before.
///
/// The functions are looked up at run time, as `EngineCache.runtimeBuildInfo` is.
enum RuntimeTelemetry {
  /// The level that records span timings (counters alone are level 1, the runtime's default).
  static let spanLevel: Int32 = 2

  /// Whether replies take their stats from telemetry instead of benchmark mode: a build of
  /// ours (it reports a build id) that has telemetry.
  static func replacesBenchmark(runtimeBuildID: String?, hasTelemetry: Bool) -> Bool {
    runtimeBuildID != nil && hasTelemetry
  }

  /// Whether the loaded runtime's replies take their stats from telemetry.
  static let inUse = replacesBenchmark(
    runtimeBuildID: EngineCache.runtimeBuildID, hasTelemetry: isAvailable)

  static var isAvailable: Bool {
    symbol("litert_lm_telemetry_snapshot_json", as: Snapshot.self) != nil
  }

  /// Raises the level to record spans; a higher level (the test harness's choice) stays.
  static func recordSpans() {
    guard let get = symbol("litert_lm_telemetry_get_level", as: GetLevel.self),
      let set = symbol("litert_lm_telemetry_set_level", as: SetLevel.self), get() < spanLevel
    else { return }
    set(spanLevel)
  }

  /// The running totals now, or nil without telemetry.
  static func totals() -> TelemetryTotals? {
    guard let take = symbol("litert_lm_telemetry_snapshot_json", as: Snapshot.self),
      let free = symbol("litert_lm_telemetry_free_string", as: Free.self),
      let text = take()
    else { return nil }
    defer { free(text) }
    return TelemetryTotals(json: Data(String(cString: text).utf8))
  }

  private typealias Snapshot = @convention(c) () -> UnsafeMutablePointer<CChar>?
  private typealias Free = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
  private typealias GetLevel = @convention(c) () -> Int32
  private typealias SetLevel = @convention(c) (Int32) -> Void

  private static func symbol<T>(_ name: String, as _: T.Type) -> T? {
    guard let handle = dlopen(nil, RTLD_NOW), let address = dlsym(handle, name) else { return nil }
    return unsafeBitCast(address, to: T.self)
  }
}

/// The telemetry totals a reply's stats come from, since the runtime's last reset.
struct TelemetryTotals: Equatable, Sendable {
  var tokensPrefilled = 0
  var tokensDecoded = 0
  var prefillMilliseconds = 0.0
  var decodeMilliseconds = 0.0

  /// Parses `litert_lm_telemetry_snapshot_json`'s counters and span totals.
  init?(json: Data) {
    guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
      let counters = object["counters"] as? [String: Any]
    else { return nil }
    let spans = object["spans"] as? [String: Any] ?? [:]
    func spanMilliseconds(_ name: String) -> Double {
      ((spans[name] as? [String: Any])?["total_ms"] as? NSNumber)?.doubleValue ?? 0
    }
    tokensPrefilled = (counters["tokens_prefilled"] as? NSNumber)?.intValue ?? 0
    tokensDecoded = (counters["tokens_decoded"] as? NSNumber)?.intValue ?? 0
    prefillMilliseconds = spanMilliseconds("turn.prefill")
    decodeMilliseconds = spanMilliseconds("turn.decode")
  }

  init(
    tokensPrefilled: Int, tokensDecoded: Int, prefillMilliseconds: Double,
    decodeMilliseconds: Double
  ) {
    self.tokensPrefilled = tokensPrefilled
    self.tokensDecoded = tokensDecoded
    self.prefillMilliseconds = prefillMilliseconds
    self.decodeMilliseconds = decodeMilliseconds
  }
}

/// One reply's prefill and decode figures from the totals taken before and after it. Every
/// turn of the reply counts (a reply with tool calls has several), where `BenchmarkInfo`
/// reports its last turn.
struct ReplyTelemetry: Equatable, Sendable {
  var inputTokens: Int
  var outputTokens: Int
  /// nil when the decode time wasn't recorded (telemetry below level 2).
  var decodeTokensPerSecond: Double?

  /// nil when the totals went back (a reset in between, as the test harness does per scenario)
  /// or the reply decoded nothing.
  init?(before: TelemetryTotals, after: TelemetryTotals) {
    let prefilled = after.tokensPrefilled - before.tokensPrefilled
    let decoded = after.tokensDecoded - before.tokensDecoded
    let decodeMilliseconds = after.decodeMilliseconds - before.decodeMilliseconds
    guard prefilled >= 0, decoded > 0, decodeMilliseconds >= 0,
      after.prefillMilliseconds >= before.prefillMilliseconds
    else { return nil }
    inputTokens = prefilled
    outputTokens = decoded
    decodeTokensPerSecond = decodeMilliseconds > 0 ? Double(decoded) / decodeMilliseconds * 1000 : nil
  }
}
