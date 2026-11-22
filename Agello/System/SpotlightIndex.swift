import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Chats, projects, and attached documents in system search (Spotlight & AppIntents
/// `IndexedEntity`): tapping a result opens the chat, project, or document owner. Can be turned
/// off in Settings (the index is then cleared).
@MainActor
enum SpotlightIndex {
  static let domain = "com.patricedery.agello.chats"
  static let projectDomain = "com.patricedery.agello.projects"
  static let documentDomain = "com.patricedery.agello.documents"
  static let allDomains = [domain, projectDomain, documentDomain]
  static let enabledKey = "spotlightEnabled"

  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
  }

  /// Most recent items indexed per kind at launch.
  static let limit = 300

  /// What Spotlight shows for a chat. Pure (unit-tested).
  struct Entry: Equatable, Sendable {
    var id: UUID
    var title: String
    var snippet: String
    var updatedAt: Date
  }

  /// What Spotlight and `ProjectEntity` show for a project.
  struct ProjectEntry: Equatable, Sendable {
    var id: UUID
    var name: String
    var instructions: String
    var updatedAt: Date
  }

  /// What Spotlight and `DocumentEntity` show for an attached document.
  struct DocumentEntry: Equatable, Sendable {
    var id: UUID
    var name: String
    var kindRaw: String
    var pageCount: Int
    var snippet: String
    var createdAt: Date
  }

  static func entry(for thread: ChatThread) -> Entry? {
    let turns = thread.orderedTurns.filter {
      !$0.text.isEmpty && !$0.text.hasPrefix(ChatTurn.errorPrefix)
    }
    guard !turns.isEmpty else { return nil }
    let firstQuestion = turns.first(where: \.isUser)?.text ?? ""
    let lastReply = turns.last(where: { !$0.isUser })?.text ?? ""
    let snippet = [firstQuestion, lastReply]
      .map { $0.replacingOccurrences(of: "\n", with: " ") }
      .filter { !$0.isEmpty }
      .joined(separator: " — ")
    return Entry(
      id: thread.id, title: thread.title, snippet: String(snippet.prefix(300)),
      updatedAt: thread.updatedAt)
  }

  static func projectEntry(for project: Project) -> ProjectEntry {
    ProjectEntry(
      id: project.id, name: project.name,
      instructions: project.instructions.trimmingCharacters(in: .whitespacesAndNewlines),
      updatedAt: project.updatedAt)
  }

  static func documentEntry(for document: ChatDocument) -> DocumentEntry {
    let source = document.summary ?? document.text
    let compact = source
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return DocumentEntry(
      id: document.id, name: document.name, kindRaw: document.kindRaw,
      pageCount: document.pageCount, snippet: String(compact.prefix(300)),
      createdAt: document.createdAt)
  }

  static func item(for entry: Entry) -> CSSearchableItem {
    let attributes = CSSearchableItemAttributeSet(contentType: .text)
    attributes.title = entry.title
    attributes.contentDescription = entry.snippet
    attributes.contentModificationDate = entry.updatedAt
    return CSSearchableItem(
      uniqueIdentifier: entry.id.uuidString, domainIdentifier: domain, attributeSet: attributes)
  }

  static func item(for entry: ProjectEntry) -> CSSearchableItem {
    let attributes = CSSearchableItemAttributeSet(contentType: .folder)
    attributes.title = entry.name
    attributes.contentDescription = entry.instructions.isEmpty ? nil : String(entry.instructions.prefix(300))
    attributes.contentModificationDate = entry.updatedAt
    return CSSearchableItem(
      uniqueIdentifier: "project:\(entry.id.uuidString)", domainIdentifier: projectDomain,
      attributeSet: attributes)
  }

  static func item(for entry: DocumentEntry) -> CSSearchableItem {
    let attributes = CSSearchableItemAttributeSet(contentType: .content)
    attributes.title = entry.name
    attributes.contentDescription = entry.snippet
    attributes.contentCreationDate = entry.createdAt
    if entry.pageCount > 0 { attributes.pageCount = NSNumber(value: entry.pageCount) }
    return CSSearchableItem(
      uniqueIdentifier: "document:\(entry.id.uuidString)", domainIdentifier: documentDomain,
      attributeSet: attributes)
  }

  /// (Re)index these chats in CoreSpotlight and AppIntents `IndexedEntity` storage.
  static func index(_ threads: [ChatThread]) {
    guard isEnabled else { return }
    let entries = threads.compactMap(entry(for:))
    guard !entries.isEmpty else { return }
    let items = entries.map(item(for:))
    CSSearchableIndex.default().indexSearchableItems(items) { error in
      if let error { Log.lifecycle.error("spotlight: \(error.localizedDescription, privacy: .public)") }
    }
    EntityIndexing.indexChats(entries)
  }

  /// (Re)index these projects in CoreSpotlight and AppIntents `IndexedEntity` storage.
  static func indexProjects(_ projects: [Project]) {
    guard isEnabled, !projects.isEmpty else { return }
    let entries = projects.map(projectEntry(for:))
    let items = entries.map(item(for:))
    CSSearchableIndex.default().indexSearchableItems(items) { error in
      if let error { Log.lifecycle.error("spotlight projects: \(error.localizedDescription, privacy: .public)") }
    }
    EntityIndexing.indexProjects(entries)
  }

  /// (Re)index these documents in CoreSpotlight and AppIntents `IndexedEntity` storage.
  static func indexDocuments(_ documents: [ChatDocument]) {
    guard isEnabled, !documents.isEmpty else { return }
    let entries = documents.map(documentEntry(for:))
    let items = entries.map(item(for:))
    CSSearchableIndex.default().indexSearchableItems(items) { error in
      if let error { Log.lifecycle.error("spotlight documents: \(error.localizedDescription, privacy: .public)") }
    }
    EntityIndexing.indexDocuments(entries)
  }

  static func remove(_ ids: [UUID]) {
    guard !ids.isEmpty else { return }
    CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ids.map(\.uuidString))
    EntityIndexing.removeChats(ids)
  }

  static func removeProjects(_ ids: [UUID]) {
    guard !ids.isEmpty else { return }
    CSSearchableIndex.default().deleteSearchableItems(
      withIdentifiers: ids.map { "project:\($0.uuidString)" })
    EntityIndexing.removeProjects(ids)
  }

  static func removeDocuments(_ ids: [UUID]) {
    guard !ids.isEmpty else { return }
    CSSearchableIndex.default().deleteSearchableItems(
      withIdentifiers: ids.map { "document:\($0.uuidString)" })
    EntityIndexing.removeDocuments(ids)
  }

  /// When the index last caught up with the store.
  static let refreshedAtKey = "spotlightRefreshedAt"

  /// Index chats, projects, and documents changed since the last refresh (launch), all of them
  /// (`full`, when turned on), or clear the index when off.
  static func refresh(
    in context: ModelContext, full: Bool = false, defaults: UserDefaults = .standard
  ) {
    guard isEnabled else {
      CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: allDomains)
      EntityIndexing.deleteAll()
      defaults.removeObject(forKey: refreshedAtKey)
      return
    }
    let since = full ? nil : defaults.object(forKey: refreshedAtKey) as? Date
    let now = Date()
    index(threadsToIndex(in: context, changedSince: since))
    indexProjects(projectsToIndex(in: context, changedSince: since))
    indexDocuments(documentsToIndex(in: context, changedSince: since))
    defaults.set(now, forKey: refreshedAtKey)
  }

  /// The most recent chats, or those changed since `date`.
  static func threadsToIndex(in context: ModelContext, changedSince date: Date?) -> [ChatThread] {
    var descriptor = FetchDescriptor<ChatThread>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
    if let date { descriptor.predicate = #Predicate { $0.updatedAt > date } }
    descriptor.fetchLimit = limit
    return (try? context.fetch(descriptor)) ?? []
  }

  /// The most recent projects, or those changed since `date`.
  static func projectsToIndex(in context: ModelContext, changedSince date: Date?) -> [Project] {
    var descriptor = FetchDescriptor<Project>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
    if let date { descriptor.predicate = #Predicate { $0.updatedAt > date } }
    descriptor.fetchLimit = limit
    return (try? context.fetch(descriptor)) ?? []
  }

  /// The most recent attached documents, or those added since `date`.
  static func documentsToIndex(in context: ModelContext, changedSince date: Date?) -> [ChatDocument] {
    var descriptor = FetchDescriptor<ChatDocument>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
    if let date { descriptor.predicate = #Predicate { $0.createdAt > date } }
    descriptor.fetchLimit = limit
    return (try? context.fetch(descriptor)) ?? []
  }

  /// The chat a legacy Spotlight result points at.
  static func chatID(from activity: NSUserActivity) -> UUID? {
    (activity.userInfo?[CSSearchableItemActivityIdentifier] as? String).flatMap(UUID.init(uuidString:))
  }

  /// Resolves a Spotlight user activity into an ``AppRouter/Action`` (chat, project, or document).
  static func action(from activity: NSUserActivity) -> AppRouter.Action? {
    guard let raw = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else {
      return nil
    }
    if raw.hasPrefix("project:"), let id = UUID(uuidString: String(raw.dropFirst("project:".count))) {
      return .openProject(id)
    }
    if raw.hasPrefix("document:"), let id = UUID(uuidString: String(raw.dropFirst("document:".count))) {
      return .openDocument(id)
    }
    return UUID(uuidString: raw).map(AppRouter.Action.openChat)
  }
}
