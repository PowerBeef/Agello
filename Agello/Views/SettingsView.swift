import SwiftUI

/// Settings: the model's status on top, then what most people change
/// (personalization, memory, web search, Spotlight, models, tools), with the
/// engine's developer controls one level down in Advanced. Everything
/// applies live (via `onChange`).
struct SettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @AppStorage(SpotlightIndex.enabledKey) private var spotlightEnabled = true

  private var bindable: Bindable<AppState> { Bindable(appState) }

  var body: some View {
    NavigationStack {
      Form {
        statusSection
        youSection
        modelSection
        advancedSection
        aboutSection
      }
      .themedList(Theme.Brand.glacier)
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.large)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("settings.done")
        }
      }
      // Advanced edits options too: it is pushed on this stack, so these
      // stay alive while it shows.
      .onChange(of: appState.options) {
        appState.scheduleApplyOptions()
      }
      .onChange(of: appState.enableTools) {
        appState.scheduleApplyOptions()
      }
    }
  }

  // MARK: - Status

  private var statusSection: some View {
    Section {
      HStack(spacing: Theme.Spacing.md) {
        TintTile(symbol: "sparkles", tint: Theme.Brand.glacier, size: 44)
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
          Text(activeSpec.displayName)
            .font(.headline)
            .foregroundStyle(Theme.Text.primary)
          Text(statusLine)
            .font(.caption)
            .foregroundStyle(Theme.Text.tertiary)
            .accessibilityIdentifier("settings.status")
        }
        Spacer(minLength: Theme.Spacing.sm)
        StatusBadge(text: status.word, tone: status.tone)
      }
      .padding(.vertical, Theme.Spacing.xs)
      .themedRow()
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
      guard let resolved = appState.resolved else { return String(localized: "On this iPhone") }
      return String(
        localized: "On this iPhone · \(resolved.backendLabel) · \(resolved.maxNumTokens / 1024)K context")
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
      .themedRow()
      .onChange(of: spotlightEnabled) {
        if let context = appState.modelContext { SpotlightIndex.refresh(in: context, full: true) }
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
    let customized = !p.name.isEmpty || !p.aboutYou.isEmpty || !p.instructions.isEmpty
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
      .themedRow()
    } header: {
      Text("Model").eyebrowStyle()
    } footer: {
      Text("Tools let the assistant check the date and calculate, fully on this iPhone.")
        .foregroundStyle(Theme.Text.tertiary)
    }
  }

  private var advancedSection: some View {
    Section {
      NavigationLink {
        AdvancedSettingsView()
      } label: {
        RowLabel(
          title: String(localized: "Advanced"), symbol: "slider.horizontal.3",
          tint: Theme.Brand.silver)
      }
      .themedRow()
      .accessibilityIdentifier("settings.advanced")
    } footer: {
      Text("Performance, reasoning, sampling, voice and vision, the system prompt, and the benchmark.")
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
      Text(appVersion)
        .font(.caption2)
        .frame(maxWidth: .infinity)
        .foregroundStyle(Theme.Text.tertiary)
    }
  }

  private var appVersion: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
    let build = info?["CFBundleVersion"] as? String ?? "1"
    return "Agello \(version) (\(build)) · Gemma 4 on-device via LiteRT-LM"
  }
}
