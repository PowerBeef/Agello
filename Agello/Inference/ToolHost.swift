import Foundation
import Synchronization

/// Records tool invocations as they actually run. LiteRT-LM executes tools
/// automatically inside the stream and does not surface the calls in the
/// streamed chunks, so this is the reliable signal that a tool ran.
/// Append-only so independent readers (the engine, the device harness) can
/// each observe invocations via a cursor without stealing them.
enum ToolActivity {
  private static let log = Mutex<[ToolActivityRecord]>([])

  static func record(_ name: String, summary: String) {
    log.withLock { $0.append(ToolActivityRecord(name: name, summary: summary)) }
    Log.generation.info("tool \(name, privacy: .public): \(summary, privacy: .public)")
  }

  /// Cursor for ``records(since:)``.
  static var cursor: Int { log.withLock { $0.count } }

  /// Tool runs recorded after `cursor` was taken.
  static func records(since cursor: Int) -> [ToolActivityRecord] {
    log.withLock { Array($0.dropFirst(cursor)) }
  }

  /// Names of tools run after `cursor` was taken.
  static func invocations(since cursor: Int) -> [String] {
    records(since: cursor).map(\.name)
  }
}

/// Per-reply limits for tool calls. Tool rounds run inside LiteRT-LM, so the
/// engine sets these before each generation and tools must honor them: a
/// tool result that overflows the KV cache corrupts the native heap.
enum ToolBudget {
  struct Limits: Sendable, Equatable {
    /// Largest tool result (UTF-8 bytes) the context can absorb.
    var maxResultBytes: Int
    /// Tool calls allowed for this reply.
    var maxCalls: Int
  }

  /// Used before any reply set a budget (tests, probes calling tools directly).
  static let unrestricted = Limits(maxResultBytes: 16_000, maxCalls: .max)

  /// A reply's share of the context room.
  struct Plan: Sendable, Equatable {
    /// Largest output of one generation round.
    var outputCap: Int
    var limits: Limits
  }

  /// Split `room` (tokens) for one reply. Tool rounds run inside LiteRT-LM
  /// under the same cap, so whenever any tool is registered (including
  /// `web_search` alone) the room is split: a quarter per generation, an
  /// eighth per tool result, at most two calls (3/4 + 2/8 = 1). Without
  /// tools the reply gets the whole room.
  static func plan(room: Int, toolsOffered: Bool) -> Plan {
    let resultBytes = Int(Double(room / 8) * ContextBudget.bytesPerToken)
    return toolsOffered
      ? Plan(outputCap: room / 4, limits: Limits(maxResultBytes: resultBytes, maxCalls: 2))
      : Plan(outputCap: room, limits: Limits(maxResultBytes: resultBytes, maxCalls: 0))
  }

  private struct State {
    var limits: Limits?
    var calls = 0
    var resultBytes = 0
    /// The last reply ended: tool rounds still running for it get nothing.
    var closed = false
  }
  private static let state = Mutex(State())

  static func begin(_ limits: Limits) {
    state.withLock { $0 = State(limits: limits) }
  }

  static func end() {
    state.withLock { $0 = State(closed: true) }
  }

  /// Back to no budget at all (tests, probes that call tools directly).
  static func reset() {
    state.withLock { $0 = State() }
  }

  /// Claim one tool call. Returns nil when this reply's call limit is spent, or when no reply
  /// is running any more (a tool round that outlived its reply).
  static func claim() -> Limits? {
    state.withLock { state in
      guard !state.closed else { return nil }
      let limits = state.limits ?? unrestricted
      guard state.calls < limits.maxCalls else { return nil }
      state.calls += 1
      return limits
    }
  }

  /// Total tool-result bytes delivered during the current reply.
  static var resultBytes: Int { state.withLock { $0.resultBytes } }

  /// Trim `text` to the limit (never splitting a character) and account for it.
  static func fit(_ text: String, _ limits: Limits) -> String {
    let fitted =
      text.utf8.count <= limits.maxResultBytes
      ? text : ContextBudget.prefix(text, maxBytes: max(0, limits.maxResultBytes - 3)) + "…"
    state.withLock { $0.resultBytes += fitted.utf8.count }
    return fitted
  }

  /// Result returned to the model when the call limit is reached.
  static var limitReachedResult: [String: Any] {
    ["error": "Tool limit reached for this reply. Answer with the information you already have."]
  }
}
