import SwiftUI

struct ModelLibraryView: View {
  @Environment(AppState.self) private var appState

  /// Hosts provide the NavigationStack (Settings pushes it; the chat's
  /// download banner presents it in a sheet).
  var body: some View {
    ScrollView {
      LazyVStack(spacing: Theme.Spacing.md) {
        ForEach(ModelCatalog.all) { spec in
          ModelCardView(spec: spec)
        }
        Text(
          "Models download once from Hugging Face and stay on this iPhone. Downloads continue if you leave the app."
        )
        .font(.footnote)
        .foregroundStyle(Theme.Text.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.top, Theme.Spacing.xs)
      }
      .padding(.horizontal, Theme.Spacing.lg)
      .padding(.vertical, Theme.Spacing.md)
    }
    .ambientBackdrop(Theme.Brand.glacier, intensity: .whisper)
    .navigationTitle("Models")
    .onAppear { appState.store.refreshStates() }
  }
}

private struct ModelCardView: View {
  @Environment(AppState.self) private var appState
  let spec: ModelSpec

  private var state: ModelStore.DownloadState {
    appState.store.states[spec.id] ?? .notDownloaded
  }

  /// The chat model sparkles; the search model finds passages.
  private var symbol: String { spec.id == ModelCatalog.embeddingGemma.id ? "text.magnifyingglass" : "sparkles" }
  private var tint: Color { spec.id == ModelCatalog.embeddingGemma.id ? Theme.Brand.teal : Theme.Brand.glacier }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      HStack(alignment: .top, spacing: Theme.Spacing.md) {
        TintTile(symbol: symbol, tint: tint, size: 40)
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
          Text(spec.displayName)
            .font(.headline)
            .foregroundStyle(Theme.Text.primary)
          Text(spec.tagline)
            .font(.footnote)
            .foregroundStyle(Theme.Text.secondary)
          Text(spec.sizeDisplay)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(Theme.Text.tertiary)
        }
        Spacer(minLength: 0)
      }
      controls
    }
    .padding(Theme.Spacing.lg)
    .surfaceCard(radius: Theme.Radius.group)
  }

  @ViewBuilder
  private var controls: some View {
    switch state {
    case .notDownloaded:
      Button {
        appState.store.startDownload(spec)
      } label: {
        Label("Download", systemImage: "arrow.down")
      }
      .buttonStyle(LitButtonStyle(tint: tint))
      .accessibilityIdentifier("models.download.\(spec.id.rawValue)")
    case .downloading(let progress):
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        ProgressView(value: progress)
          .tint(tint)
        HStack {
          Text("Downloading… \(Int(progress * 100))%")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(Theme.Text.secondary)
            .contentTransition(.numericText())
          Spacer()
          Button("Pause") { appState.store.pauseDownload(spec) }
            .buttonStyle(QuietCapsuleButtonStyle())
          Button("Cancel", role: .cancel) { appState.store.cancelDownload(spec) }
            .buttonStyle(QuietCapsuleButtonStyle(tint: Theme.Text.secondary))
        }
      }
    case .paused(let progress):
      HStack {
        StatusBadge(text: String(localized: "Paused at \(Int(progress * 100))%"), tone: Theme.Status.guarded)
        Spacer()
        Button("Resume") { appState.store.startDownload(spec) }
          .buttonStyle(QuietCapsuleButtonStyle(tint: tint))
        Button("Cancel", role: .cancel) { appState.store.cancelDownload(spec) }
          .buttonStyle(QuietCapsuleButtonStyle(tint: Theme.Text.secondary))
      }
    case .ready:
      HStack {
        StatusBadge(text: String(localized: "Ready"), tone: Theme.Status.healthy)
          .accessibilityIdentifier("models.ready.\(spec.id.rawValue)")
        Spacer()
        Button("Delete", role: .destructive) { Task { await appState.deleteModel(spec) } }
          .buttonStyle(QuietCapsuleButtonStyle(tint: Theme.Status.critical))
      }
    case .failed(let message):
      VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
        Text(message)
          .font(.footnote)
          .foregroundStyle(Theme.Status.critical)
        Button("Retry") { appState.store.startDownload(spec) }
          .buttonStyle(QuietCapsuleButtonStyle(tint: tint))
      }
    }
  }
}
