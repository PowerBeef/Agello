import AppIntents
import CoreSpotlight
import Foundation
import SwiftData

/// Platform seam bridging ``SpotlightIndex`` to iOS 27 `AppIntents` / `IndexedEntity` indexing
/// (keeps `SpotlightIndex` compiling cleanly in the Mac CLI without platform `#if`s).
@MainActor
enum EntityIndexing {
  static func configure(container: ModelContainer) {
    AppEntityStore.container = container
  }

  static func indexChats(_ entries: [SpotlightIndex.Entry]) {
    let entities = entries.map { ChatEntity(entry: $0) }
    guard !entities.isEmpty else { return }
    Task.detached(priority: .utility) {
      do {
        try await CSSearchableIndex.default().indexAppEntities(entities)
      } catch {
        Log.lifecycle.error("spotlight entity chats: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  static func indexProjects(_ entries: [SpotlightIndex.ProjectEntry]) {
    let entities = entries.map(ProjectEntity.init(entry:))
    guard !entities.isEmpty else { return }
    Task.detached(priority: .utility) {
      do {
        try await CSSearchableIndex.default().indexAppEntities(entities)
      } catch {
        Log.lifecycle.error("spotlight entity projects: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  static func indexDocuments(_ entries: [SpotlightIndex.DocumentEntry]) {
    let entities = entries.map(DocumentEntity.init(entry:))
    guard !entities.isEmpty else { return }
    Task.detached(priority: .utility) {
      do {
        try await CSSearchableIndex.default().indexAppEntities(entities)
      } catch {
        Log.lifecycle.error("spotlight entity documents: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  static func removeChats(_ ids: [UUID]) {
    guard !ids.isEmpty else { return }
    Task.detached(priority: .utility) {
      try? await CSSearchableIndex.default().deleteAppEntities(
        identifiedBy: ids, ofType: ChatEntity.self)
    }
  }

  static func removeProjects(_ ids: [UUID]) {
    guard !ids.isEmpty else { return }
    Task.detached(priority: .utility) {
      try? await CSSearchableIndex.default().deleteAppEntities(
        identifiedBy: ids, ofType: ProjectEntity.self)
    }
  }

  static func removeDocuments(_ ids: [UUID]) {
    guard !ids.isEmpty else { return }
    Task.detached(priority: .utility) {
      try? await CSSearchableIndex.default().deleteAppEntities(
        identifiedBy: ids, ofType: DocumentEntity.self)
    }
  }

  static func deleteAll() {
    Task.detached(priority: .utility) {
      let index = CSSearchableIndex.default()
      try? await index.deleteAppEntities(ofType: ChatEntity.self)
      try? await index.deleteAppEntities(ofType: ProjectEntity.self)
      try? await index.deleteAppEntities(ofType: DocumentEntity.self)
    }
  }
}
