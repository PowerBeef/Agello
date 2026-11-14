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

  /// Preamble for a conversation with `systemPrompt` (which grows with
  /// personalization), so long instructions can't overflow the window.
  static func preambleTokens(systemPrompt: String) -> Int {
    preambleTokens + estimateTokens(systemPrompt)
  }
  /// Per-turn template overhead (role markers, separators).
  static let perTurnOverhead = 8
  /// Never fill the window to the last token.
  static let safetyMargin = 64
  /// Smallest reply worth starting; below this the context is "full".
  static let minReplyTokens = 96
  /// Audio input token rate (conservative).
  static let audioTokensPerSecond = 25.0

  /// The model file's export window, the context size LiteRT-LM reads from it: 32,003 for the
  /// Gemma 4 E2B/E4B files as published. A file opened to the trained 131,072-token window
  /// (the fork's `tools/model-surgery/window_128k.py`) exports 131,101; development tools that
  /// load one say so with `AGELLO_EXPORT_WINDOW`.
  static let exportWindow: Int = {
    if let value = ProcessInfo.processInfo.environment["AGELLO_EXPORT_WINDOW"],
      let window = Int(value), window > 256
    {
      return window
    }
    return 32_003
  }()

  /// The most positions LiteRT-LM allocates: a `maxNumTokens` of the export window or more gets
  /// the largest multiple of 256 below it (32,000 for 32,003, 131,072 for 131,101), so a "32K"
  /// request of 32,768 has 768 fewer positions than it asks for.
  static let maxAllocatedPositions = (exportWindow - 1) / 256 * 256

  /// Positions the runtime allocates for a requested `maxNumTokens`. Budgets
  /// must use this, never the request: the margins that keep a reply (and an
  /// MTP verify round) inside the cache are only a few dozen positions.
  static func allocatedPositions(requested: Int) -> Int {
    requested >= exportWindow ? maxAllocatedPositions : requested
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

  /// Room kept free for the reply when history is trimmed: a quarter of the window for the
  /// answer plus the reasoning budget, at most a third. A long chat keeps less history, and every
  /// reply keeps room for a long answer (512 tokens until 2026-11-02 cut them short, probe 23).
  static func replyReserve(maxNumTokens: Int, thinkingBudget: Int?) -> Int {
    min(maxNumTokens / 3, maxNumTokens / 4 + (thinkingBudget ?? 0))
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
    return kept
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
  /// nil takes the device's default. An override (tests, probes) wins over both.
  static func resolve(
    options: InferenceOptions,
    model: ModelID,
    memoryBytes: UInt64,
    contextTokens: Int? = nil
  ) -> ResolvedInference {
    let maxNumTokens: Int
    if let override = options.maxNumTokensOverride {
      maxNumTokens = ContextBudget.allocatedPositions(
        requested: min(max(minTokens, override), maxTokens))
    } else {
      maxNumTokens = ContextBudget.allocatedPositions(
        requested: contextTokens ?? DeviceProfile.defaultMaxTokens(model: model, memoryBytes: memoryBytes))
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
