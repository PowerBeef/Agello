import SwiftUI

struct ModelLibraryView: View {
  @Environment(AppState.self) private var appState

  /// Hosts provide the NavigationStack (Settings pushes it; the chat's
  /// download banner presents it in a sheet).
  var body: some View {
    ScrollView {
      LazyVStack(spacing: DS.spaceLG) {
        ForEach(ModelCatalog.all) { spec in
          ModelCardView(spec: spec)
        }
        Text(
          "Models download once from Hugging Face and stay on this iPhone. Downloads continue if you leave the app."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
      }
      .padding()
    }
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

  var body: some View {
    VStack(alignment: .leading, spacing: DS.spaceMD) {
      HStack(spacing: 12) {
        Image(systemName: "sparkles")
          .font(.callout)
          .frame(width: DS.iconLG, height: DS.iconLG)
          .glassEffect(.regular.tint(.accentColor), in: .circle)
        VStack(alignment: .leading, spacing: 2) {
          Text(spec.displayName).font(.headline)
          Text(spec.tagline).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
      }
      Text(spec.sizeDisplay).font(.caption).foregroundStyle(.secondary)

      controls
    }
    .padding()
    .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusCard))
  }

  @ViewBuilder
  private var controls: some View {
    switch state {
    case .notDownloaded:
      Button("Download") { appState.store.startDownload(spec) }
        .buttonStyle(.glassProminent)
        .controlSize(.regular)
        .accessibilityIdentifier("models.download.\(spec.id.rawValue)")
    case .downloading(let progress):
      VStack(alignment: .leading, spacing: 8) {
        ProgressView(value: progress) {
          Text("Downloading… \(Int(progress * 100))%")
            .font(.caption)
        }
        HStack {
          Button("Pause") { appState.store.pauseDownload(spec) }
          Button("Cancel", role: .cancel) { appState.store.cancelDownload(spec) }
        }
        .buttonStyle(.glass)
        .controlSize(.small)
      }
    case .paused(let progress):
      HStack {
        Button("Resume") { appState.store.startDownload(spec) }
          .buttonStyle(.glassProminent)
          .controlSize(.small)
        Button("Cancel", role: .cancel) { appState.store.cancelDownload(spec) }
          .buttonStyle(.glass)
          .controlSize(.small)
        Spacer()
        Text("\(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
      }
    case .ready:
      HStack {
        Label("Ready", systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.green)
          .accessibilityIdentifier("models.ready.\(spec.id.rawValue)")
        Spacer()
        Button("Delete", role: .destructive) { Task { await appState.deleteModel(spec) } }
          .buttonStyle(.glass)
          .controlSize(.small)
      }
    case .failed(let message):
      VStack(alignment: .leading, spacing: 8) {
        Text(message).font(.caption).foregroundStyle(.red)
        Button("Retry") { appState.store.startDownload(spec) }
          .buttonStyle(.glass)
          .controlSize(.small)
      }
    }
  }
}
