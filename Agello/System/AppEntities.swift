import AppIntents
import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Shared SwiftData container bridge for `AppEntity` queries invoked by Siri, Shortcuts, and
/// Spotlight. Configured once in ``AppBootstrap`` (and injectable in unit tests).
@MainActor
enum AppEntityStore {
  static var container: ModelContainer?

  static func context() -> ModelContext {
    if let container { return container.mainContext }
    let opened = ChatStoreLoader.open().container
    container = opened
    return opened.mainContext
  }

  static func chats(ids: [UUID]? = nil, matching query: String? = nil, limit: Int = 50) -> [ChatEntity] {
    let ctx = context()
    var descriptor = FetchDescriptor<ChatThread>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
    if ids == nil && query == nil { descriptor.fetchLimit = limit }
    let threads = (try? ctx.fetch(descriptor)) ?? []
    let projectsByID = Dictionary(
      uniqueKeysWithValues: ((try? ctx.fetch(FetchDescriptor<Project>())) ?? []).map { ($0.id, $0.name) })
    let idSet = ids.map(Set.init)
    let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines)
    var results: [ChatEntity] = []
    for thread in threads {
      if let idSet, !idSet.contains(thread.id) { continue }
      guard let entry = SpotlightIndex.entry(for: thread) else { continue }
      let projectName = thread.projectID.flatMap { projectsByID[$0] }
      let entity = ChatEntity(entry: entry, projectName: projectName)
      if let needle, !needle.isEmpty, !entity.matches(needle) { continue }
      results.append(entity)
      if results.count >= limit && idSet == nil { break }
    }
    return results
  }

  static func projects(ids: [UUID]? = nil, matching query: String? = nil, limit: Int = 50) -> [ProjectEntity] {
    let ctx = context()
    var descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
    if ids == nil && query == nil { descriptor.fetchLimit = limit }
    let all = (try? ctx.fetch(descriptor)) ?? []
    let idSet = ids.map(Set.init)
    let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines)
    var results: [ProjectEntity] = []
    for project in all {
      if let idSet, !idSet.contains(project.id) { continue }
      let entry = SpotlightIndex.projectEntry(for: project)
      let entity = ProjectEntity(entry: entry)
      if let needle, !needle.isEmpty, !entity.matches(needle) { continue }
      results.append(entity)
      if results.count >= limit && idSet == nil { break }
    }
    return results
  }

  static func documents(ids: [UUID]? = nil, matching query: String? = nil, limit: Int = 50) -> [DocumentEntity] {
    let ctx = context()
    var descriptor = FetchDescriptor<ChatDocument>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
    if ids == nil && query == nil { descriptor.fetchLimit = limit }
    let all = (try? ctx.fetch(descriptor)) ?? []
    let idSet = ids.map(Set.init)
    let needle = query?.trimmingCharacters(in: .whitespacesAndNewlines)
    var results: [DocumentEntity] = []
    for document in all {
      if let idSet, !idSet.contains(document.id) { continue }
      let entry = SpotlightIndex.documentEntry(for: document)
      let entity = DocumentEntity(entry: entry)
      if let needle, !needle.isEmpty, !entity.matches(needle) { continue }
      results.append(entity)
      if results.count >= limit && idSet == nil { break }
    }
    return results
  }
}

// MARK: - Indexed Entities

/// A saved Agello chat exposed to Siri, Shortcuts, and Spotlight.
struct ChatEntity: IndexedEntity, Sendable {
  static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Chat", numericFormat: "\(placeholder: .int) chats")
  static let defaultQuery = ChatEntityQuery()

  var id: UUID
  @Property(title: "Title")
  var title: String
  @Property(title: "Preview")
  var snippet: String
  @Property(title: "Updated")
  var updatedAt: Date
  @Property(title: "Project")
  var projectName: String?

  init(id: UUID, title: String, snippet: String, updatedAt: Date, projectName: String? = nil) {
    self.id = id
    self.title = title
    self.snippet = snippet
    self.updatedAt = updatedAt
    self.projectName = projectName
  }

  init(entry: SpotlightIndex.Entry, projectName: String? = nil) {
    self.init(
      id: entry.id, title: entry.title, snippet: entry.snippet,
      updatedAt: entry.updatedAt, projectName: projectName)
  }

  var displayRepresentation: DisplayRepresentation {
    let subtitle = snippet.isEmpty ? projectName : snippet
    return DisplayRepresentation(
      title: LocalizedStringResource(stringLiteral: title),
      subtitle: subtitle.map { LocalizedStringResource(stringLiteral: $0) },
      image: .init(systemName: "bubble.left.and.text.bubble.right"))
  }

  var attributeSet: CSSearchableItemAttributeSet {
    let set = defaultAttributeSet
    set.title = title
    set.contentDescription = snippet
    set.contentModificationDate = updatedAt
    if let projectName, !projectName.isEmpty {
      set.keywords = [projectName]
    }
    return set
  }

  func matches(_ query: String) -> Bool {
    title.localizedStandardContains(query)
      || snippet.localizedStandardContains(query)
      || (projectName?.localizedStandardContains(query) ?? false)
  }
}

/// A saved Agello project exposed to Siri, Shortcuts, and Spotlight.
struct ProjectEntity: IndexedEntity, Sendable {
  static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Project", numericFormat: "\(placeholder: .int) projects")
  static let defaultQuery = ProjectEntityQuery()

  var id: UUID
  @Property(title: "Name")
  var name: String
  @Property(title: "Instructions")
  var instructions: String
  @Property(title: "Updated")
  var updatedAt: Date

  init(id: UUID, name: String, instructions: String, updatedAt: Date) {
    self.id = id
    self.name = name
    self.instructions = instructions
    self.updatedAt = updatedAt
  }

  init(entry: SpotlightIndex.ProjectEntry) {
    self.init(
      id: entry.id, name: entry.name, instructions: entry.instructions, updatedAt: entry.updatedAt)
  }

  var displayRepresentation: DisplayRepresentation {
    let subtitle = instructions.isEmpty ? nil : String(instructions.prefix(120))
    return DisplayRepresentation(
      title: LocalizedStringResource(stringLiteral: name),
      subtitle: subtitle.map { LocalizedStringResource(stringLiteral: $0) },
      image: .init(systemName: "folder"))
  }

  var attributeSet: CSSearchableItemAttributeSet {
    let set = defaultAttributeSet
    set.title = name
    set.contentDescription = instructions.isEmpty ? nil : String(instructions.prefix(300))
    set.contentModificationDate = updatedAt
    return set
  }

  func matches(_ query: String) -> Bool {
    name.localizedStandardContains(query) || instructions.localizedStandardContains(query)
  }
}

/// An attached chat or project document exposed to Siri, Shortcuts, and Spotlight.
struct DocumentEntity: IndexedEntity, Sendable {
  static let typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Document", numericFormat: "\(placeholder: .int) documents")
  static let defaultQuery = DocumentEntityQuery()

  var id: UUID
  @Property(title: "Name")
  var name: String
  @Property(title: "Kind")
  var kindRaw: String
  @Property(title: "Pages")
  var pageCount: Int
  @Property(title: "Preview")
  var snippet: String
  @Property(title: "Added")
  var createdAt: Date

  init(
    id: UUID, name: String, kindRaw: String, pageCount: Int, snippet: String, createdAt: Date
  ) {
    self.id = id
    self.name = name
    self.kindRaw = kindRaw
    self.pageCount = pageCount
    self.snippet = snippet
    self.createdAt = createdAt
  }

  init(entry: SpotlightIndex.DocumentEntry) {
    self.init(
      id: entry.id, name: entry.name, kindRaw: entry.kindRaw, pageCount: entry.pageCount,
      snippet: entry.snippet, createdAt: entry.createdAt)
  }

  var displayRepresentation: DisplayRepresentation {
    let detail: String? =
      pageCount > 0 ? "\(pageCount) pages" : (snippet.isEmpty ? nil : String(snippet.prefix(120)))
    let symbol = (DocumentKind(rawValue: kindRaw) ?? .text).symbol
    return DisplayRepresentation(
      title: LocalizedStringResource(stringLiteral: name),
      subtitle: detail.map { LocalizedStringResource(stringLiteral: $0) },
      image: .init(systemName: symbol))
  }

  var attributeSet: CSSearchableItemAttributeSet {
    let set = defaultAttributeSet
    set.title = name
    set.contentDescription = snippet
    set.contentCreationDate = createdAt
    if pageCount > 0 { set.pageCount = NSNumber(value: pageCount) }
    return set
  }

  func matches(_ query: String) -> Bool {
    name.localizedStandardContains(query) || snippet.localizedStandardContains(query)
  }
}

// MARK: - Entity Queries

struct ChatEntityQuery: EntityStringQuery, IndexedEntityQuery {
  func entities(for identifiers: [UUID]) async throws -> [ChatEntity] {
    await MainActor.run { AppEntityStore.chats(ids: identifiers) }
  }

  func entities(matching string: String) async throws -> [ChatEntity] {
    await MainActor.run { AppEntityStore.chats(matching: string, limit: 25) }
  }

  func suggestedEntities() async throws -> [ChatEntity] {
    await MainActor.run { AppEntityStore.chats(limit: 20) }
  }

  func reindexEntities(
    for identifiers: [UUID], indexDescription: CSSearchableIndexDescription
  ) async throws {
    let enabled = await MainActor.run { SpotlightIndex.isEnabled }
    guard enabled else { return }
    let entities = await MainActor.run { AppEntityStore.chats(ids: identifiers) }
    if !entities.isEmpty { try await CSSearchableIndex.default().indexAppEntities(entities) }
  }

  func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
    let enabled = await MainActor.run { SpotlightIndex.isEnabled }
    guard enabled else {
      try await CSSearchableIndex.default().deleteAppEntities(ofType: ChatEntity.self)
      return
    }
    let entities = await MainActor.run { AppEntityStore.chats(limit: SpotlightIndex.limit) }
    if !entities.isEmpty { try await CSSearchableIndex.default().indexAppEntities(entities) }
  }
}

struct ProjectEntityQuery: EntityStringQuery, IndexedEntityQuery {
  func entities(for identifiers: [UUID]) async throws -> [ProjectEntity] {
    await MainActor.run { AppEntityStore.projects(ids: identifiers) }
  }

  func entities(matching string: String) async throws -> [ProjectEntity] {
    await MainActor.run { AppEntityStore.projects(matching: string, limit: 25) }
  }

  func suggestedEntities() async throws -> [ProjectEntity] {
    await MainActor.run { AppEntityStore.projects(limit: 20) }
  }

  func reindexEntities(
    for identifiers: [UUID], indexDescription: CSSearchableIndexDescription
  ) async throws {
    let enabled = await MainActor.run { SpotlightIndex.isEnabled }
    guard enabled else { return }
    let entities = await MainActor.run { AppEntityStore.projects(ids: identifiers) }
    if !entities.isEmpty { try await CSSearchableIndex.default().indexAppEntities(entities) }
  }

  func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
    let enabled = await MainActor.run { SpotlightIndex.isEnabled }
    guard enabled else {
      try await CSSearchableIndex.default().deleteAppEntities(ofType: ProjectEntity.self)
      return
    }
    let entities = await MainActor.run { AppEntityStore.projects(limit: SpotlightIndex.limit) }
    if !entities.isEmpty { try await CSSearchableIndex.default().indexAppEntities(entities) }
  }
}

struct DocumentEntityQuery: EntityStringQuery, IndexedEntityQuery {
  func entities(for identifiers: [UUID]) async throws -> [DocumentEntity] {
    await MainActor.run { AppEntityStore.documents(ids: identifiers) }
  }

  func entities(matching string: String) async throws -> [DocumentEntity] {
    await MainActor.run { AppEntityStore.documents(matching: string, limit: 25) }
  }

  func suggestedEntities() async throws -> [DocumentEntity] {
    await MainActor.run { AppEntityStore.documents(limit: 20) }
  }

  func reindexEntities(
    for identifiers: [UUID], indexDescription: CSSearchableIndexDescription
  ) async throws {
    let enabled = await MainActor.run { SpotlightIndex.isEnabled }
    guard enabled else { return }
    let entities = await MainActor.run { AppEntityStore.documents(ids: identifiers) }
    if !entities.isEmpty { try await CSSearchableIndex.default().indexAppEntities(entities) }
  }

  func reindexAllEntities(indexDescription: CSSearchableIndexDescription) async throws {
    let enabled = await MainActor.run { SpotlightIndex.isEnabled }
    guard enabled else {
      try await CSSearchableIndex.default().deleteAppEntities(ofType: DocumentEntity.self)
      return
    }
    let entities = await MainActor.run { AppEntityStore.documents(limit: SpotlightIndex.limit) }
    if !entities.isEmpty { try await CSSearchableIndex.default().indexAppEntities(entities) }
  }
}

// MARK: - Open Intents (Siri, Shortcuts, Spotlight AppEntity activation)

/// Open a saved chat from Spotlight, Siri, or Shortcuts.
struct OpenChatIntent: OpenIntent {
  static let title: LocalizedStringResource = "Open Chat"
  static let description = IntentDescription("Open a saved Agello chat.")
  static let supportedModes: IntentModes = .foreground(.immediate)
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  @Parameter(title: "Chat")
  var target: ChatEntity

  @MainActor
  func perform() async throws -> some IntentResult {
    AppRouter.shared.handle(.openChat(target.id))
    return .result()
  }
}

/// Open a saved project from Spotlight, Siri, or Shortcuts.
struct OpenProjectIntent: OpenIntent {
  static let title: LocalizedStringResource = "Open Project"
  static let description = IntentDescription("Open a saved Agello project.")
  static let supportedModes: IntentModes = .foreground(.immediate)
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  @Parameter(title: "Project")
  var target: ProjectEntity

  @MainActor
  func perform() async throws -> some IntentResult {
    AppRouter.shared.handle(.openProject(target.id))
    return .result()
  }
}

/// Open the chat or project that holds a saved document.
struct OpenDocumentIntent: OpenIntent {
  static let title: LocalizedStringResource = "Open Document"
  static let description = IntentDescription("Open the chat or project containing a saved document.")
  static let supportedModes: IntentModes = .foreground(.immediate)
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  @Parameter(title: "Document")
  var target: DocumentEntity

  @MainActor
  func perform() async throws -> some IntentResult {
    AppRouter.shared.handle(.openDocument(target.id))
    return .result()
  }
}
