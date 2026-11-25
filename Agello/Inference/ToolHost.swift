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
    Log.generation.info("tool \(name, privacy: .public): \(summary, privacy: .private)")
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

/// Concurrency-safe bounded ring buffer capturing typed ``ActionCardRecord``s emitted by Swift
/// tools during a reply. Mirrors ``ToolActivity``'s cursor contract (immune to LiteRT-LM's C++
/// callback thread boundary where `@TaskLocal` does not propagate) while staying O(1) memory
/// across long soak sessions.
enum ToolCardRecorder {
  static let capacity = 64

  private struct Entry {
    var sequence: Int
    var card: ActionCardRecord
  }

  private struct State {
    var entries: [Entry] = []
    var nextSequence = 0
  }

  private static let state = Mutex(State())

  static func record(_ card: ActionCardRecord) {
    guard card.isRenderable else { return }
    state.withLock { s in
      s.entries.append(Entry(sequence: s.nextSequence, card: card))
      s.nextSequence += 1
      if s.entries.count > capacity {
        s.entries.removeFirst(s.entries.count - capacity)
      }
    }
  }

  static func record(_ payload: ActionCardRecord.Payload) {
    record(ActionCardRecord(payload: payload))
  }

  /// Monotonic cursor for ``records(since:)``.
  static var cursor: Int { state.withLock { $0.nextSequence } }

  /// Action cards recorded at or after `cursor`, in insertion order.
  static func records(since cursor: Int) -> [ActionCardRecord] {
    state.withLock { s in
      s.entries.filter { $0.sequence >= cursor }.map(\.card)
    }
  }

  /// Clears buffered cards while preserving monotonic sequence numbers (for unit test isolation).
  static func reset() {
    state.withLock { $0.entries.removeAll(keepingCapacity: true) }
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
    /// Each follow-up tool round's reasoning budget (nil without Think), clamped to `followUpCap`.
    var followUpThinkingBudget: Int?
    var limits: Limits
  }

  /// Tokens a Think round keeps for its answer after reasoning.
  static let answerTokens = 256

  /// Split `room` (tokens) for one reply. Tool rounds run inside LiteRT-LM, so whenever any tool
  /// is registered (including `web_search` alone) the room is split so every tool result plus its
  /// follow-up generation fits strictly inside `room`:
  /// - Smaller rooms (`< 16,384` tokens): up to 2 tool calls, an eighth per result.
  /// - Large rooms (`>= 16,384` tokens, e.g. 64K context): up to 4 tool calls, a sixteenth per
  ///   result (still 1,000–4,000 tokens per result), enabling multi-step Think + parallel research.
  /// Without tools the reply gets the whole room. `maxOutputTokens` caps every round; the reasoning
  /// budget always leaves an answer room.
  static func plan(
    room: Int, toolsOffered: Bool, thinkingBudget: Int? = nil, maxOutputTokens: Int? = nil
  ) -> Plan {
    let limit = maxOutputTokens ?? .max
    guard toolsOffered else {
      let cap = min(room, limit)
      let reasoningBudget = thinkingBudget.map { reasoning($0, cap: cap) }
      return Plan(
        outputCap: cap, followUpCap: cap,
        thinkingBudget: reasoningBudget, followUpThinkingBudget: reasoningBudget,
        limits: Limits(maxResultTokens: room / 8, maxCalls: 0))
    }
    let maxCalls = room >= 16_384 ? 4 : 2
    let resultTokens = room / (maxCalls * 4)
    let laterFloor = room / (maxCalls * 8)
    let laterRound = min(resultTokens, max(laterFloor, thinkingBudget.map { $0 + answerTokens } ?? 0))
    let first = min(
      room - maxCalls * resultTokens - maxCalls * laterRound,
      room / 2 + (thinkingBudget ?? 0))
    let followUp = (room - first - maxCalls * resultTokens) / maxCalls
    let cap = min(first, limit)
    let followCap = min(followUp, limit)
    return Plan(
      outputCap: cap, followUpCap: followCap,
      thinkingBudget: thinkingBudget.map { reasoning($0, cap: cap) },
      followUpThinkingBudget: thinkingBudget.map { reasoning($0, cap: followCap) },
      limits: Limits(maxResultTokens: resultTokens, maxCalls: maxCalls))
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
