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
    /// Open voice mode with the live camera already on (Action Button / Control Center / Siri).
    case voiceWithCamera
    /// Open a new chat and launch the camera to snap a photo and ask about it.
    case snapAndAsk
    /// Open a saved chat.
    case openChat(UUID)
    /// Open a saved project sheet.
    case openProject(UUID)
    /// Open the chat or project that owns a saved document.
    case openDocument(UUID)
  }

  /// The action waiting to be carried out by the chat screen.
  var pending: Action?
  /// Voice mode should open over the current (new) chat.
  var voiceRequested = false
  /// Voice mode should open with the live camera already on.
  var voiceWithCameraRequested = false
  /// Camera capture should open over the current (new) chat ("Snap & Ask").
  var cameraRequested = false
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

  /// `agello://new`, `agello://voice`, `agello://voice-camera`, `agello://camera`,
  /// `agello://ask?q=…`, `agello://chat/<id>`, `agello://project/<id>`, `agello://document/<id>`.
  nonisolated static func action(for url: URL) -> Action? {
    guard url.scheme?.lowercased() == scheme, let host = url.host()?.lowercased() else { return nil }
    switch host {
    case "new":
      return .newChat
    case "voice":
      return .voice
    case "voice-camera":
      return .voiceWithCamera
    case "camera":
      return .snapAndAsk
    case "ask":
      let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "q" }?.value?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard let query, !query.isEmpty else { return .newChat }
      return .draft(String(query.prefix(4_000)))
    case "chat":
      let id = url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:))
      return id.map(Action.openChat)
    case "project":
      let id = url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:))
      return id.map(Action.openProject)
    case "document":
      let id = url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:))
      return id.map(Action.openDocument)
    default:
      return nil
    }
  }

  nonisolated static func url(for action: Action) -> URL {
    switch action {
    case .newChat: return URL(string: "\(scheme)://new")!
    case .voice: return URL(string: "\(scheme)://voice")!
    case .voiceWithCamera: return URL(string: "\(scheme)://voice-camera")!
    case .snapAndAsk: return URL(string: "\(scheme)://camera")!
    case .openChat(let id): return URL(string: "\(scheme)://chat/\(id.uuidString)")!
    case .openProject(let id): return URL(string: "\(scheme)://project/\(id.uuidString)")!
    case .openDocument(let id): return URL(string: "\(scheme)://document/\(id.uuidString)")!
    case .ask(let text), .draft(let text):
      var components = URLComponents(string: "\(scheme)://ask")!
      components.queryItems = [URLQueryItem(name: "q", value: text)]
      return components.url!
    }
  }
}
