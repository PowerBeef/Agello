import Foundation
import SwiftData

/// Opens the chat store with migrations. If the store can't be opened, it is
/// moved aside (never deleted) and a fresh store is created, so a bad store
/// can't crash the app at launch.
enum ChatStoreLoader {
  struct Opened {
    let container: ModelContainer
    /// User-facing message when the previous store had to be set aside.
    let recoveryNotice: String?
  }

  static func open(url: URL? = nil) -> Opened {
    let configuration =
      url.map { ModelConfiguration(schema: ChatStore.schema, url: $0) }
      ?? ModelConfiguration(schema: ChatStore.schema)
    do {
      return Opened(container: try makeContainer(configuration), recoveryNotice: nil)
    } catch {
      Log.lifecycle.error(
        "chat store failed to open: \(String(describing: error), privacy: .public)")
      let backup = moveAside(configuration.url)
      do {
        let container = try makeContainer(configuration)
        let where_ = backup.map { " A copy was kept as \($0.lastPathComponent)." } ?? ""
        return Opened(
          container: container,
          recoveryNotice: "Your chat history couldn't be opened, so a new one was started.\(where_)")
      } catch {
        // Last resort: keep the app usable for this session.
        let memory = ModelConfiguration(schema: ChatStore.schema, isStoredInMemoryOnly: true)
        return Opened(
          // swiftlint:disable:next force_try - an in-memory store has no file to fail on
          container: try! makeContainer(memory),
          recoveryNotice: "Chat history is unavailable right now; chats won't be saved this session.")
      }
    }
  }

  static func makeContainer(_ configuration: ModelConfiguration) throws -> ModelContainer {
    try ModelContainer(
      for: ChatStore.schema, migrationPlan: ChatMigrationPlan.self,
      configurations: [configuration])
  }

  /// Rename the store and its SQLite sidecar files; returns the new store URL.
  @discardableResult
  static func moveAside(_ store: URL) -> URL? {
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let backup = store.deletingLastPathComponent()
      .appendingPathComponent("\(store.lastPathComponent).unreadable-\(stamp)")
    var moved = false
    for suffix in ["", "-shm", "-wal"] {
      let source = URL(fileURLWithPath: store.path + suffix)
      guard FileManager.default.fileExists(atPath: source.path) else { continue }
      let destination = URL(fileURLWithPath: backup.path + suffix)
      if (try? FileManager.default.moveItem(at: source, to: destination)) != nil, suffix.isEmpty {
        moved = true
      }
    }
    return moved ? backup : nil
  }
}
