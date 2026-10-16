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
    /// Largest tool result (estimated tokens, ``ContextBudget/estimateTextTokens(_:)``) the
    /// context can absorb.
    var maxResultTokens: Int
    /// Tool calls allowed for this reply.
    var maxCalls: Int
  }

  /// Used before any reply set a budget (tests, probes calling tools directly).
  static let unrestricted = Limits(maxResultTokens: 5_000, maxCalls: .max)

  /// A reply's share of the context room.
  struct Plan: Sendable, Equatable {
    /// Largest output of the first generation round, reasoning included.
    var outputCap: Int
    /// Largest output of each round after a tool result.
    var followUpCap: Int
    /// The first round's reasoning budget (nil without Think), sized to leave an answer room.
    var thinkingBudget: Int?
    var limits: Limits
  }

  /// Tokens a Think round keeps for its answer after reasoning.
  static let answerTokens = 256

  /// Split `room` (tokens) for one reply. Tool rounds run inside LiteRT-LM, so whenever any tool
  /// is registered (including `web_search` alone) the room is split: an eighth per tool result,
  /// at most two calls, and the three generation rounds share the rest (a quarter each without
  /// Think). With Think the first round grows to its reasoning budget plus an answer, up to half
  /// the room, and the later rounds share what's left. Without tools the reply gets the whole
  /// room. `maxOutputTokens` caps every round; the reasoning budget always leaves an answer room.
  static func plan(
    room: Int, toolsOffered: Bool, thinkingBudget: Int? = nil, maxOutputTokens: Int? = nil
  ) -> Plan {
    let resultTokens = room / 8
    let limit = maxOutputTokens ?? .max
    guard toolsOffered else {
      let cap = min(room, limit)
      return Plan(
        outputCap: cap, followUpCap: cap, thinkingBudget: thinkingBudget.map { reasoning($0, cap: cap) },
        limits: Limits(maxResultTokens: resultTokens, maxCalls: 0))
    }
    let first = min(room / 2, max(room / 4, thinkingBudget.map { $0 + answerTokens } ?? 0))
    let followUp = (room - first - 2 * resultTokens) / 2
    let cap = min(first, limit)
    return Plan(
      outputCap: cap, followUpCap: min(followUp, limit),
      thinkingBudget: thinkingBudget.map { reasoning($0, cap: cap) },
      limits: Limits(maxResultTokens: resultTokens, maxCalls: 2))
  }

  /// The reasoning budget that leaves a round of `cap` tokens room for its answer:
  /// ``answerTokens``, or half the round when it's small.
  static func reasoning(_ budget: Int, cap: Int) -> Int {
    max(0, min(budget, max(cap / 2, cap - answerTokens)))
  }

  private struct State {
    var limits: Limits?
    var calls = 0
    var resultTokens = 0
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

  /// Estimated tokens of the tool results delivered during the current reply.
  static var resultTokens: Int { state.withLock { $0.resultTokens } }

  /// Trim `text` to the limit (never splitting a character) and account for it. Estimates err
  /// high (a token per digit or ideograph), so a table of numbers can't overflow the room.
  static func fit(_ text: String, _ limits: Limits) -> String {
    var fitted = text
    var tokens = ContextBudget.estimateTextTokens(text)
    if tokens > limits.maxResultTokens {
      // The ellipsis takes a token.
      let room = max(0, limits.maxResultTokens - 1)
      var maxBytes = Int(Double(text.utf8.count) * Double(room) / Double(tokens))
      repeat {
        fitted = ContextBudget.prefix(text, maxBytes: maxBytes)
        maxBytes = maxBytes * 9 / 10
      } while ContextBudget.estimateTextTokens(fitted) > room && maxBytes > 0
      if ContextBudget.estimateTextTokens(fitted) > room { fitted = "" }
      fitted += "…"
      tokens = ContextBudget.estimateTextTokens(fitted)
    }
    state.withLock { $0.resultTokens += tokens }
    return fitted
  }

  /// Result returned to the model when the call limit is reached.
  static var limitReachedResult: [String: Any] {
    ["error": "Tool limit reached for this reply. Answer with the information you already have."]
  }
}
