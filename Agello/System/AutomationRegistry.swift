import CryptoKit
import Foundation
import Synchronization

/// User-allowlisted Apple Shortcut registered for Agello's outbound Shortcuts Bridge.
/// Only Shortcuts explicitly added here can ever be proposed or invoked by ``RunShortcutTool``.
struct RegisteredShortcut: Codable, Equatable, Identifiable, Sendable {
  enum PayloadMode: String, Codable, Equatable, Sendable, CaseIterable {
    case none
    case text
    case json

    var displayName: String {
      switch self {
      case .none: "No payload"
      case .text: "Plain text"
      case .json: "JSON"
      }
    }
  }

  var id: String
  /// Exact Apple Shortcuts name passed to `shortcuts://x-callback-url/run-shortcut?name=...`.
  var name: String
  /// Concise 1-line description surfaced to the model and confirmation card.
  var summary: String
  var inputMode: PayloadMode = .text
  var outputMode: PayloadMode = .text
  var symbol: String = "bolt.fill"
  var enabled: Bool = true
  var iCloudTemplateURL: String? = nil

  init(
    id: String? = nil, name: String, summary: String,
    inputMode: PayloadMode = .text, outputMode: PayloadMode = .text,
    symbol: String = "bolt.fill", enabled: Bool = true, iCloudTemplateURL: String? = nil
  ) {
    let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.id = id ?? Self.slug(from: cleanName)
    self.name = cleanName
    self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    self.inputMode = inputMode
    self.outputMode = outputMode
    self.symbol = symbol
    self.enabled = enabled
    self.iCloudTemplateURL = iCloudTemplateURL
  }

  static func slug(from name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let folded = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    let scalars = folded.unicodeScalars.map { scalar -> Character in
      CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
    }
    let collapsed = String(scalars)
      .split(separator: "_", omittingEmptySubsequences: true)
      .joined(separator: "_")
    if !collapsed.isEmpty {
      return String(collapsed.prefix(40))
    }
    guard !trimmed.isEmpty else { return "" }
    // Deterministic hash for emoji- or symbol-only names so duplicates resolve to the same slug.
    let digest = SHA256.hash(data: Data(trimmed.lowercased().utf8))
    let hex = digest.prefix(5).map { String(format: "%02x", $0) }.joined()
    return "sc_\(hex)"
  }
}

/// Curated starter Shortcut template surfaced in ``AutomationGalleryView`` to help users
/// set up common iOS automations (Apple Home, Notes, Expenses, Messaging, Music) without
/// shipping private APIs or HomeKit entitlements.
struct StarterShortcutTemplate: Identifiable, Equatable, Sendable {
  let id: String
  let name: String
  let summary: String
  let symbol: String
  let inputMode: RegisteredShortcut.PayloadMode
  let outputMode: RegisteredShortcut.PayloadMode
  let setupHint: String
  let iCloudURL: String?

  func asRegisteredShortcut() -> RegisteredShortcut {
    RegisteredShortcut(
      id: id, name: name, summary: summary,
      inputMode: inputMode, outputMode: outputMode,
      symbol: symbol, enabled: true, iCloudTemplateURL: iCloudURL)
  }

  static let curated: [StarterShortcutTemplate] = [
    StarterShortcutTemplate(
      id: "save_to_apple_notes",
      name: "Save Note from Agello",
      summary: "Create a new Apple Note with the provided text.",
      symbol: "note.text.badge.plus",
      inputMode: .text, outputMode: .text,
      setupHint: "In Shortcuts, create \"Save Note from Agello\" with Action: Create Note (Shortcut Input) → Stop and Output \"Saved\".",
      iCloudURL: nil),
    StarterShortcutTemplate(
      id: "control_home_scene",
      name: "Run Home Scene",
      summary: "Trigger an Apple Home scene or accessory by name (e.g. Movie Night, Goodnight).",
      symbol: "homekit",
      inputMode: .text, outputMode: .text,
      setupHint: "In Shortcuts, create \"Run Home Scene\" using Control Home actions matched to Shortcut Input.",
      iCloudURL: nil),
    StarterShortcutTemplate(
      id: "log_expense",
      name: "Log Expense",
      summary: "Append a date, merchant, and amount line to your expense tracker note or Numbers sheet.",
      symbol: "dollarsign.circle.fill",
      inputMode: .text, outputMode: .text,
      setupHint: "In Shortcuts, create \"Log Expense\" with Append to Note or Add Row to Numbers using Shortcut Input.",
      iCloudURL: nil),
    StarterShortcutTemplate(
      id: "play_focus_playlist",
      name: "Play Focus Music",
      summary: "Start your focus playlist or ambient soundscape in Apple Music.",
      symbol: "music.note.list",
      inputMode: .none, outputMode: .none,
      setupHint: "In Shortcuts, create \"Play Focus Music\" with Play Music (your playlist) and Shuffle on.",
      iCloudURL: nil),
  ]
}

/// Multi-step agentic workflow saved for 1-tap execution from the Automation Gallery or Siri/Shortcuts.
struct AutomationRecipe: Codable, Equatable, Identifiable, Sendable {
  var id: String
  var name: String
  var summary: String
  var prompt: String
  var symbol: String

  static let builtIn: [AutomationRecipe] = [
    AutomationRecipe(
      id: "morning_briefing",
      name: "Morning Briefing",
      summary: "Check today's calendar, open reminders, and local weather in one pass.",
      prompt: "Give me my morning briefing: check today's calendar events, my incomplete reminders, and the weather right now.",
      symbol: "sun.horizon.fill"),
    AutomationRecipe(
      id: "after_meeting_wrapup",
      name: "After-Meeting Wrap-Up",
      summary: "Check my next free slot tomorrow and prepare follow-up reminders.",
      prompt: "Check my open slots tomorrow afternoon and list any incomplete follow-up reminders I should prioritize.",
      symbol: "checkmark.rectangle.stack.fill"),
    AutomationRecipe(
      id: "commute_check",
      name: "Commute & Nearby Check",
      summary: "Check local weather and driving time to my next scheduled event location.",
      prompt: "Check my next calendar event today; if it has a location, estimate driving time there and check the current weather.",
      symbol: "car.fill"),
  ]
}

/// Thread-safe allowlist store for user-registered Shortcuts and saved Recipes.
/// Persisted in `UserDefaults`; never populated automatically from untrusted content.
final class AutomationRegistry: @unchecked Sendable {
  static let shared = AutomationRegistry()
  static let shortcutsDefaultsKey = "automationRegistry.shortcuts"
  static let recipesDefaultsKey = "automationRegistry.recipes"
  static let didChangeNotification = Notification.Name("com.patricedery.agello.automationRegistryDidChange")

  /// Upper bound on shortcuts embedded directly into the `run_shortcut` enum schema.
  static let maxSchemaShortcuts = 10

  private struct State {
    var shortcuts: [RegisteredShortcut]
    var customRecipes: [AutomationRecipe]
  }

  private let defaults: UserDefaults
  private let state: Mutex<State>

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let loadedShortcuts: [RegisteredShortcut]
    if let data = defaults.data(forKey: Self.shortcutsDefaultsKey),
      let decoded = try? JSONDecoder().decode([RegisteredShortcut].self, from: data)
    {
      loadedShortcuts = decoded
    } else {
      loadedShortcuts = []
    }
    let loadedRecipes: [AutomationRecipe]
    if let data = defaults.data(forKey: Self.recipesDefaultsKey),
      let decoded = try? JSONDecoder().decode([AutomationRecipe].self, from: data)
    {
      loadedRecipes = decoded
    } else {
      loadedRecipes = []
    }
    self.state = Mutex(State(shortcuts: loadedShortcuts, customRecipes: loadedRecipes))
  }

  /// All registered shortcuts (enabled and disabled).
  var shortcuts: [RegisteredShortcut] {
    state.withLock { $0.shortcuts }
  }

  /// Enabled allowlisted shortcuts eligible for `RunShortcutTool`.
  var enabledShortcuts: [RegisteredShortcut] {
    state.withLock { $0.shortcuts.filter(\.enabled) }
  }

  /// Built-in recipes combined with any user-saved custom recipes.
  var allRecipes: [AutomationRecipe] {
    AutomationRecipe.builtIn + state.withLock { $0.customRecipes }
  }

  func recipe(id: String) -> AutomationRecipe? {
    let clean = id.trimmingCharacters(in: .whitespacesAndNewlines)
    return allRecipes.first {
      $0.id.caseInsensitiveCompare(clean) == .orderedSame
        || $0.name.caseInsensitiveCompare(clean) == .orderedSame
    }
  }

  /// Exact allowlist match by `id` or exact `name` (case-insensitive). Returns `nil` for any
  /// unregistered or disabled shortcut so unknown shortcuts are rejected pre-confirmation.
  func shortcut(matching idOrName: String) -> RegisteredShortcut? {
    let clean = idOrName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return nil }
    return state.withLock { s in
      s.shortcuts.first { item in
        item.enabled
          && (item.id.caseInsensitiveCompare(clean) == .orderedSame
            || item.name.caseInsensitiveCompare(clean) == .orderedSame)
      }
    }
  }

  /// Selects at most `limit` enabled shortcuts for schema injection. When more than `limit`
  /// shortcuts are registered, ranks them by keyword relevance (plus optional ANE semantic scores)
  /// so Gemma 4 E4B's tool schema stays compact.
  func activeShortcuts(
    for query: String? = nil, semanticScores: [String: Float] = [:],
    limit: Int = maxSchemaShortcuts
  ) -> [RegisteredShortcut] {
    let enabled = enabledShortcuts
    guard enabled.count > limit else { return enabled }
    guard let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return Array(enabled.prefix(limit))
    }
    let docs = enabled.map { "\($0.name) \($0.summary) \($0.id)" }
    let kw = KeywordScorer.scores(query: query, documents: docs)
    let ranked = zip(enabled, kw).sorted { lhs, rhs in
      let lScore = lhs.1 + Double(semanticScores[lhs.0.id] ?? 0) * 4.0
      let rScore = rhs.1 + Double(semanticScores[rhs.0.id] ?? 0) * 4.0
      if lScore != rScore { return lScore > rScore }
      return lhs.0.name < rhs.0.name
    }
    return Array(ranked.prefix(limit).map(\.0))
  }

  /// Deterministic fingerprint for `InferenceOptions.toolSetKey`.
  var toolSetFingerprint: String {
    let ids = enabledShortcuts.prefix(Self.maxSchemaShortcuts).map(\.id).joined(separator: ",")
    return ids
  }

  enum RegistrationError: Error, LocalizedError, Equatable {
    case emptyName
    case duplicateName(existing: String)
    case slugCollision(existing: String)

    var errorDescription: String? {
      switch self {
      case .emptyName:
        return String(localized: "Enter a Shortcut name.")
      case .duplicateName(let existing):
        return String(localized: "A Shortcut named \"\(existing)\" is already registered.")
      case .slugCollision(let existing):
        return String(
          localized: "That name conflicts with the existing Shortcut \"\(existing)\". Choose a distinct name.")
      }
    }
  }

  /// Registers a brand-new Shortcut, rejecting empty names, duplicate names (including emoji-only
  /// names), and slug collisions instead of silently overwriting an existing entry.
  @discardableResult
  func register(_ shortcut: RegisteredShortcut) throws -> RegisteredShortcut {
    let cleanName = shortcut.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanName.isEmpty else { throw RegistrationError.emptyName }
    let cleanID = shortcut.id.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedID = cleanID.isEmpty ? RegisteredShortcut.slug(from: cleanName) : cleanID
    var item = shortcut
    item.name = cleanName
    item.id = resolvedID

    let result: Result<[RegisteredShortcut], RegistrationError> = state.withLock { s in
      if let duplicate = s.shortcuts.first(where: {
        $0.name.caseInsensitiveCompare(cleanName) == .orderedSame
      }) {
        return .failure(.duplicateName(existing: duplicate.name))
      }
      if let colliding = s.shortcuts.first(where: {
        $0.id.caseInsensitiveCompare(resolvedID) == .orderedSame
      }) {
        return .failure(.slugCollision(existing: colliding.name))
      }
      s.shortcuts.append(item)
      return .success(s.shortcuts)
    }
    switch result {
    case .success(let snapshot):
      persist(shortcuts: snapshot)
      return item
    case .failure(let error):
      throw error
    }
  }

  /// Inserts or updates a Shortcut safely: updates in place when matching by exact name or
  /// matching ID+name, deduplicates identical names (including emoji-only), and disambiguates
  /// colliding slugs so an unrelated Shortcut is never silently overwritten.
  func upsert(_ shortcut: RegisteredShortcut) {
    let cleanName = shortcut.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanName.isEmpty else { return }
    let snapshot: [RegisteredShortcut] = state.withLock { s in
      var item = shortcut
      item.name = cleanName
      if item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        item.id = RegisteredShortcut.slug(from: cleanName)
      }
      if let nameIdx = s.shortcuts.firstIndex(where: {
        $0.name.caseInsensitiveCompare(cleanName) == .orderedSame
      }) {
        item.id = s.shortcuts[nameIdx].id
        s.shortcuts[nameIdx] = item
      } else if s.shortcuts.contains(where: {
        $0.id.caseInsensitiveCompare(item.id) == .orderedSame
      }) {
        // Different name folded to the same slug: assign a unique disambiguated ID instead of
        // overwriting the existing Shortcut.
        item.id = Self.uniqueSlug(base: item.id, existing: s.shortcuts)
        s.shortcuts.append(item)
      } else {
        s.shortcuts.append(item)
      }
      return s.shortcuts
    }
    persist(shortcuts: snapshot)
  }

  private static func uniqueSlug(base: String, existing: [RegisteredShortcut]) -> String {
    let used = Set(existing.map { $0.id.lowercased() })
    if !used.contains(base.lowercased()) { return base }
    var suffix = 2
    while true {
      let tag = "_\(suffix)"
      let prefix = String(base.prefix(max(1, 40 - tag.count)))
      let candidate = prefix + tag
      if !used.contains(candidate.lowercased()) { return candidate }
      suffix += 1
    }
  }

  func removeShortcut(id: String) {
    let snapshot: [RegisteredShortcut] = state.withLock { s in
      s.shortcuts.removeAll { $0.id == id }
      return s.shortcuts
    }
    persist(shortcuts: snapshot)
  }

  func setShortcuts(_ list: [RegisteredShortcut]) {
    state.withLock { $0.shortcuts = list }
    persist(shortcuts: list)
  }

  func upsertRecipe(_ recipe: AutomationRecipe) {
    let snapshot: [AutomationRecipe] = state.withLock { s in
      if let idx = s.customRecipes.firstIndex(where: { $0.id == recipe.id }) {
        s.customRecipes[idx] = recipe
      } else {
        s.customRecipes.append(recipe)
      }
      return s.customRecipes
    }
    if let data = try? JSONEncoder().encode(snapshot) {
      defaults.set(data, forKey: Self.recipesDefaultsKey)
    }
    NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
  }

  func removeRecipe(id: String) {
    let snapshot: [AutomationRecipe] = state.withLock { s in
      s.customRecipes.removeAll { $0.id == id }
      return s.customRecipes
    }
    if let data = try? JSONEncoder().encode(snapshot) {
      defaults.set(data, forKey: Self.recipesDefaultsKey)
    }
    NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
  }

  private func persist(shortcuts: [RegisteredShortcut]) {
    if let data = try? JSONEncoder().encode(shortcuts) {
      defaults.set(data, forKey: Self.shortcutsDefaultsKey)
    }
    NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
  }
}
