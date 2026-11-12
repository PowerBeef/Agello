import SwiftUI

/// Web search: on/off, automatic mode, provider.
struct WebSearchSettingsView: View {
  @Environment(AppState.self) private var appState

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
          TextField("https://searx.example.org", text: $appState.webSettings.searxngURL)
            .accessibilityLabel("SearXNG server URL")
            .urlField()
        }
      } header: {
        Text("Provider")
      } footer: {
        Text(providerFooter)
      }
      .themedRow()
      .disabled(!appState.webSettings.allowed)
    }
    .themedList(Theme.Brand.teal)
    .navigationTitle("Web search")
  }

  private var providerFooter: String {
    switch appState.webSettings.provider {
    case .duckDuckGo:
      return String(localized: "Results by DuckDuckGo, with Wikipedia as a fallback.")
    case .wikipedia:
      return String(localized: "Searches Wikipedia only (DuckDuckGo if it finds nothing).")
    case .searxng:
      return String(localized: "Your SearXNG instance must allow the JSON format. DuckDuckGo and Wikipedia are fallbacks.")
    }
  }
}
