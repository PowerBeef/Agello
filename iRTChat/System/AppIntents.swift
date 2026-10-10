import AppIntents

/// Ask a question: opens iRTChat in a new chat and sends it.
struct AskIRTChatIntent: AppIntent {
  static let title: LocalizedStringResource = "Ask iRTChat"
  static let description = IntentDescription(
    "Ask the on-device assistant a question in a new chat.")
  static let supportedModes: IntentModes = .foreground(.immediate)

  @Parameter(title: "Question", requestValueDialog: "What would you like to ask?")
  var question: String

  @MainActor
  func perform() async throws -> some IntentResult {
    AppRouter.shared.handle(.ask(question))
    return .result()
  }
}

/// Open a new, empty chat.
struct NewChatIntent: AppIntent {
  static let title: LocalizedStringResource = "New Chat"
  static let description = IntentDescription("Start a new chat in iRTChat.")
  static let supportedModes: IntentModes = .foreground(.immediate)

  @MainActor
  func perform() async throws -> some IntentResult {
    AppRouter.shared.handle(.newChat)
    return .result()
  }
}

/// Talk hands-free (voice mode).
struct StartVoiceModeIntent: AppIntent {
  static let title: LocalizedStringResource = "Talk to iRTChat"
  static let description = IntentDescription("Start a hands-free voice conversation.")
  static let supportedModes: IntentModes = .foreground(.immediate)

  @MainActor
  func perform() async throws -> some IntentResult {
    AppRouter.shared.handle(.voice)
    return .result()
  }
}

/// Siri phrases, the Shortcuts app, Spotlight, and the Action Button.
struct IRTChatShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: AskIRTChatIntent(),
      phrases: ["Ask \(.applicationName)", "Ask \(.applicationName) a question"],
      shortTitle: "Ask", systemImageName: "bubble.left.and.text.bubble.right")
    AppShortcut(
      intent: StartVoiceModeIntent(),
      phrases: ["Talk to \(.applicationName)", "Start a voice chat in \(.applicationName)"],
      shortTitle: "Talk", systemImageName: "waveform")
    AppShortcut(
      intent: NewChatIntent(),
      phrases: ["New chat in \(.applicationName)", "Start a new \(.applicationName) chat"],
      shortTitle: "New Chat", systemImageName: "square.and.pencil")
  }
}
