import CoreSpotlight
import Foundation
import SwiftData

/// `--uitest-reset`: a clean slate for UI tests. Deletes every chat, project,
/// file and memory, all settings, the search API keys, items waiting in the
/// share inbox, and Spotlight entries. Downloaded models (Application
/// Support/Models) and the engine cache are kept.
@MainActor
enum AppReset {
  static func perform(
    context: ModelContext, defaults: UserDefaults = .standard,
    domain: String? = Bundle.main.bundleIdentifier, shareInbox: URL? = nil,
    systemStores: Bool = true
  ) {
    // Children first: passages belong to documents, turns to threads.
    try? context.delete(model: DocumentChunk.self)
    try? context.delete(model: ChatDocument.self)
    try? context.delete(model: ChatTurn.self)
    try? context.delete(model: ChatThread.self)
    try? context.delete(model: Project.self)
    try? context.delete(model: MemoryItem.self)
    try? context.save()
    // The whole domain, so a new setting can never leak between runs.
    if let domain { defaults.removePersistentDomain(forName: domain) }
    for pending in ShareInbox.pending(base: shareInbox) {
      ShareInbox.remove(pending.item.id, base: shareInbox)
    }
    // Shared with the installed app; unit tests leave them alone.
    guard systemStores else { return }
    for provider in [SearchProvider.brave, .tavily] { SearchKeys.setKey(nil, for: provider) }
    CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [SpotlightIndex.domain])
  }
}
