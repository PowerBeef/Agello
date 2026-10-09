import Foundation

// MARK: - Model identity

/// Downloadable models. Chats run Gemma 4 E4B only (stored identifiers
/// like "e2b" from earlier versions continue on E4B); EmbeddingGemma powers
/// search by meaning in files and memory.
enum ModelID: String, Codable, Sendable, CaseIterable, Identifiable {
  case e4b
  case embeddingGemma = "embeddinggemma-2-text-270m"

  var id: String { rawValue }

  /// Decodes a chat's stored model, mapping retired (and non-chat) models to E4B.
  init(storedValue: String) {
    let model = ModelID(rawValue: storedValue) ?? .e4b
    self = model == .embeddingGemma ? .e4b : model
  }
}

// MARK: - User-facing inference options

enum BackendPreference: String, Codable, Sendable, CaseIterable {
  case gpu
  case cpu
}

enum SamplerPreset: String, Codable, Sendable, CaseIterable {
  case precise
  case balanced
  case creative

  var topK: Int {
    switch self {
    case .precise: return 20
    case .balanced: return 40
    case .creative: return 60
    }
  }

  var topP: Float {
    switch self {
    case .precise: return 0.9
    case .balanced: return 0.95
    case .creative: return 0.98
    }
  }

  var temperature: Float {
    switch self {
    case .precise: return 0.2
    case .balanced: return 0.7
    case .creative: return 1.0
    }
  }

  var displayName: String {
    switch self {
    case .precise: return "Precise"
    case .balanced: return "Balanced"
    case .creative: return "Creative"
    }
  }
}

/// Visual token budget presets. Allowed Gemma 4 budgets are
/// 70 / 140 / 280 / 560 / 1120 tokens per image.
enum VisualDetail: String, Codable, Sendable, CaseIterable {
  case fast
  case balanced
  case detailed

  var tokenBudget: Int32 {
    switch self {
    case .fast: return 140
    case .balanced: return 280
    case .detailed: return 560
    }
  }

  var displayName: String {
    switch self {
    case .fast: return "Fast (140)"
    case .balanced: return "Balanced (280)"
    case .detailed: return "Detailed (560)"
    }
  }
}

/// Persisted user choices for inference. Resolved to concrete engine settings
/// by ``InferencePlanner`` together with the device profile.
struct InferenceOptions: Codable, Sendable, Equatable {
  var backendPreference: BackendPreference = .gpu
  /// KV-cache size override. `nil` means "auto" (device + model aware).
  var maxNumTokensOverride: Int? = nil
  var enableThinking: Bool = false
  var thinkingBudget: Int = 1024
  var samplerPreset: SamplerPreset = .balanced
  var systemPrompt: String = "You are a helpful on-device assistant."
  var enableVision: Bool = true
  var enableAudio: Bool = true
  var visualDetail: VisualDetail = .balanced
  /// Multi-Token Prediction / speculative decoding. Faster decode, same quality.
  var enableSpeculativeDecoding: Bool = true
  var maxOutputTokens: Int? = nil
  /// Drop reasoning-channel tokens from the KV cache. Longer effective
  /// context when thinking is on; the thought text still streams to the UI.
  var compactReasoningCache: Bool = false
}

// MARK: - Streaming types

/// One delta produced while a reply streams in. Always append-only.
struct ChatChunk: Sendable, Equatable {
  /// Newly generated answer text (may be empty for thought-only chunks).
  var textDelta: String
  /// Newly generated reasoning text when thinking is enabled.
  var thoughtDelta: String?
  /// Tool names invoked to produce this chunk (usually empty).
  var toolNames: [String] = []
  /// Tool runs (with user-facing summaries) completed since the last chunk.
  var toolActivity: [ToolActivityRecord] = []

  static let empty = ChatChunk(textDelta: "", thoughtDelta: nil)
}

/// Pure append-only accumulator for streamed chunks. Covered by unit tests.
struct StreamAccumulator: Sendable, Equatable {
  private(set) var text = ""
  private(set) var thought = ""
  private(set) var toolNames: [String] = []
  private(set) var toolActivity: [ToolActivityRecord] = []

  mutating func append(_ chunk: ChatChunk) {
    toolActivity += chunk.toolActivity
    text += chunk.textDelta
    if let thoughtDelta = chunk.thoughtDelta {
      thought += thoughtDelta
    }
    for name in chunk.toolNames where !toolNames.contains(name) {
      toolNames.append(name)
    }
  }

  var hasThought: Bool { !thought.isEmpty }
}

// MARK: - Stats & state

struct GenerationStats: Sendable, Codable, Equatable {
  var timeToFirstToken: TimeInterval?
  var totalTime: TimeInterval
  /// Token counts are best-effort (KV-cache deltas) and may be nil.
  var inputTokens: Int?
  var outputTokens: Int?
  var decodeTokensPerSecond: Double?
  var backend: String
  var modelID: ModelID

  var footerLine: String {
    var parts: [String] = []
    if let ttft = timeToFirstToken {
      parts.append(String(format: "TTFT %.1fs", ttft))
    }
    if let tokS = decodeTokensPerSecond {
      parts.append(String(format: "%.0f tok/s", tokS))
    }
    parts.append(backend)
    return parts.joined(separator: " · ")
  }
}

enum ChatEngineState: Sendable, Equatable {
  case idle
  case loading(progress: String)
  case ready
  case generating
  case failed(message: String)
}

enum ChatError: Error, Sendable, Equatable {
  case engineNotReady
  case modelFileMissing
  case generationCancelled
  /// No room left in the context window for a reply.
  case contextFull
  /// The message alone does not fit the context window.
  case messageTooLong
  /// The reply was stopped before it could overflow the context window.
  case replyTruncated
  case underlying(message: String)

  var displayMessage: String {
    switch self {
    case .engineNotReady: return "The model isn't loaded yet."
    case .modelFileMissing: return "Model file is missing. Please re-download it."
    case .generationCancelled: return "Generation stopped."
    case .contextFull:
      return "This conversation is too long for the model's memory. Start a new chat."
    case .replyTruncated:
      return "The reply was cut short because the model's memory filled up. Start a new chat for long answers."
    case .messageTooLong:
      return "This message is too long for the model's memory. Shorten it or raise the KV cache in Settings."
    case .underlying(let message): return message
    }
  }
}
