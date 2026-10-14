import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

/// Chats in system search: title and a short snippet; tapping a result opens
/// the chat. Can be turned off in Settings (the index is then cleared).
@MainActor
enum SpotlightIndex {
  static let domain = "com.patricedery.irtchat.chats"
  static let enabledKey = "spotlightEnabled"

  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
  }

  /// Most recent chats indexed at launch.
  static let limit = 300

  /// What Spotlight shows for a chat. Pure (unit-tested).
  struct Entry: Equatable, Sendable {
    var id: UUID
    var title: String
    var snippet: String
    var updatedAt: Date
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

  static func item(for entry: Entry) -> CSSearchableItem {
    let attributes = CSSearchableItemAttributeSet(contentType: .text)
    attributes.title = entry.title
    attributes.contentDescription = entry.snippet
    attributes.contentModificationDate = entry.updatedAt
    let item = CSSearchableItem(
      uniqueIdentifier: entry.id.uuidString, domainIdentifier: domain, attributeSet: attributes)
    return item
  }

  /// (Re)index these chats.
  static func index(_ threads: [ChatThread]) {
    guard isEnabled else { return }
    let items = threads.compactMap(entry(for:)).map(item(for:))
    guard !items.isEmpty else { return }
    CSSearchableIndex.default().indexSearchableItems(items) { error in
      if let error { Log.lifecycle.error("spotlight: \(error.localizedDescription, privacy: .public)") }
    }
  }

  static func remove(_ ids: [UUID]) {
    guard !ids.isEmpty else { return }
    CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ids.map(\.uuidString))
  }

  /// Rebuild the index from the store (launch), or clear it when off.
  static func refresh(in context: ModelContext) {
    guard isEnabled else {
      CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain])
      return
    }
    var descriptor = FetchDescriptor<ChatThread>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
    descriptor.fetchLimit = limit
    index((try? context.fetch(descriptor)) ?? [])
  }

  /// The chat a Spotlight result points at.
  static func chatID(from activity: NSUserActivity) -> UUID? {
    (activity.userInfo?[CSSearchableItemActivityIdentifier] as? String).flatMap(UUID.init(uuidString:))
  }
}
