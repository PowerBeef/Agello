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

/// Downloads that ask first on a cellular or metered network: Download now, or wait for Wi-Fi.
struct CellularDownloadConfirmation: ViewModifier {
  @Environment(AppState.self) private var appState
  @Binding var spec: ModelSpec?

  func body(content: Content) -> some View {
    content.confirmationDialog(
      spec.map { String(localized: "Download \($0.sizeDisplay) over cellular?") } ?? "",
      isPresented: Binding(get: { spec != nil }, set: { if !$0 { spec = nil } }),
      titleVisibility: .visible, presenting: spec
    ) { spec in
      Button("Download now") { appState.store.startDownload(spec, overCellular: true) }
      Button("Wait for Wi-Fi") { appState.store.startDownload(spec, overCellular: false) }
      Button("Cancel", role: .cancel) {}
    } message: { spec in
      Text("\(spec.displayName) is a large download. It may use a lot of your data plan.")
    }
  }
}

extension View {
  func cellularDownloadConfirmation(_ spec: Binding<ModelSpec?>) -> some View {
    modifier(CellularDownloadConfirmation(spec: spec))
  }
}

extension ModelStore {
  /// Start `spec`, or hand it to `confirm` when it should ask about cellular data first.
  func download(_ spec: ModelSpec, confirm: (ModelSpec) -> Void) {
    if needsCellularConsent(for: spec) { confirm(spec) } else { startDownload(spec) }
  }
}

private struct ModelCardView: View {
  @Environment(AppState.self) private var appState
  let spec: ModelSpec
  @State private var cellularSpec: ModelSpec?

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
    .cellularDownloadConfirmation($cellularSpec)
  }

  @ViewBuilder
  private var controls: some View {
    switch state {
    case .notDownloaded:
      Button {
        appState.store.download(spec) { cellularSpec = $0 }
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
          Text(
            appState.store.waitingForWiFi.contains(spec.id)
              ? String(localized: "Waiting for Wi-Fi…")
              : String(localized: "Downloading… \(Int(progress * 100))%"))
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
        Button("Resume") { appState.store.download(spec) { cellularSpec = $0 } }
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
        Button("Retry") { appState.store.download(spec) { cellularSpec = $0 } }
          .buttonStyle(QuietCapsuleButtonStyle(tint: tint))
      }
    }
  }
}
