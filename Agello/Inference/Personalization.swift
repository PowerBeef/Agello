import Foundation

/// What the user tells Agello about themselves and how it should respond.
/// Stored apart from ``InferenceOptions`` and merged into the system prompt.
struct Personalization: Codable, Equatable, Sendable {
  enum Style: String, Codable, CaseIterable, Sendable {
    case standard, concise, detailed, friendly, professional

    var displayName: String {
      switch self {
      case .standard: return String(localized: "Default")
      case .concise: return String(localized: "Concise")
      case .detailed: return String(localized: "Detailed")
      case .friendly: return String(localized: "Friendly")
      case .professional: return String(localized: "Professional")
      }
    }

    var instruction: String? {
      switch self {
      case .standard: return nil
      case .concise: return "Keep answers short and to the point; skip preambles and summaries."
      case .detailed: return "Give thorough, well-structured answers with explanations and examples."
      case .friendly: return "Use a warm, conversational, encouraging tone."
      case .professional: return "Use a precise, formal, professional tone."
      }
    }
  }

  var enabled = true
  var name = ""
  var aboutYou = ""
  var instructions = ""
  var style: Style = .standard

  /// Per-field limit: keeps the system prompt (re-read on every reply) small.
  static let fieldLimit = 1000

  init() {}

  /// Tolerates missing keys, so fields can be added without losing settings.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    aboutYou = try container.decodeIfPresent(String.self, forKey: .aboutYou) ?? ""
    instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
    style = (try? container.decodeIfPresent(Style.self, forKey: .style)) ?? .standard
  }

  /// The system prompt the model receives: `base`, then what the user shared.
  func systemPrompt(base: String) -> String {
    var parts = [base.trimmingCharacters(in: .whitespacesAndNewlines)]
    if enabled {
      if let instruction = style.instruction { parts.append(instruction) }
      let name = Self.clean(name, limit: 80)
      if !name.isEmpty { parts.append("The user's name is \(name).") }
      let about = Self.clean(aboutYou, limit: Self.fieldLimit)
      if !about.isEmpty { parts.append("About the user:\n\(about)") }
      let instructions = Self.clean(instructions, limit: Self.fieldLimit)
      if !instructions.isEmpty { parts.append("How the user wants you to respond:\n\(instructions)") }
    }
    return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
  }

  private static func clean(_ text: String, limit: Int) -> String {
    String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
  }
}

/// The project of the chat the model is in: its instructions join the
/// system prompt.
struct ProjectContext: Equatable, Sendable {
  var id: UUID
  var name: String
  var instructions: String

  /// Per-project limit, like personalization fields.
  static let instructionLimit = 1_500
}

enum SystemPrompt {
  /// Memories added to the system prompt.
  static let memoryLimit = 25
  /// With more saved than ``memoryLimit``, a chat gets the most recent this many, then the rest
  /// closest in meaning to its first message (2026-11-16; before, only the most recent).
  static let recentMemories = 10
  /// Memories ranked for a chat at most (the most recent).
  static let memoryCandidateLimit = 500

  /// Where the model can point for current information, the base's `{current}` slot.
  enum CurrentInfo: Sendable {
    /// No web search: what may be out of date is only said to be.
    case none
    /// Search is allowed and the user turns it on per message.
    case tapSearch
    /// The model offers itself `web_search` (automatic search).
    case automaticSearch

    init(webSettings: WebSearchSettings) {
      self = webSettings.allowed ? (webSettings.automatic ? .automaticSearch : .tapSearch) : .none
    }

    var clause: String {
      switch self {
      case .none: ""
      case .tapSearch: "; the user can tap Search for current information"
      case .automaticSearch: "; use web_search when a question needs current facts"
      }
    }
  }

  /// The chat's base prompt: docs/SYSTEM-PROMPT.md's D4, the lead of probe 34's confirmation
  /// round (2026-11-17, 133 of 137 checks against 61 of 75 for the one line before it, "You are
  /// a helpful on-device assistant."). Its slots are filled by ``fill(_:today:current:precedence:)``.
  static let base = """
    You are Agello, an assistant running on the user's iPhone. Today is {date}.

    Your training data ends in early 2025, so trust today's date over your own sense of the year, and mention the date only when the answer depends on it. For anything that may have changed since then, give what you know and say it may be out of date{current}.

    Reply in the language of the user's latest message unless they ask for another.

    Start with the answer, not a preamble. Write conversational replies as plain paragraphs. Use headings, lists or a narrow table only when a long or structured answer needs them. Don't use emoji unless the user does.

    For open-ended requests such as recommendations, names, messages, plans or recipes, don't ask about preferences first: make sensible assumptions and give your answer, and the user can refine it. Ask a question only when you can't proceed without the answer.

    If you're unsure of a fact, say so in a few words and still give your best answer.{precedence}
    """

  /// Said after the base only when the user's preferences or a project follow it.
  static let precedenceLine =
    "The user's preferences and project instructions below take precedence over these defaults."

  /// `base` with its slots filled: `{date}` as today's date in English (the device's language
  /// had gone into English replies), `{current}` from the search settings, `{precedence}` when
  /// `precedence`. A base without slots comes back unchanged.
  ///
  /// The date changes the prompt at midnight. A chat that's already open keeps the conversation
  /// it was built with until its next rebuild (another chat, a reseed, a setting): comparing the
  /// prompt happens only when a chat is bound, so a chat isn't rebuilt for the date alone.
  static func fill(_ base: String, today: Date, current: CurrentInfo, precedence: Bool) -> String {
    base
      .replacingOccurrences(of: "{date}", with: PromptText.date(today))
      .replacingOccurrences(of: "{current}", with: current.clause)
      .replacingOccurrences(of: "{precedence}", with: precedence ? "\n\n" + precedenceLine : "")
  }

  /// Base prompt, personalization, saved memories, then the project's
  /// instructions.
  static func compose(
    base: String, personalization: Personalization, project: ProjectContext?,
    memories: [String] = [], today: Date = .now, current: CurrentInfo = .none
  ) -> String {
    composeText(
      base: base, personalization: personalization, project: project, memories: memories,
      today: today, current: current)
  }

  private static func composeText(
    base: String, personalization: Personalization, project: ProjectContext?,
    memories: [String], today: Date, current: CurrentInfo
  ) -> String {
    let preferences = !personalization.systemPrompt(base: "").isEmpty
    let base = fill(base, today: today, current: current, precedence: preferences || project != nil)
    var prompt = personalization.systemPrompt(base: base)
    if !memories.isEmpty {
      let list = memories.prefix(memoryLimit).map { "- \($0)" }.joined(separator: "\n")
      prompt +=
        "\n\nWhat you remember about the user from earlier chats (use it when relevant; "
        + "don't recite this list):\n\(list)"
    }
    if let project {
      let instructions = String(
        project.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
          .prefix(ProjectContext.instructionLimit))
      // The name capped like a title: instructions have their own limit.
      let name = String(project.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
      var block = "This chat is part of the project \"\(name)\"."
      if !instructions.isEmpty { block += " Follow the project's instructions:\n\(instructions)" }
      prompt += "\n\n" + block
    }
    return prompt
  }
}
