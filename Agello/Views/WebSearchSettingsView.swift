import SwiftUI

/// Web search: on/off, automatic mode, provider.
struct WebSearchSettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.scenePhase) private var scenePhase
  @State private var searxngURLDraft = ""
  @State private var loadedDraft = false

  private var searxngProblem: String? {
    guard appState.webSettings.provider == .searxng else { return nil }
    let address = loadedDraft ? searxngURLDraft : appState.webSettings.searxngURL
    return WebSearchSettings.searxngProblem(address)
  }

  var body: some View {
    @Bindable var appState = appState
    Form {
      Section {
        Toggle("Allow web search", isOn: $appState.webSettings.allowed)
          .tint(Theme.Mode.search.tint)
          .accessibilityIdentifier("web.allowed")
        Toggle("Search automatically", isOn: $appState.webSettings.automatic)
          .tint(Theme.Mode.search.tint)
          .disabled(!appState.webSettings.allowed)
          .accessibilityIdentifier("web.automatic")
      } footer: {
        Text(
          "Use the Search button in the composer to search for one message. With automatic search, the model searches on its own when a question needs current information. Only search queries and the pages read are sent; your conversation stays on this \(Platform.deviceName)."
        )
        .foregroundStyle(Theme.Text.tertiary)
      }
      .themedRow()

      Section {
        Picker("Search with", selection: $appState.webSettings.provider) {
          ForEach(SearchProvider.allCases, id: \.self) { provider in
            Text(provider.displayName).tag(provider)
          }
        }
        .accessibilityIdentifier("web.provider")
        if appState.webSettings.provider == .searxng {
          TextField("https://searx.example.org", text: $searxngURLDraft)
            .accessibilityLabel("SearXNG server URL")
            .urlField()
            .submitLabel(.done)
            .onSubmit(commitSearxngURL)
            .transition(.opacity)
        }
      } header: {
        Text("Provider").eyebrowStyle()
      } footer: {
        Text(providerFooter)
          .foregroundStyle(searxngProblem == nil ? Theme.Text.tertiary : Theme.Status.critical)
      }
      .themedRow()
      .disabled(!appState.webSettings.allowed)
    }
    .appAnimation(Theme.Motion.panel, value: appState.webSettings.provider)
    .scrollDismissesKeyboard(.interactively)
    .themedList(Theme.Mode.search.tint)
    .navigationTitle("Web search")
    .inlineTitleDisplay()
    .onAppear {
      guard !loadedDraft else { return }
      searxngURLDraft = appState.webSettings.searxngURL
      loadedDraft = true
    }
    .onChange(of: appState.webSettings.allowed) { _, _ in Haptics.selection() }
    .onChange(of: appState.webSettings.automatic) { _, _ in Haptics.selection() }
    .onChange(of: appState.webSettings.searxngURL) { _, updated in
      if loadedDraft, updated != searxngURLDraft { searxngURLDraft = updated }
    }
    .onChange(of: appState.webSettings.provider) { _, _ in
      Haptics.selection()
      commitSearxngURL()
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { commitSearxngURL() }
    }
    .onDisappear(perform: commitSearxngURL)
  }

  private func commitSearxngURL() {
    guard loadedDraft, searxngURLDraft != appState.webSettings.searxngURL else { return }
    appState.webSettings.searxngURL = searxngURLDraft
  }

  private var providerFooter: String {
    switch appState.webSettings.provider {
    case .wikipedia:
      return String(localized: "Searches Wikipedia.")
    case .searxng:
      return searxngProblem
        ?? String(localized: "Your SearXNG instance must allow the JSON format. Wikipedia is the fallback.")
    }
  }
}
