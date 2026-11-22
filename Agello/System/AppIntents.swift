import AppIntents

/// Ask a question: opens Agello in a new chat and sends it. Requires device unlock so
/// lock-screen Siri/Shortcuts invocations cannot trigger personal-context tools unauthenticated.
struct AskAgelloIntent: AppIntent {
  static let title: LocalizedStringResource = "Ask Agello"
  static let description = IntentDescription(
    "Ask the on-device assistant a question in a new chat.")
  static let supportedModes: IntentModes = .foreground(.immediate)
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  @Parameter(title: "Question", requestValueDialog: "What would you like to ask?")
  var question: String

  @MainActor
  func perform() async throws -> some IntentResult {
    AppRouter.shared.handle(.ask(question))
    return .result()
  }
}

/// Siri phrases, the Shortcuts app, Spotlight, and the Action Button.
struct AgelloShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: AskAgelloIntent(),
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
    AppShortcut(
      intent: SnapAndAskIntent(),
      phrases: [
        "Snap and ask \(.applicationName)",
        "Take a photo with \(.applicationName)",
        "Show a photo to \(.applicationName)",
      ],
      shortTitle: "Snap & Ask", systemImageName: "camera.viewfinder")
    AppShortcut(
      intent: VoiceWithCameraIntent(),
      phrases: [
        "Voice with camera in \(.applicationName)",
        "Show \(.applicationName) my camera",
        "Look and talk with \(.applicationName)",
      ],
      shortTitle: "Voice & Camera", systemImageName: "video.fill")
  }
}
