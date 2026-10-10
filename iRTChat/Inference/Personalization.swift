import Foundation

/// What the user tells iRTChat about themselves and how it should respond.
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
  /// Base prompt, then personalization, then the project's instructions.
  static func compose(
    base: String, personalization: Personalization, project: ProjectContext?
  ) -> String {
    var prompt = personalization.systemPrompt(base: base)
    if let project {
      let instructions = String(
        project.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
          .prefix(ProjectContext.instructionLimit))
      var block = "This chat is part of the project \"\(project.name)\"."
      if !instructions.isEmpty { block += " Follow the project's instructions:\n\(instructions)" }
      prompt += "\n\n" + block
    }
    return prompt
  }
}
