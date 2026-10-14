import AppIntents

// Compiled into the app and the widget extension (Control Center buttons
// and widgets). They open the app, so the system runs `perform()` in the
// app process; the extension's copy has nothing to do.

/// Open a new, empty chat.
struct NewChatIntent: AppIntent {
  static let title: LocalizedStringResource = "New Chat"
  static let description = IntentDescription("Start a new chat in Agello.")
  static let supportedModes: IntentModes = .foreground(.immediate)

  func perform() async throws -> some IntentResult {
    #if !WIDGET_EXTENSION
      await MainActor.run { AppRouter.shared.handle(.newChat) }
    #endif
    return .result()
  }
}

/// Talk hands-free (voice mode).
struct StartVoiceModeIntent: AppIntent {
  static let title: LocalizedStringResource = "Talk to Agello"
  static let description = IntentDescription("Start a hands-free voice conversation.")
  static let supportedModes: IntentModes = .foreground(.immediate)

  func perform() async throws -> some IntentResult {
    #if !WIDGET_EXTENSION
      await MainActor.run { AppRouter.shared.handle(.voice) }
    #endif
    return .result()
  }
}
