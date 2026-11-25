import Foundation

/// Fully resolved engine settings. Pure value produced by ``InferencePlanner``
/// and mapped onto LiteRT-LM types at the engine boundary.
struct ResolvedInference: Sendable, Equatable {
  var maxNumTokens: Int
  var enableVision: Bool
  var enableAudio: Bool
  /// Thinking token budget, or nil when thinking is disabled.
  var thinkingBudget: Int?
  var topK: Int
  var topP: Float
  var temperature: Float
  var visualTokenBudget: Int32?
  var enableSpeculativeDecoding: Bool
  var maxOutputTokens: Int?

  /// The language model runs on the GPU (Metal), with no other backend.
  var backendLabel: String { "GPU" }
}

/// Model-file capabilities from `ModelInfo` introspection (no engine needed).
struct ModelCapabilities: Sendable, Equatable {
  var speculativeDecoding: Bool
  var thinking: Bool
  var functionCalling: Bool
  var vision: Bool
  var audio: Bool
  /// -1 when the model has no vision budget info.
  var maxVisionTokenBudget: Int
  var maxContextTokens: Int
  var dynamicContext: Bool

  /// Assume full support (used when introspection is unavailable, e.g. mocks).
  static let full = ModelCapabilities(
    speculativeDecoding: true, thinking: true, functionCalling: true,
    vision: true, audio: true, maxVisionTokenBudget: -1,
    maxContextTokens: 0, dynamicContext: true
  )
}

/// KV-cache (context window) budgeting. Overflowing the cache corrupts
/// LiteRT-LM's native heap and crashes the app, so every send must fit:
/// tokens already in the cache + the new message + the reply cap <= window.
///
/// The engine counts exactly with the model's own tokenizer (probe 17); these estimates stand in
/// where it can't (the scripted engine, file and web budgets) and err high.
enum ContextBudget {
  /// Bytes per token used for estimates. Gemma averages ~4+ bytes/token on
  /// English; 3 leaves headroom for code and other scripts.
  static let bytesPerToken = 3.0
  /// Tool schemas + chat template + a short system prompt, before any turn.
  static let preambleTokens = 256

  /// Estimates tokens occupied by serialized tool JSON declarations (empty or `"[]"` -> 0).
  static func estimateToolSchemaTokens(_ toolsJsonDescription: String) -> Int {
    let trimmed = toolsJsonDescription.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "[]" else { return 0 }
    return estimateTextTokens(trimmed)
  }

  /// Preamble for a conversation with `systemPrompt` (which grows with personalization) and active
  /// tool declarations (`toolSchemaTokens` measured from `ToolManager.toolsJsonDescription`, or a
  /// conservative per-tool estimate when only `toolCount` is known).
  static func preambleTokens(
    systemPrompt: String, toolCount: Int = 0, toolSchemaTokens: Int? = nil
  ) -> Int {
    let toolTokens: Int
    if let toolSchemaTokens {
      toolTokens = max(0, toolSchemaTokens)
    } else {
      toolTokens = max(0, toolCount - 3) * 140
    }
    return preambleTokens + estimateTokens(systemPrompt) + toolTokens
  }
  /// Per-turn template overhead (role markers, separators).
  static let perTurnOverhead = 8
  /// Never fill the window to the last token.
  static let safetyMargin = 64
  /// Smallest reply worth starting; below this the context is "full".
  static let minReplyTokens = 96
  /// Audio input token rate (conservative).
  static let audioTokensPerSecond = 25.0

  /// The export window assumed when a model file can't be inspected: 32,003, the Gemma 4 E2B/E4B
  /// files' as published, or `AGELLO_EXPORT_WINDOW`. A load reads the file's own
  /// (``exportWindow(reported:)``): a file opened to the trained 131,072-token window (the fork's
  /// `tools/model-surgery/window_128k.py`) exports 131,101.
  static let exportWindow: Int = {
    #if DEBUG || BENCH
      if let value = ProcessInfo.processInfo.environment["AGELLO_EXPORT_WINDOW"],
        let window = Int(value), window > 256
      {
        return window
      }
    #endif
    return 32_003
  }()

  /// The most positions LiteRT-LM allocates: a `maxNumTokens` of the export window or more gets
  /// the largest multiple of 256 below it (32,000 for 32,003, 131,072 for 131,101), so a "32K"
  /// request of 32,768 has 768 fewer positions than it asks for.
  static let maxAllocatedPositions = maxAllocatedPositions(exportWindow: exportWindow)

  /// The export window of a file that reports `reported` (ModelInfo's maxContextTokens), or
  /// ``exportWindow`` when it reports nothing usable.
  static func exportWindow(reported: Int?) -> Int {
    if let reported, reported > 256 { return reported }
    return exportWindow
  }

  /// The most positions LiteRT-LM allocates for a file of `exportWindow`.
  static func maxAllocatedPositions(exportWindow: Int) -> Int { (exportWindow - 1) / 256 * 256 }

  /// Positions the runtime allocates for a requested `maxNumTokens`. Budgets
  /// must use this, never the request: the margins that keep a reply (and an
  /// MTP verify round) inside the cache are only a few dozen positions.
  static func allocatedPositions(requested: Int, exportWindow: Int = exportWindow) -> Int {
    requested >= exportWindow ? maxAllocatedPositions(exportWindow: exportWindow) : requested
  }

  /// Tokens `text` takes, estimated without the model's tokenizer: 3 bytes a token, or about a
  /// token per digit, ideograph or kana (``Chunker/weight(of:)``), whichever is more. Gemma
  /// splits numbers into single digits, so digit-heavy text costs a token per byte.
  static func estimateTextTokens<S: StringProtocol>(_ text: S) -> Int {
    estimateTextTokens(bytes: text.utf8.count, weight: Chunker.weight(of: text))
  }

  /// ``estimateTextTokens(_:)`` from running totals of UTF-8 bytes and ``Chunker/weight(of:)``.
  static func estimateTextTokens(bytes: Int, weight: Int) -> Int {
    Int(max(Double(bytes) / bytesPerToken, Double(weight) / 4).rounded(.up))
  }

  /// A turn's estimated tokens: its text and the template around it.
  static func estimateTokens(_ text: String) -> Int {
    estimateTextTokens(text) + perTurnOverhead
  }

  /// Tokens an attached image or voice message adds to a message.
  static func mediaTokens(imageTokens: Int?, audioSeconds: Double?) -> Int {
    var total = 0
    if let imageTokens { total += imageTokens + perTurnOverhead }
    if let audioSeconds { total += Int((audioSeconds * audioTokensPerSecond).rounded(.up)) }
    return total
  }

  static func estimateInput(text: String, imageTokens: Int?, audioSeconds: Double?) -> Int {
    estimateTokens(text) + mediaTokens(imageTokens: imageTokens, audioSeconds: audioSeconds)
  }

  static func estimateHistory(_ history: [(role: ChatRole, text: String)]) -> Int {
    history.reduce(0) { $0 + estimateTokens($1.text) }
  }

  /// Cap on the answer portion of ``replyReserve(maxNumTokens:thinkingBudget:)``.
  /// Preserves ~56–60K usable single-prompt tokens in a 64K window while reserving full room for
  /// long answers plus any Think reasoning budget.
  static let maxAnswerReserve = 4_096

  /// Room kept free for the reply when history is trimmed: up to ``maxAnswerReserve`` (or a
  /// quarter of smaller windows) for the answer plus the reasoning budget, capped at a third of
  /// the window.
  static func replyReserve(maxNumTokens: Int, thinkingBudget: Int?) -> Int {
    min(maxNumTokens / 3, min(maxNumTokens / 4, maxAnswerReserve) + (thinkingBudget ?? 0))
  }

  /// Whether `used` cached tokens + `input` + a reply reserve fit the window.
  static func fits(used: Int, input: Int, maxNumTokens: Int, thinkingBudget: Int?) -> Bool {
    used + input + replyReserve(maxNumTokens: maxNumTokens, thinkingBudget: thinkingBudget)
      + safetyMargin <= maxNumTokens
  }

  /// Token budget for replayed history after trimming: leave room for the
  /// preamble, the new message, and a reply, and use at most half the window
  /// so the next turns don't immediately trim again.
  static func historyBudget(
    maxNumTokens: Int, input: Int, thinkingBudget: Int?, preamble: Int = preambleTokens
  ) -> Int {
    let room =
      maxNumTokens - preamble - input
      - replyReserve(maxNumTokens: maxNumTokens, thinkingBudget: thinkingBudget) - safetyMargin
    return max(0, min(maxNumTokens / 2, room))
  }

  /// Smallest useful remnant of a truncated reply.
  static let minTruncatedTokens = 48

  /// The newest turns that fit `budget`, starting on a user turn. When a reply is too long to
  /// keep whole, the exchange is kept with the reply truncated, rather than losing the latest
  /// context entirely. `tokens` holds each turn's text tokens when the engine counted them
  /// exactly; without it they're estimated. Each turn adds ``perTurnOverhead``.
  static func trimmedHistory(
    _ history: [(role: ChatRole, text: String)], budget: Int, tokens: [Int]? = nil
  ) -> [(role: ChatRole, text: String)] {
    trimHistory(history, budget: budget, tokens: tokens).kept
  }

  /// Splits `history` into the newest turns that fit `budget` (`kept`, starting on a user turn)
  /// and the older turns dropped from the front (`evicted`) so callers can semantically recall
  /// relevant earlier facts.
  static func trimHistory(
    _ history: [(role: ChatRole, text: String)], budget: Int, tokens: [Int]? = nil
  ) -> (kept: [(role: ChatRole, text: String)], evicted: [(role: ChatRole, text: String)]) {
    let textTokens =
      tokens.flatMap { $0.count == history.count ? $0 : nil }
      ?? history.map { estimateTextTokens($0.text) }
    func cost(_ index: Int) -> Int { textTokens[index] + perTurnOverhead }
    /// `history[index]`'s text cut to about `room` tokens of its own, with an ellipsis.
    func truncated(_ index: Int, room: Int) -> (role: ChatRole, text: String) {
      let text = history[index].text
      let maxBytes = Int(Double(text.utf8.count) * Double(room) / Double(max(1, textTokens[index])))
      return (history[index].role, prefix(text, maxBytes: maxBytes) + "…")
    }
    var kept: [(role: ChatRole, text: String)] = []
    var total = 0
    var index = history.count - 1
    while index >= 0 {
      let turn = history[index]
      if total + cost(index) <= budget {
        kept.insert(turn, at: 0)
        total += cost(index)
        index -= 1
        continue
      }
      if turn.role == .model, index > 0, history[index - 1].role == .user {
        // Room for the reply's text, minus its template overhead and the ellipsis.
        let room = budget - total - cost(index - 1) - perTurnOverhead - 2
        if room >= minTruncatedTokens {
          kept.insert(truncated(index, room: room), at: 0)
          kept.insert(history[index - 1], at: 0)
        }
      }
      break
    }
    // The oldest kept turn may be a reply whose prompt didn't fit: shrink the
    // reply to make room for its prompt rather than dropping the exchange.
    if let first = kept.first, first.role == .model, index >= 0, history[index].role == .user {
      let others = total - cost(index + 1)
      let room = budget - others - cost(index) - perTurnOverhead - 2
      if room >= minTruncatedTokens {
        kept[0] = truncated(index + 1, room: room)
        kept.insert(history[index], at: 0)
      }
    }
    while let first = kept.first, first.role != .user { kept.removeFirst() }
    let evictedCount = max(0, history.count - kept.count)
    return (kept, Array(history.prefix(evictedCount)))
  }

  /// Upper bound on tokens reserved for semantically recalled evicted turns.
  static let maxRecallTokens = 1_536

  /// Token budget for recalled snippets from evicted turns, scaled gently with the window so
  /// recall never crowds out recent turns or the answer.
  static func recallBudget(maxNumTokens: Int) -> Int {
    max(0, min(maxRecallTokens, maxNumTokens / 16))
  }

  /// Pairs evicted turns into compact user/assistant exchanges suitable for semantic or BM25
  /// recall. Long turns are capped to keep recalled snippets focused.
  static func evictedExchanges(_ evicted: [(role: ChatRole, text: String)]) -> [String] {
    var exchanges: [String] = []
    var index = 0
    let perTurnMaxBytes = 1_200
    func compact(_ text: String) -> String {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.utf8.count > perTurnMaxBytes else { return trimmed }
      return prefix(trimmed, maxBytes: perTurnMaxBytes) + "…"
    }
    while index < evicted.count {
      let current = evicted[index]
      let currentText = compact(current.text)
      if current.role == .user, index + 1 < evicted.count, evicted[index + 1].role == .model {
        let replyText = compact(evicted[index + 1].text)
        if !currentText.isEmpty || !replyText.isEmpty {
          exchanges.append("User: \(currentText)\nAssistant: \(replyText)")
        }
        index += 2
      } else {
        if !currentText.isEmpty {
          let label = current.role == .user ? "User" : "Assistant"
          exchanges.append("\(label): \(currentText)")
        }
        index += 1
      }
    }
    return exchanges
  }

  /// Formats the top-ranked recalled exchanges within `budget` tokens, or nil when none fit.
  static func recalledContext(exchanges: [String], budget: Int) -> String? {
    guard !exchanges.isEmpty, budget >= minTruncatedTokens else { return nil }
    let header = "[Earlier in this conversation — recalled for relevance]"
    var used = estimateTextTokens(header) + 4
    var selected: [String] = []
    for exchange in exchanges {
      let cost = estimateTextTokens(exchange) + 2
      if used + cost <= budget {
        selected.append(exchange)
        used += cost
      } else if selected.isEmpty {
        let room = budget - used - 2
        if room >= minTruncatedTokens {
          let maxBytes = Int(Double(room) * bytesPerToken)
          selected.append(prefix(exchange, maxBytes: maxBytes) + "…")
        }
        break
      }
    }
    guard !selected.isEmpty else { return nil }
    return header + "\n" + selected.joined(separator: "\n---\n")
  }

  /// Prepends a recalled-history block to `prompt` when present.
  static func promptWithRecall(_ recall: String?, prompt: String) -> String {
    guard let recall, !recall.isEmpty else { return prompt }
    return recall + "\n\n" + prompt
  }

  /// Longest prefix of `text` within `maxBytes` UTF-8 bytes (never splits a character).
  static func prefix(_ text: String, maxBytes: Int) -> String {
    var bytes = 0
    var end = text.startIndex
    for index in text.indices {
      let size = text[index].utf8.count
      if bytes + size > maxBytes { break }
      bytes += size
      end = text.index(after: index)
    }
    return String(text[..<end])
  }

  /// Largest safe reply length, or nil when not even ``minReplyTokens`` fit.
  static func outputCap(maxNumTokens: Int, used: Int, input: Int) -> Int? {
    let room = maxNumTokens - used - input - safetyMargin
    return room >= minReplyTokens ? room : nil
  }
}

enum InferencePlanner {
  static let minTokens = 256
  /// Gemma 4 E2B/E4B are trained for 128K, but the published files export a 32K
  /// window and LiteRT-LM allocates at most 32,000 positions (131,072 with a file
  /// opened to 128K, ``ContextBudget/exportWindow``); within that the practical
  /// ceiling is device memory (see DeviceProfile and the calibration scenario).
  static let maxTokens = ContextBudget.maxAllocatedPositions

  /// Resolve user options + model + device into concrete engine settings. `contextTokens` is the
  /// window chosen for this load from the memory left (``DeviceProfile/contextTokens(standard:roomBytes:)``);
  /// nil takes the device's default. An override (tests, probes) wins over both. `exportWindow` is
  /// the model file's (``ContextBudget/exportWindow(reported:)``): what the runtime can allocate.
  static func resolve(
    options: InferenceOptions,
    model: ModelID,
    memoryBytes: UInt64,
    contextTokens: Int? = nil,
    exportWindow: Int = ContextBudget.exportWindow
  ) -> ResolvedInference {
    let maxNumTokens: Int
    if let override = options.maxNumTokensOverride {
      maxNumTokens = ContextBudget.allocatedPositions(
        requested: min(max(minTokens, override), ContextBudget.maxAllocatedPositions(exportWindow: exportWindow)),
        exportWindow: exportWindow)
    } else {
      maxNumTokens = ContextBudget.allocatedPositions(
        requested: contextTokens ?? DeviceProfile.defaultMaxTokens(model: model, memoryBytes: memoryBytes),
        exportWindow: exportWindow)
    }

    return ResolvedInference(
      maxNumTokens: maxNumTokens,
      enableVision: options.enableVision,
      enableAudio: options.enableAudio,
      thinkingBudget: options.enableThinking ? max(128, options.thinkingBudget) : nil,
      topK: options.samplerPreset.topK,
      topP: options.samplerPreset.topP,
      temperature: options.samplerPreset.temperature,
      visualTokenBudget: options.enableVision ? options.visualDetail.tokenBudget : nil,
      enableSpeculativeDecoding: options.enableSpeculativeDecoding,
      maxOutputTokens: options.maxOutputTokens
    )
  }

  /// Intersect resolved settings with model-file capabilities. Turns off MTP,
  /// thinking, and modalities the file lacks, and clamps the visual budget
  /// and KV cache to the model's stated limits.
  static func applyCapabilities(
    _ caps: ModelCapabilities, to resolved: ResolvedInference
  ) -> ResolvedInference {
    var out = resolved
    if !caps.speculativeDecoding { out.enableSpeculativeDecoding = false }
    // `caps.thinking` (like `caps.functionCalling`) is not trusted: the
    // Gemma 4 E2B file reports false for both, yet streams reasoning and
    // calls tools on device. Thinking stays a user choice.
    out.enableVision = out.enableVision && caps.vision
    out.enableAudio = out.enableAudio && caps.audio
    if !out.enableVision {
      out.visualTokenBudget = nil
    } else if let budget = out.visualTokenBudget {
      // A file that doesn't say gets Gemma 4's default, the most its phone files accept.
      let limit =
        caps.maxVisionTokenBudget > 0 ? caps.maxVisionTokenBudget : VisualDetail.defaultLimit
      out.visualTokenBudget = min(budget, Int32(limit))
    }
    if caps.maxContextTokens > 0 {
      out.maxNumTokens = min(out.maxNumTokens, caps.maxContextTokens)
    }
    return out
  }

  /// Whether moving from the plan an engine was built for (`built`, before
  /// any fallback) to `requested` needs a new Engine. KV size,
  /// vision/audio executors, and MTP are fixed at Engine creation.
  static func requiresEngineReload(built: ResolvedInference, requested: ResolvedInference)
    -> Bool
  {
    built.maxNumTokens != requested.maxNumTokens
      || built.enableVision != requested.enableVision
      || built.enableAudio != requested.enableAudio
      || built.enableSpeculativeDecoding != requested.enableSpeculativeDecoding
  }

  /// Conversation-level settings from `plan` applied on top of the engine
  /// actually running (`engine`, after fallbacks): never claims vision/audio
  /// or a backend the engine doesn't have.
  static func conversationUpdate(engine: ResolvedInference, plan: ResolvedInference)
    -> ResolvedInference
  {
    var out = engine
    out.thinkingBudget = plan.thinkingBudget
    out.topK = plan.topK
    out.topP = plan.topP
    out.temperature = plan.temperature
    out.maxOutputTokens = plan.maxOutputTokens
    out.visualTokenBudget = engine.enableVision ? plan.visualTokenBudget : nil
    return out
  }

  /// Ordered engine-init attempts: the plan, then the same without vision and audio (a model
  /// file can lack their executors). One attempt when the plan is already text-only. There's no
  /// other backend to fall back to: a GPU load that fails is retried and then reported.
  static func attempts(for plan: ResolvedInference) -> [ResolvedInference] {
    var textOnly = plan
    textOnly.enableVision = false
    textOnly.enableAudio = false
    textOnly.visualTokenBudget = nil
    return textOnly == plan ? [plan] : [plan, textOnly]
  }
}
