import Foundation
import SwiftData

/// macOS CLI no-op twin of `AgelloiOS/Platform/EntityIndexing.swift`: AppIntents entity
/// indexing only ships in the iPhone app.
@MainActor
enum EntityIndexing {
  static func configure(container: ModelContainer) {}
  static func indexChats(_ entries: [SpotlightIndex.Entry]) {}
  static func indexProjects(_ entries: [SpotlightIndex.ProjectEntry]) {}
  static func indexDocuments(_ entries: [SpotlightIndex.DocumentEntry]) {}
  static func removeChats(_ ids: [UUID]) {}
  static func removeProjects(_ ids: [UUID]) {}
  static func removeDocuments(_ ids: [UUID]) {}
  static func deleteAll() {}
}
