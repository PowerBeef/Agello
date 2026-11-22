import AppIntents

// Compiled into the app and the widget extension (Control Center buttons
// and widgets). They open the app, so the system runs `perform()` in the
// app process; the extension's copy has nothing to do.

/// Open a new, empty chat.
struct NewChatIntent: AppIntent {
  static let title: LocalizedStringResource = "New Chat"
  static let description = IntentDescription("Start a new chat in Agello.")
  static let supportedModes: IntentModes = .foreground(.immediate)
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  func perform() async throws -> some IntentResult {
    #if !WIDGET_EXTENSION
      await MainActor.run { AppRouter.shared.handle(.newChat) }
    #endif
    return .result()
  }
}

/// Talk hands-free (voice mode). Requires device unlock so voice queries cannot access
/// personal-context tools from a locked screen.
struct StartVoiceModeIntent: AppIntent {
  static let title: LocalizedStringResource = "Talk to Agello"
  static let description = IntentDescription("Start a hands-free voice conversation.")
  static let supportedModes: IntentModes = .foreground(.immediate)
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  func perform() async throws -> some IntentResult {
    #if !WIDGET_EXTENSION
      await MainActor.run { AppRouter.shared.handle(.voice) }
    #endif
    return .result()
  }
}

/// Open a new chat and immediately launch the camera to snap a photo and ask about it.
/// Requires device unlock so lock-screen triggers cannot access the camera or personal tools.
struct SnapAndAskIntent: AppIntent {
  static let title: LocalizedStringResource = "Snap & Ask Agello"
  static let description = IntentDescription("Take a photo and ask Agello about it in a new chat.")
  static let supportedModes: IntentModes = .foreground(.immediate)
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  func perform() async throws -> some IntentResult {
    #if !WIDGET_EXTENSION
      await MainActor.run { AppRouter.shared.handle(.snapAndAsk) }
    #endif
    return .result()
  }
}

/// Start hands-free voice mode with the live camera active so Agello can see while listening.
struct VoiceWithCameraIntent: AppIntent {
  static let title: LocalizedStringResource = "Voice with Camera"
  static let description = IntentDescription(
    "Start a hands-free voice conversation with the camera on.")
  static let supportedModes: IntentModes = .foreground(.immediate)
  static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  func perform() async throws -> some IntentResult {
    #if !WIDGET_EXTENSION
      await MainActor.run { AppRouter.shared.handle(.voiceWithCamera) }
    #endif
    return .result()
  }
}
