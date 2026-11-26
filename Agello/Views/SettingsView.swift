import SwiftUI

/// Settings: the model's status on top, then what people change
/// (personalization, memory, web search, Spotlight, models, tools), help and
/// about. The engine's choices aren't settings: the app makes them. Engine
/// changes coalesce and apply once when Settings closes. Five taps on the
/// version line open ``DeveloperSettingsView``.
struct SettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize
  @AppStorage(SpotlightIndex.enabledKey) private var spotlightEnabled = true
  @State private var showDeveloper = false
  @State private var spotlightTask: Task<Void, Never>?
  @State private var versionTapCount = 0
  @State private var versionTapWindowStart: ContinuousClock.Instant?

  private var bindable: Bindable<AppState> { Bindable(appState) }

  var body: some View {
    NavigationStack {
      Form {
        statusSection
        youSection
        modelSection
        helpSection
        aboutSection
      }
      .themedList(Theme.Brand.glacier)
      .navigationTitle("Settings")
      .inlineTitleDisplay()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .close) { dismiss() }
            .accessibilityIdentifier("settings.done")
        }
      }
      // On the Form, not on a row: a destination inside a lazy container isn't always found.
      .navigationDestination(isPresented: $showDeveloper) { DeveloperSettingsView() }
    }
    .appliesEngineSettings(appState)
  }

  // MARK: - Status

  private var statusSection: some View {
    Section {
      Group {
        if typeSize.isAccessibilitySize {
          VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
              TintTile(symbol: "sparkles", tint: Theme.Brand.glacier, size: 44)
              statusHeaderText
            }
            StatusBadge(text: status.word, tone: status.tone)
          }
        } else {
          HStack(spacing: Theme.Spacing.md) {
            TintTile(symbol: "sparkles", tint: Theme.Brand.glacier, size: 44)
            statusHeaderText
            Spacer(minLength: Theme.Spacing.sm)
            StatusBadge(text: status.word, tone: status.tone)
          }
        }
      }
      .padding(.vertical, Theme.Spacing.xs)
      .themedRow()
    }
  }

  private var statusHeaderText: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
      Text(activeSpec.displayName)
        .font(.headline)
        .foregroundStyle(Theme.Text.primary)
      Text(statusLine)
        .font(.caption)
        .foregroundStyle(Theme.Text.tertiary)
        .accessibilityIdentifier("settings.status")
    }
  }

  private var activeSpec: ModelSpec { appState.store.activeSpec }

  private var status: (word: String, tone: Color) {
    switch appState.engineState {
    case .ready: (String(localized: "Ready"), Theme.Status.healthy)
    case .generating: (String(localized: "Working"), Theme.Status.healthy)
    case .loading: (String(localized: "Loading"), Theme.Status.guarded)
    case .failed: (String(localized: "Error"), Theme.Status.critical)
    case .idle:
      appState.store.isDownloaded(activeSpec)
        ? (String(localized: "Idle"), Theme.Text.tertiary)
        : (String(localized: "Not downloaded"), Theme.Status.guarded)
    }
  }

  private var statusLine: String {
    switch appState.engineState {
    case .ready:
      guard let resolved = appState.resolved else { return String(localized: "On this \(Platform.deviceName)") }
      return String(
        localized: "On this \(Platform.deviceName) · \(resolved.backendLabel) · \(resolved.maxNumTokens / 1000)K context")
    case .generating: return String(localized: "Writing a reply…")
    case .loading(let progress): return progress
    case .failed: return String(localized: "See the chat for details")
    case .idle:
      return appState.store.isDownloaded(activeSpec)
        ? String(localized: "Loads when you start a chat")
        : String(localized: "Download it in Models below")
    }
  }

  // MARK: - Sections

  private var youSection: some View {
    Section {
      NavigationLink {
        PersonalizationView()
      } label: {
        RowLabel(
          title: String(localized: "Personalization"), symbol: "person.crop.circle.fill",
          tint: Theme.Brand.glacier, value: personalizationSummary)
      }
      .themedRow()
      .accessibilityIdentifier("settings.personalization")
      NavigationLink {
        MemoryView()
      } label: {
        RowLabel(
          title: String(localized: "Memory"), symbol: "brain.head.profile",
          tint: Theme.Brand.lavender,
          value: appState.memoryEnabled ? String(localized: "On") : String(localized: "Off"))
      }
      .themedRow()
      .accessibilityIdentifier("settings.memory")
      NavigationLink {
        WebSearchSettingsView()
      } label: {
        RowLabel(
          title: String(localized: "Web search"), symbol: "globe", tint: Theme.Brand.teal,
          value: webSummary)
      }
      .themedRow()
      .accessibilityIdentifier("settings.web")
      Toggle(isOn: $spotlightEnabled) {
        RowLabel(
          title: String(localized: "Show chats in Spotlight"), symbol: "magnifyingglass",
          tint: Theme.Brand.silver)
      }
      .tint(Theme.Brand.glacier)
      .themedRow()
      .onChange(of: spotlightEnabled) {
        Haptics.selection()
        spotlightTask?.cancel()
        guard let context = appState.modelContext else { return }
        spotlightTask = Task(priority: .utility) {
          // Wait for the UISwitch animation to finish before indexing/clearing up to 900 records.
          try? await Task.sleep(for: .milliseconds(300))
          guard !Task.isCancelled else { return }
          await SpotlightIndex.refreshAsync(in: context, full: true)
        }
      }
      .accessibilityIdentifier("settings.spotlight")
    } header: {
      Text("You").eyebrowStyle()
    }
  }

  private var webSummary: String {
    let web = appState.webSettings
    guard web.allowed else { return String(localized: "Off") }
    return web.automatic ? String(localized: "Automatic") : web.provider.displayName
  }

  private var personalizationSummary: String {
    let p = appState.personalization
    guard p.enabled else { return String(localized: "Off") }
    let customized =
      p.style != .standard
      || !p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !p.aboutYou.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !p.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return customized ? p.style.displayName : String(localized: "Not set")
  }

  private var modelSection: some View {
    Section {
      NavigationLink {
        ModelLibraryView()
      } label: {
        RowLabel(
          title: String(localized: "Models"), symbol: "cube.fill", tint: Theme.Brand.glacier,
          value: activeSpec.displayName)
      }
      .themedRow()
      .accessibilityIdentifier("settings.models")
      Toggle(isOn: bindable.enableTools) {
        RowLabel(
          title: String(localized: "On-device tools"), symbol: "wrench.and.screwdriver.fill",
          tint: Theme.Brand.gold)
      }
      .tint(Theme.Mode.voice.tint)
      .themedRow()
      .onChange(of: appState.enableTools) { _, _ in Haptics.selection() }
      .accessibilityIdentifier("settings.tools")
      NavigationLink {
        PersonalToolsSettingsView()
      } label: {
        RowLabel(
          title: String(localized: "Personal tools"), symbol: "person.badge.shield.checkmark.fill",
          tint: Theme.Brand.gold, value: personalToolsSummary)
      }
      .themedRow()
      .disabled(!appState.enableTools)
      .accessibilityIdentifier("settings.personalTools")
      NavigationLink {
        AutomationGalleryView()
      } label: {
        RowLabel(
          title: String(localized: "Automations & Shortcuts"), symbol: "bolt.shield.fill",
          tint: Theme.Brand.glacier, value: automationsSummary)
      }
      .themedRow()
      .accessibilityIdentifier("settings.automations")
    } header: {
      Text("Model").eyebrowStyle()
    } footer: {
      Text(
        "Tools let the assistant check the date, calculate, convert units, query files and tables, and optionally access Calendar, Reminders, Contacts, Maps, Weather, Alarms, Photos, and registered Shortcuts on this \(Platform.deviceName)."
      )
      .foregroundStyle(Theme.Text.tertiary)
    }
  }

  private var personalToolsSummary: String {
    guard appState.enableTools, appState.personalTools.anyEnabled else {
      return String(localized: "Off")
    }
    return String(localized: "\(appState.personalTools.enabledCount) on")
  }

  private var automationsSummary: String {
    _ = appState.automationRegistryVersion
    guard appState.enableTools else { return String(localized: "Off") }
    if appState.focusFilter.hidePersonalTools { return String(localized: "Off (Focus)") }
    let count = AutomationRegistry.shared.enabledShortcuts.count
    return count == 0 ? String(localized: "Off") : String(localized: "\(count) allowed")
  }

  private var helpSection: some View {
    Section {
      ShareLink(
        item: DiagnosticsExport(),
        preview: SharePreview(String(localized: "Agello diagnostics"))
      ) {
        RowLabel(
          title: String(localized: "Share diagnostics"), symbol: "stethoscope",
          tint: Theme.Brand.silver)
      }
      .themedRow()
      .accessibilityIdentifier("settings.diagnostics")
    } header: {
      Text("Help").eyebrowStyle()
    } footer: {
      Text("Crash and performance reports from \(Platform.osName) and the app's log of the last hour, kept on this \(Platform.deviceName) until you share them. The log can include parts of your questions.")
        .foregroundStyle(Theme.Text.tertiary)
    }
  }

  /// Published from `docs/privacy.md` (GitHub Pages).
  static let privacyPolicyURL = URL(string: "https://powerbeef.github.io/Agello/privacy")!

  private var aboutSection: some View {
    Section {
      Link(destination: Self.privacyPolicyURL) {
        RowLabel(
          title: String(localized: "Privacy policy"), symbol: "hand.raised.fill",
          tint: Theme.Brand.silver)
      }
      .themedRow()
      .accessibilityIdentifier("settings.privacy")
      NavigationLink {
        LicensesView()
      } label: {
        RowLabel(
          title: String(localized: "Licenses"), symbol: "doc.text", tint: Theme.Brand.silver)
      }
      .themedRow()
      .accessibilityIdentifier("settings.licenses")
    } header: {
      Text("About").eyebrowStyle()
    } footer: {
      Text(Self.appVersion)
        .font(.caption2)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, minHeight: Theme.Size.target)
        .foregroundStyle(Theme.Text.tertiary)
        // Five taps within 3 s open the developer screen (the stats line, benchmark, what's loaded).
        .contentShape(.rect)
        .onTapGesture { handleVersionTap() }
        .accessibilityAction(named: String(localized: "Developer settings")) {
          Haptics.success()
          showDeveloper = true
        }
        .accessibilityIdentifier("settings.version")
    }
  }

  private func handleVersionTap() {
    let now = ContinuousClock.now
    if let start = versionTapWindowStart, now - start <= .seconds(3) {
      versionTapCount += 1
    } else {
      versionTapWindowStart = now
      versionTapCount = 1
    }
    if versionTapCount >= 5 {
      versionTapCount = 0
      versionTapWindowStart = nil
      Haptics.success()
      showDeveloper = true
    }
  }

  private static let appVersion: String = {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
    let build = info?["CFBundleVersion"] as? String ?? "1"
    return "Agello \(version) (\(build)) · Gemma 4 on-device via LiteRT-LM"
  }()
}
