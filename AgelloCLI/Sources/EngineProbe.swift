import Foundation

/// The runtime's telemetry controls the app doesn't need (it only reads totals and snapshots,
/// ``RuntimeTelemetry``): the level, a reset between cases, and the event trace. Looked up at
/// run time, so a build without telemetry still loads and these do nothing.
enum EngineProbe {
  private typealias SetLevel = @convention(c) (Int32) -> Void
  private typealias GetLevel = @convention(c) () -> Int32
  private typealias Reset = @convention(c) () -> Void
  private typealias WriteTrace = @convention(c) (UnsafePointer<CChar>) -> Bool

  private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
    guard let handle = dlopen(nil, RTLD_NOW), let address = dlsym(handle, name) else { return nil }
    return unsafeBitCast(address, to: type)
  }

  /// 0 to 4 (the fork's TELEMETRY.md): 2 times spans, 3 keeps events for a trace, 4 times each
  /// GPU kernel and changes the speeds it measures.
  static var level: Int32 {
    get { symbol("litert_lm_telemetry_get_level", as: GetLevel.self)?() ?? 0 }
    set { symbol("litert_lm_telemetry_set_level", as: SetLevel.self)?(newValue) }
  }

  /// Zeroes the counters and spans, so the next snapshot is one case's.
  static func reset() {
    symbol("litert_lm_telemetry_reset", as: Reset.self)?()
  }

  /// The snapshot as a JSON object, or nil without telemetry.
  static func snapshot() -> [String: Any]? {
    guard let text = RuntimeTelemetry.snapshotJSON(), let data = text.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  /// Writes the level-3 events as a Chrome/Perfetto trace. False when there's nothing to write.
  @discardableResult
  static func writeTrace(to path: String) -> Bool {
    guard let write = symbol("litert_lm_telemetry_write_trace", as: WriteTrace.self) else { return false }
    return path.withCString { write($0) }
  }
}
