import SwiftUI

/// Web search: on/off, automatic mode, provider.
struct WebSearchSettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.scenePhase) private var scenePhase
  @State private var searxngURLDraft = ""
  @State private var loadedDraft = false

  var body: some View {
    @Bindable var appState = appState
    Form {
      Section {
        Toggle("Allow web search", isOn: $appState.webSettings.allowed)
          .accessibilityIdentifier("web.allowed")
        Toggle("Search automatically", isOn: $appState.webSettings.automatic)
          .disabled(!appState.webSettings.allowed)
          .accessibilityIdentifier("web.automatic")
      } footer: {
        Text(
          "Use the Search button in the composer to search for one message. With automatic search, the model searches on its own when a question needs current information. Only search queries and the pages read are sent; your conversation stays on this \(Platform.deviceName)."
        )
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
        }
      } header: {
        Text("Provider")
      } footer: {
        Text(providerFooter)
      }
      .themedRow()
      .disabled(!appState.webSettings.allowed)
    }
    .scrollDismissesKeyboard(.interactively)
    .themedList(Theme.Brand.teal)
    .navigationTitle("Web search")
    .onAppear {
      guard !loadedDraft else { return }
      searxngURLDraft = appState.webSettings.searxngURL
      loadedDraft = true
    }
    .onChange(of: appState.webSettings.searxngURL) { _, updated in
      if loadedDraft, updated != searxngURLDraft { searxngURLDraft = updated }
    }
    .onChange(of: appState.webSettings.provider) { _, _ in
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
      let address = loadedDraft ? searxngURLDraft : appState.webSettings.searxngURL
      return WebSearchSettings.searxngProblem(address)
        ?? String(localized: "Your SearXNG instance must allow the JSON format. Wikipedia is the fallback.")
    }
  }
}
