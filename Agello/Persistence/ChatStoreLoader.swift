import Foundation
import SwiftData

/// Opens the chat store with migrations, without ever losing a readable store.
///
/// - A store that is corrupt, or whose migration failed, is moved aside (never deleted; the two
///   newest copies are kept) and a fresh store is created, so a bad store can't crash the app.
/// - A store this build can't read but that isn't damaged (written by a newer build, the disk is
///   full, its file is protected before the first unlock) is left alone: chats are kept in
///   memory for this session, with a notice, and the store opens again on a later launch.
enum ChatStoreLoader {
  struct Opened {
    let container: ModelContainer
    /// User-facing message when the store couldn't be used as is.
    let recoveryNotice: String?
  }

  /// Why a store didn't open.
  enum Failure: Equatable {
    /// Damaged: move it aside.
    case corrupt
    /// Schema migration failed: move it aside.
    case migrationFailed
    /// Saved by a build with a schema this one doesn't know.
    case newerVersion
    /// Can't be read right now (disk full, file protection, permissions, lock, timeout).
    case unavailable
    /// Unclassified error: leave a healthy SQLite store untouched and use an in-memory session.
    case other
  }

  static let keptBackups = 2
  private static let sqliteMagic = Data("SQLite format 3\0".utf8)

  static func open(url: URL? = nil) -> Opened {
    let configuration =
      url.map { ModelConfiguration(schema: ChatStore.schema, url: $0) }
      ?? ModelConfiguration(schema: ChatStore.schema, groupContainer: Platform.chatStoreGroupContainer)
    // Before the first unlock the store's file can't be read (a background launch): opening it
    // would fail and look like damage.
    if !isReadable(configuration.url) {
      Log.lifecycle.error("chat store not readable yet (file protection?)")
      return inMemory(
        notice: String(localized: "Chat history is unavailable right now; chats won't be saved this session."))
    }
    do {
      return Opened(container: try makeContainer(configuration), recoveryNotice: nil)
    } catch {
      let failure = classify(error)
      Log.lifecycle.error(
        "chat store failed to open (\(String(describing: failure), privacy: .public)): \(String(describing: error), privacy: .public)")
      switch failure {
      case .newerVersion:
        return inMemory(
          notice: String(localized: "Your chat history was saved by a newer version of Agello. Update the app to see it; chats won't be saved until then."))
      case .unavailable:
        return inMemory(
          notice: String(localized: "Chat history is unavailable right now; chats won't be saved this session."))
      case .other:
        // Only move aside an unclassified failure if the on-disk file is demonstrably not a
        // SQLite database (e.g. SwiftData stripped the underlying SQLITE_NOTADB error).
        guard hasCorruptHeader(configuration.url) else {
          return inMemory(
            notice: String(localized: "Chat history is unavailable right now; chats won't be saved this session."))
        }
      case .corrupt, .migrationFailed:
        break
      }
      let backup = moveAside(configuration.url)
      pruneBackups(of: configuration.url)
      do {
        let container = try makeContainer(configuration)
        let where_ = backup.map { " A copy was kept as \($0.lastPathComponent)." } ?? ""
        return Opened(
          container: container,
          recoveryNotice: "Your chat history couldn't be opened, so a new one was started.\(where_)")
      } catch {
        // Last resort: keep the app usable for this session.
        return inMemory(
          notice: String(localized: "Chat history is unavailable right now; chats won't be saved this session."))
      }
    }
  }

  static func makeContainer(_ configuration: ModelConfiguration) throws -> ModelContainer {
    try ModelContainer(
      for: ChatStore.schema, migrationPlan: ChatMigrationPlan.self,
      configurations: [configuration])
  }

  private static func inMemory(notice: String) -> Opened {
    let memory = ModelConfiguration(schema: ChatStore.schema, isStoredInMemoryOnly: true)
    return Opened(
      // swiftlint:disable:next force_try - an in-memory store has no file to fail on
      container: try! makeContainer(memory), recoveryNotice: notice)
  }

  /// Whether an existing store and its SQLite sidecars can be read now (missing files are fine).
  static func isReadable(_ store: URL) -> Bool {
    for suffix in ["", "-wal", "-shm"] {
      let url = URL(fileURLWithPath: store.path + suffix)
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
      defer { try? handle.close() }
      do {
        _ = try handle.read(upToCount: 16)
      } catch {
        return false
      }
    }
    return true
  }

  /// True when an existing store file is readable, non-empty, and lacks SQLite's 16-byte header.
  static func hasCorruptHeader(_ store: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: store.path),
      let handle = try? FileHandle(forReadingFrom: store)
    else { return false }
    defer { try? handle.close() }
    guard let header = try? handle.read(upToCount: sqliteMagic.count), !header.isEmpty else {
      return false
    }
    return header != sqliteMagic
  }

  // Core Data and SQLite codes behind a failed open.
  private static let newerVersionCodes: Set<Int> = [
    134_100,  // NSPersistentStoreIncompatibleVersionHashError
    134_130,  // NSMigrationMissingSourceModelError: no stage knows the store's version
  ]
  private static let migrationFailedCodes: Set<Int> = [
    134_110,  // NSMigrationError
    134_140,  // NSMigrationMissingMappingModelError
  ]
  private static let unavailableCocoaCodes: Set<Int> = [
    255,  // NSFileLockingError
    257,  // NSFileReadNoPermissionError
    513,  // NSFileWriteNoPermissionError
    640,  // NSFileWriteOutOfSpaceError
    134_091,  // NSPersistentStoreTimeoutError
  ]
  private static let corruptSQLiteCodes: Set<Int> = [11, 26]  // SQLITE_CORRUPT, SQLITE_NOTADB
  private static let unavailableSQLiteCodes: Set<Int> = [
    3, 5, 6, 7, 8, 10, 13, 14, 23,  // PERM, BUSY, LOCKED, NOMEM, READONLY, IOERR, FULL, CANTOPEN, AUTH
  ]

  /// Why `error` kept the store from opening, from the error and the errors it wraps.
  static func classify(_ error: Error) -> Failure {
    var cocoaCodes: Set<Int> = []
    var sqliteCodes: Set<Int> = []
    var pending: [NSError] = [error as NSError]
    var seen = 0
    while let next = pending.popLast(), seen < 16 {
      seen += 1
      if next.domain == NSCocoaErrorDomain { cocoaCodes.insert(next.code) }
      if next.domain == "NSSQLiteErrorDomain" { sqliteCodes.insert(next.code & 0xFF) }
      if let sqlite = next.userInfo["NSSQLiteErrorDomain"] as? Int {
        sqliteCodes.insert(sqlite & 0xFF)
      }
      if let underlying = next.userInfo[NSUnderlyingErrorKey] as? NSError { pending.append(underlying) }
      // Core Data's NSDetailedErrorsKey.
      if let detailed = next.userInfo["NSDetailedErrors"] as? [NSError] { pending += detailed }
    }
    if !sqliteCodes.isDisjoint(with: corruptSQLiteCodes) || cocoaCodes.contains(259) {
      return .corrupt  // 259: NSFileReadCorruptFileError
    }
    if !cocoaCodes.isDisjoint(with: newerVersionCodes) { return .newerVersion }
    if !sqliteCodes.isDisjoint(with: unavailableSQLiteCodes)
      || !cocoaCodes.isDisjoint(with: unavailableCocoaCodes)
    {
      return .unavailable
    }
    if !cocoaCodes.isDisjoint(with: migrationFailedCodes) { return .migrationFailed }
    return .other
  }

  /// Rename the store and its SQLite sidecar files; returns the new store URL. Aborts without
  /// touching `-wal`/`-shm` if moving the primary store file fails so WAL frames stay paired.
  @discardableResult
  static func moveAside(_ store: URL) -> URL? {
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let backup = store.deletingLastPathComponent()
      .appendingPathComponent("\(store.lastPathComponent).unreadable-\(stamp)")
    guard FileManager.default.fileExists(atPath: store.path) else { return nil }
    guard (try? FileManager.default.moveItem(at: store, to: backup)) != nil else { return nil }
    for suffix in ["-shm", "-wal"] {
      let source = URL(fileURLWithPath: store.path + suffix)
      guard FileManager.default.fileExists(atPath: source.path) else { continue }
      let destination = URL(fileURLWithPath: backup.path + suffix)
      _ = try? FileManager.default.moveItem(at: source, to: destination)
    }
    return backup
  }

  /// Delete set-aside copies beyond the ``keptBackups`` newest (their names sort by date).
  static func pruneBackups(of store: URL) {
    let folder = store.deletingLastPathComponent()
    let prefix = "\(store.lastPathComponent).unreadable-"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    let backups = names.filter { $0.hasPrefix(prefix) && !$0.hasSuffix("-shm") && !$0.hasSuffix("-wal") }
      .sorted(by: >)
    for name in backups.dropFirst(keptBackups) {
      for suffix in ["", "-shm", "-wal"] {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name + suffix))
      }
    }
  }
}
