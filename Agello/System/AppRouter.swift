import Foundation
import Observation

/// Requests from outside the chat screen (Siri and Shortcuts, widgets,
/// Control Center, Spotlight, deep links). They all hand off to the app,
/// which does the work in the foreground (the model can't run in extensions
/// or the background).
@MainActor
@Observable
final class AppRouter {
  static let shared = AppRouter()

  enum Action: Equatable, Sendable {
    /// Open a new, empty chat.
    case newChat
    /// Open a new chat and send this message (Siri and Shortcuts).
    case ask(String)
    /// Open a new chat with this message in the composer, unsent: a link (`agello://ask`) can
    /// come from any page or app, so it never sends for the user.
    case draft(String)
    /// Open voice mode in a new chat.
    case voice
    /// Open a saved chat.
    case openChat(UUID)
  }

  /// The action waiting to be carried out by the chat screen.
  var pending: Action?
  /// Voice mode should open over the current (new) chat.
  var voiceRequested = false
  /// Text for the new chat's composer (``Action/draft(_:)``).
  var draftRequested: String?

  /// The most recent request (kept after it's carried out; diagnostics).
  private(set) var lastHandled: Action?

  func handle(_ action: Action) {
    lastHandled = action
    pending = action
  }

  /// Takes the pending action (the screen that carries it out calls this).
  func take() -> Action? {
    defer { pending = nil }
    return pending
  }

  // MARK: Deep links

  nonisolated static let scheme = "agello"

  /// `agello://new`, `agello://voice`, `agello://ask?q=…`, `agello://chat/<id>`.
  nonisolated static func action(for url: URL) -> Action? {
    guard url.scheme?.lowercased() == scheme, let host = url.host()?.lowercased() else { return nil }
    switch host {
    case "new":
      return .newChat
    case "voice":
      return .voice
    case "ask":
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "q" }?.value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let query, !query.isEmpty else { return .newChat }
      return .draft(String(query.prefix(4_000)))
    case "chat":
      let id = url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:))
      return id.map(Action.openChat)
    default:
      return nil
    }
  }

  nonisolated static func url(for action: Action) -> URL {
    switch action {
    case .newChat: return URL(string: "\(scheme)://new")!
    case .voice: return URL(string: "\(scheme)://voice")!
    case .openChat(let id): return URL(string: "\(scheme)://chat/\(id.uuidString)")!
    case .ask(let text), .draft(let text):
      var components = URLComponents(string: "\(scheme)://ask")!
      components.queryItems = [URLQueryItem(name: "q", value: text)]
      return components.url!
    }
  }
}
