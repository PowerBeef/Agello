import Foundation

/// Items shared to Agello from other apps. The share extension can't run
/// the model or open the app, so it saves what was shared (and the user's
/// question) here, in the app group; the app answers it when it's next
/// opened. Compiled into the app and the share extension.
enum ShareInbox {
  static let appGroup = "group.com.patricedery.agello"

  enum Kind: String, Codable, Sendable {
    case text, url, image, file
  }

  struct Item: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    var kind: Kind
    /// What the user typed in the share sheet (may be empty).
    var question: String
    var text: String?
    var url: String?
    /// Name of the attached file in the item's folder (image or document).
    var fileName: String?
    var createdAt = Date()
  }

  /// The inbox folder (nil when the app group isn't available).
  static func directory(base: URL? = nil) -> URL? {
    guard
      let root = base
        ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    else { return nil }
    let inbox = root.appendingPathComponent("ShareInbox", isDirectory: true)
    try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    return inbox
  }

  /// Save an item, with `file` (copied) when there is one. The item becomes
  /// visible to the app only once fully written.
  @discardableResult
  static func save(_ item: Item, file: URL? = nil, fileData: Data? = nil, base: URL? = nil) throws -> URL {
    guard let inbox = directory(base: base) else { throw CocoaError(.fileNoSuchFile) }
    let staging = inbox.appendingPathComponent(".\(item.id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    if let fileName = item.fileName {
      let destination = staging.appendingPathComponent(fileName)
      if let file {
        let accessing = file.startAccessingSecurityScopedResource()
        defer { if accessing { file.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: file, to: destination)
      } else if let fileData {
        try fileData.write(to: destination)
      }
    }
    try JSONEncoder().encode(item).write(to: staging.appendingPathComponent("item.json"))
    let final = inbox.appendingPathComponent(item.id.uuidString, isDirectory: true)
    try FileManager.default.moveItem(at: staging, to: final)
    return final
  }

  /// Saved items, oldest first, with their attached file if any.
  static func pending(base: URL? = nil) -> [(item: Item, file: URL?)] {
    guard let inbox = directory(base: base),
      let folders = try? FileManager.default.contentsOfDirectory(
        at: inbox, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else { return [] }
    return folders.compactMap { folder in
      guard let data = try? Data(contentsOf: folder.appendingPathComponent("item.json")),
        let item = try? JSONDecoder().decode(Item.self, from: data)
      else { return nil }
      return (item, item.fileName.map { folder.appendingPathComponent($0) })
    }
    .sorted { $0.item.createdAt < $1.item.createdAt }
  }

  /// Remove an item once the app has taken it.
  static func remove(_ id: UUID, base: URL? = nil) {
    guard let inbox = directory(base: base) else { return }
    try? FileManager.default.removeItem(at: inbox.appendingPathComponent(id.uuidString))
  }

  /// The question to send: what the user typed, or a sensible default.
  static func question(for item: Item) -> String {
    let typed = item.question.trimmingCharacters(in: .whitespacesAndNewlines)
    if !typed.isEmpty { return typed }
    switch item.kind {
    case .image: return String(localized: "What's in this image?")
    case .text where (item.text?.count ?? 0) <= ShareInbox.inlineTextLimit:
      return item.text ?? ""
    default: return String(localized: "Summarize this.")
    }
  }

  /// Shared text up to this long is sent inline; longer text is attached
  /// as a document.
  static let inlineTextLimit = 600
}
