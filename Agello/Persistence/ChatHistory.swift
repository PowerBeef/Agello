import Foundation
import SwiftData

/// The current schema's models (see `Schema/` and ``ChatMigrationPlan``).
typealias ChatThread = SchemaV3.ChatThread
typealias ChatTurn = SchemaV3.ChatTurn
typealias Project = SchemaV3.Project
typealias ChatDocument = SchemaV3.ChatDocument
typealias DocumentChunk = SchemaV3.DocumentChunk
typealias MemoryItem = SchemaV3.MemoryItem

/// Schema for the app's container.
enum ChatStore {
  static var schema: Schema { Schema(versionedSchema: SchemaV3.self) }
}

// MARK: - Thread: branches

extension SchemaV3.ChatThread {
  var modelID: ModelID {
    get { ModelID(storedValue: modelIDRaw) }
    set { modelIDRaw = newValue.rawValue }
  }

  /// The visible branch, oldest first. Threads without an active leaf (legacy
  /// or freshly built in tests) fall back to creation order.
  var orderedTurns: [ChatTurn] {
    guard let activeLeafID else { return turns.sorted { $0.createdAt < $1.createdAt } }
    let byID = Dictionary(turns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var path: [ChatTurn] = []
    var cursor = byID[activeLeafID]
    var seen = Set<UUID>()
    while let turn = cursor, seen.insert(turn.id).inserted {
      path.append(turn)
      cursor = turn.parentID.flatMap { byID[$0] }
    }
    return path.reversed()
  }

  /// Text history of the visible branch for re-seeding the model. Skips empty
  /// turns and failed replies (persisted as "Error: …").
  var textHistory: [(role: ChatRole, text: String)] { Self.history(orderedTurns) }

  /// Text history of the visible branch up to (not including) `turn`.
  func textHistory(before turn: ChatTurn) -> [(role: ChatRole, text: String)] {
    let path = orderedTurns
    let prefix = path.firstIndex { $0.id == turn.id }.map { Array(path[..<$0]) } ?? path
    return Self.history(prefix)
  }

  private static func history(_ turns: [ChatTurn]) -> [(role: ChatRole, text: String)] {
    turns.compactMap { turn in
      guard !turn.text.isEmpty else { return nil }
      if turn.chatRole == .model, turn.text.hasPrefix(ChatTurn.errorPrefix) { return nil }
      return (turn.chatRole, turn.text)
    }
  }

  /// Chain turns by creation time and select the last as the active leaf
  /// (the V3 counterpart of ``ChatMigrationPlan/linkLinearHistory(_:)``).
  func linkLinearHistory() {
    let ordered = turns.sorted { $0.createdAt < $1.createdAt }
    var previous: UUID?
    for turn in ordered {
      turn.parentID = previous
      previous = turn.id
    }
    activeLeafID = ordered.last?.id
    updatedAt = ordered.last?.createdAt ?? createdAt
  }

  /// Continue the visible branch with `turn` and make it the active leaf.
  func append(_ turn: ChatTurn) {
    if activeLeafID == nil, !turns.isEmpty {
      // Legacy linear thread: adopt creation order first.
      linkLinearHistory()
    }
    attach(turn, parentID: activeLeafID)
  }

  /// Add `turn` as an alternative version of `original` (edit or
  /// regenerate): same parent, new branch, made active.
  func addVersion(_ turn: ChatTurn, of original: ChatTurn) {
    attach(turn, parentID: original.parentID)
  }

  private func attach(_ turn: ChatTurn, parentID: UUID?) {
    turn.parentID = parentID
    turns.append(turn)
    activeLeafID = turn.id
    updatedAt = Date()
  }

  /// Turns sharing `turn`'s parent and role (its alternative versions),
  /// oldest first. Contains `turn` itself.
  func siblings(of turn: ChatTurn) -> [ChatTurn] {
    turns
      .filter { $0.parentID == turn.parentID && $0.roleRaw == turn.roleRaw }
      .sorted { $0.createdAt < $1.createdAt }
  }

  /// Show the branch through `turn`, continuing down its most recent replies.
  func selectBranch(through turn: ChatTurn) {
    var leaf = turn
    while let next = turns.filter({ $0.parentID == leaf.id }).max(by: { $0.createdAt < $1.createdAt })
    {
      leaf = next
    }
    activeLeafID = leaf.id
  }

  /// Detach `turn` (a leaf) from the visible branch before deleting it.
  func removeLeaf(_ turn: ChatTurn) {
    if activeLeafID == turn.id { activeLeafID = turn.parentID }
    turns.removeAll { $0.id == turn.id }
  }
}

// MARK: - Turn

extension SchemaV3.ChatTurn {
  /// Prefix of model turns that record a failed generation.
  static let errorPrefix = "Error: "

  var chatRole: ChatRole { roleRaw == "model" ? .model : .user }
  var isUser: Bool { chatRole == .user }

  var stats: GenerationStats? {
    get {
      guard let statsData else { return nil }
      return try? JSONDecoder().decode(GenerationStats.self, from: statsData)
    }
    set { statsData = newValue.flatMap { try? JSONEncoder().encode($0) } }
  }

  var parts: MessageParts {
    get {
      guard let partsData, let decoded = try? JSONDecoder().decode(MessageParts.self, from: partsData)
      else { return MessageParts() }
      return decoded
    }
    set { partsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
  }
}

// MARK: - Message parts

/// Structured, non-text content of a turn.
struct MessageParts: Codable, Equatable, Sendable {
  /// Tools that ran while producing this reply, in order.
  var toolActivity: [ToolActivityRecord] = []
  /// Sources cited by this reply (web pages, files), numbered from 1.
  var sources: [SourceRecord] = []
  /// Files the user attached to this message.
  var files: [FileRecord] = []
  /// The user asked for a web search with this message.
  var webSearch = false

  var isEmpty: Bool { toolActivity.isEmpty && sources.isEmpty && files.isEmpty && !webSearch }

  init(
    toolActivity: [ToolActivityRecord] = [], sources: [SourceRecord] = [], files: [FileRecord] = [],
    webSearch: Bool = false
  ) {
    self.toolActivity = toolActivity
    self.sources = sources
    self.files = files
    self.webSearch = webSearch
  }

  /// Tolerates missing keys: parts saved before a field existed still decode.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    toolActivity = try container.decodeIfPresent([ToolActivityRecord].self, forKey: .toolActivity) ?? []
    sources = try container.decodeIfPresent([SourceRecord].self, forKey: .sources) ?? []
    files = try container.decodeIfPresent([FileRecord].self, forKey: .files) ?? []
    webSearch = try container.decodeIfPresent(Bool.self, forKey: .webSearch) ?? false
  }
}

/// A file attached to a message (its text lives in a ``ChatDocument``).
struct FileRecord: Codable, Equatable, Sendable, Identifiable {
  /// The ``ChatDocument`` id.
  var id: UUID
  var name: String
  /// ``DocumentKind`` raw value.
  var kind: String
  var pageCount: Int
}

struct ToolActivityRecord: Codable, Equatable, Sendable {
  var name: String
  /// Short, user-facing description ("Searched the web for …").
  var summary: String
}

struct SourceRecord: Codable, Equatable, Sendable, Identifiable {
  var id: Int { index }
  /// Citation number shown as [n].
  var index: Int
  var title: String
  var url: String?
  var snippet: String?
}
