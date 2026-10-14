import Foundation
import SwiftData

/// The original release's store (before voice messages were marked).
/// Frozen: never edit; migrations depend on its exact shape.
enum SchemaV0: VersionedSchema {
  static let versionIdentifier = Schema.Version(0, 9, 0)
  static var models: [any PersistentModel.Type] { [ChatThread.self, ChatTurn.self] }

  @Model
  final class ChatThread {
    var id: UUID
    var title: String
    var createdAt: Date
    var modelIDRaw: String
    @Relationship(deleteRule: .cascade, inverse: \ChatTurn.thread)
    var turns: [ChatTurn] = []

    init(id: UUID, title: String, createdAt: Date, modelIDRaw: String) {
      self.id = id
      self.title = title
      self.createdAt = createdAt
      self.modelIDRaw = modelIDRaw
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
    var createdAt: Date
    var thread: ChatThread?

    init(id: UUID, roleRaw: String, text: String, createdAt: Date) {
      self.id = id
      self.roleRaw = roleRaw
      self.text = text
      self.thought = ""
      self.toolNames = []
      self.createdAt = createdAt
    }
  }
}

/// The store as of `main@ddedc83` (adds `hasAudio`).
/// Frozen: never edit; migrations depend on its exact shape.
enum SchemaV1: VersionedSchema {
  static let versionIdentifier = Schema.Version(1, 0, 0)
  static var models: [any PersistentModel.Type] { [ChatThread.self, ChatTurn.self] }

  @Model
  final class ChatThread {
    var id: UUID
    var title: String
    var createdAt: Date
    var modelIDRaw: String
    @Relationship(deleteRule: .cascade, inverse: \ChatTurn.thread)
    var turns: [ChatTurn] = []

    init(id: UUID, title: String, createdAt: Date, modelIDRaw: String) {
      self.id = id
      self.title = title
      self.createdAt = createdAt
      self.modelIDRaw = modelIDRaw
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
    var hasAudio: Bool = false
    var createdAt: Date
    var thread: ChatThread?

    init(id: UUID, roleRaw: String, text: String, createdAt: Date) {
      self.id = id
      self.roleRaw = roleRaw
      self.text = text
      self.thought = ""
      self.toolNames = []
      self.createdAt = createdAt
    }
  }
}
