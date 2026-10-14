import Foundation
import SwiftData

/// Branching conversations and structured message parts.
///
/// - Turns form a tree: `parentID` points at the previous turn; edits and
///   regenerations create siblings. `ChatThread.activeLeafID` selects the
///   branch that is shown and replayed to the model.
/// - `partsData` holds tool activity and web/file sources (``MessageParts``).
enum SchemaV2: VersionedSchema {
  static let versionIdentifier = Schema.Version(2, 0, 0)
  static var models: [any PersistentModel.Type] { [ChatThread.self, ChatTurn.self] }

  @Model
  final class ChatThread {
    var id: UUID
    var title: String
    var createdAt: Date
    /// Last activity, for "recent" ordering.
    var updatedAt: Date = Date.distantPast
    var modelIDRaw: String
    var isPinned: Bool = false
    /// Last turn of the visible branch; nil = linear (legacy) ordering.
    var activeLeafID: UUID?
    @Relationship(deleteRule: .cascade, inverse: \ChatTurn.thread)
    var turns: [ChatTurn] = []

    init(title: String = "New chat", modelID: ModelID = .e4b) {
      self.id = UUID()
      self.title = title
      self.createdAt = Date()
      self.updatedAt = Date()
      self.modelIDRaw = modelID.rawValue
    }
  }

  @Model
  final class ChatTurn {
    var id: UUID
    var roleRaw: String
    var text: String
    var thought: String
    var toolNames: [String]
    var statsData: Data?
    @Attribute(.externalStorage)
    var imageData: Data?
    /// The user sent a voice message (the audio itself is not stored).
    var hasAudio: Bool = false
    var createdAt: Date
    /// Previous turn in the conversation tree (nil for the first turn).
    var parentID: UUID?
    /// JSON-encoded ``MessageParts`` (tool activity, sources).
    var partsData: Data?
    var thread: ChatThread?

    init(
      role: ChatRole, text: String = "", thought: String = "",
      toolNames: [String] = [], stats: GenerationStats? = nil,
      imageData: Data? = nil, hasAudio: Bool = false
    ) {
      self.id = UUID()
      self.roleRaw = role == .user ? "user" : "model"
      self.text = text
      self.thought = thought
      self.toolNames = toolNames
      self.statsData = stats.flatMap { try? JSONEncoder().encode($0) }
      self.imageData = imageData
      self.hasAudio = hasAudio
      self.createdAt = Date()
    }
  }
}
