import Foundation
import SwiftData

/// Store migrations. Add a new `SchemaVn` + stage for every model change;
/// never edit a shipped schema.
enum ChatMigrationPlan: SchemaMigrationPlan {
  static var schemas: [any VersionedSchema.Type] {
    [SchemaV0.self, SchemaV1.self, SchemaV2.self, SchemaV3.self]
  }

  static var stages: [MigrationStage] {
    [
      .lightweight(fromVersion: SchemaV0.self, toVersion: SchemaV1.self),
      // New columns are optional/defaulted; the custom step links existing
      // linear chats into a single branch.
      .custom(
        fromVersion: SchemaV1.self, toVersion: SchemaV2.self,
        willMigrate: nil,
        didMigrate: { context in
          let threads = try context.fetch(FetchDescriptor<SchemaV2.ChatThread>())
          for thread in threads {
            linkLinearHistory(thread)
          }
          try context.save()
        }),
      // New models and an optional project link only.
      .lightweight(fromVersion: SchemaV2.self, toVersion: SchemaV3.self),
    ]
  }

  /// Chain a thread's turns by creation time and select the last as the
  /// active leaf. Idempotent.
  static func linkLinearHistory(_ thread: SchemaV2.ChatThread) {
    let ordered = thread.turns.sorted { $0.createdAt < $1.createdAt }
    var previous: UUID?
    for turn in ordered {
      turn.parentID = previous
      previous = turn.id
    }
    thread.activeLeafID = ordered.last?.id
    thread.updatedAt = ordered.last?.createdAt ?? thread.createdAt
  }
}
