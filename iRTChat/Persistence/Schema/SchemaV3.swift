import Foundation
import SwiftData

/// Files, projects, and memory.
///
/// - `Project`: a folder of chats sharing instructions and files
///   (`ChatThread.projectID`).
/// - `ChatDocument`: an attached file's extracted text, attached to a chat
///   (`threadID`) or a project (`projectID`), split into `DocumentChunk`s
///   with page ranges and embeddings for retrieval.
/// - `MemoryItem`: a short fact the user chose to keep across chats.
///
/// References between models are IDs, not relationships (except a
/// document's chunks), so later migrations stay lightweight.
enum SchemaV3: VersionedSchema {
  static let versionIdentifier = Schema.Version(3, 0, 0)
  static var models: [any PersistentModel.Type] {
    [
      ChatThread.self, ChatTurn.self, Project.self, ChatDocument.self, DocumentChunk.self,
      MemoryItem.self,
    ]
  }

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
    /// The project this chat belongs to, if any.
    var projectID: UUID?
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
    /// JSON-encoded ``MessageParts`` (tool activity, sources, files).
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

  @Model
  final class Project {
    var id: UUID
    var name: String
    /// Added to the system prompt of every chat in the project.
    var instructions: String = ""
    var createdAt: Date
    var updatedAt: Date

    init(name: String) {
      self.id = UUID()
      self.name = name
      self.createdAt = Date()
      self.updatedAt = Date()
    }
  }

  @Model
  final class ChatDocument {
    var id: UUID
    var name: String
    /// ``DocumentKind`` raw value.
    var kindRaw: String
    var byteCount: Int64
    /// Pages for PDFs and scans; 0 for plain text.
    var pageCount: Int
    var createdAt: Date
    /// Attached to a chat…
    var threadID: UUID?
    /// …or to a project (shared by its chats).
    var projectID: UUID?
    /// The extracted text, with page markers for paged documents.
    var text: String
    /// Identifier of the embedding model that indexed the chunks; nil until
    /// indexed (or when the index must be rebuilt).
    var indexedWith: String?
    @Relationship(deleteRule: .cascade, inverse: \DocumentChunk.document)
    var chunks: [DocumentChunk] = []

    init(
      name: String, kindRaw: String, byteCount: Int64, pageCount: Int, text: String,
      threadID: UUID? = nil, projectID: UUID? = nil
    ) {
      self.id = UUID()
      self.name = name
      self.kindRaw = kindRaw
      self.byteCount = byteCount
      self.pageCount = pageCount
      self.text = text
      self.threadID = threadID
      self.projectID = projectID
      self.createdAt = Date()
    }
  }

  @Model
  final class DocumentChunk {
    var id: UUID
    /// Position in the document (0-based).
    var index: Int
    var text: String
    /// First and last page the chunk covers (1-based), for citations.
    var pageStart: Int?
    var pageEnd: Int?
    /// Float16 vector from the embedding model (see ``VectorIndex``).
    var embedding: Data?
    var document: ChatDocument?

    init(index: Int, text: String, pageStart: Int?, pageEnd: Int?) {
      self.id = UUID()
      self.index = index
      self.text = text
      self.pageStart = pageStart
      self.pageEnd = pageEnd
    }
  }

  @Model
  final class MemoryItem {
    var id: UUID
    var text: String
    var createdAt: Date
    var updatedAt: Date
    /// The chat it was learned in, if any.
    var sourceThreadID: UUID?
    var embedding: Data?

    init(text: String, sourceThreadID: UUID? = nil) {
      self.id = UUID()
      self.text = text
      self.createdAt = Date()
      self.updatedAt = Date()
      self.sourceThreadID = sourceThreadID
    }
  }
}
