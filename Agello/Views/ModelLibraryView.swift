import SwiftUI

struct ModelLibraryView: View {
  @Environment(AppState.self) private var appState
  @State private var deletingModelID: ModelID?
  @State private var deleteError: String?

  /// Hosts provide the NavigationStack (Settings pushes it; the chat's
  /// download banner presents it in a sheet).
  var body: some View {
    ScrollView {
      LazyVStack(spacing: Theme.Spacing.md) {
        if let deleteError {
          InlineBanner(
            symbol: "exclamationmark.triangle",
            message: deleteError,
            tint: Theme.Status.critical,
            identifier: "models.error"
          ) {
            Button("Dismiss") { self.deleteError = nil }
          }
        }
        ForEach(ModelCatalog.all) { spec in
          ModelCardView(
            spec: spec,
            deletingModelID: $deletingModelID,
            deleteError: $deleteError)
        }
        Text(
          "Models download once from Hugging Face and stay on this \(Platform.deviceName). Downloads continue if you leave the app."
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
      spec.map { Platform.meteredDownloadTitle(size: $0.sizeDisplay) } ?? "",
      isPresented: Binding(get: { spec != nil }, set: { if !$0 { spec = nil } }),
      titleVisibility: .visible, presenting: spec
    ) { spec in
      Button("Download now") { appState.store.startDownload(spec, overCellular: true) }
      Button(Platform.waitForUnmeteredNetwork) { appState.store.startDownload(spec, overCellular: false) }
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
  @Binding var deletingModelID: ModelID?
  @Binding var deleteError: String?
  @State private var cellularSpec: ModelSpec?
  @State private var confirmDelete = false

  private var state: ModelStore.DownloadState {
    appState.store.states[spec.id] ?? .notDownloaded
  }

  private var isVerifying: Bool {
    appState.store.isVerifying(spec.id)
  }

  private var isPausing: Bool {
    appState.store.isPausing(spec.id)
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
    .confirmationDialog(
      "Delete \(spec.displayName)?",
      isPresented: $confirmDelete,
      titleVisibility: .visible
    ) {
      Button("Delete (\(spec.sizeDisplay))", role: .destructive) {
        guard deletingModelID == nil else { return }
        deleteError = nil
        deletingModelID = spec.id
        Task {
          defer { deletingModelID = nil }
          if let error = await appState.deleteModel(spec) {
            deleteError = error
            Haptics.error()
          }
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This removes \(spec.sizeDisplay) from this \(Platform.deviceName). You can download it again later.")
    }
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
        if isVerifying {
          ProgressView()
            .accessibilityLabel("\(spec.displayName) verifying")
            .tint(tint)
        } else {
          ProgressView(value: progress)
            .accessibilityLabel("\(spec.displayName) download")
            .tint(tint)
        }
        HStack {
          Text(downloadingStatusText(progress: progress))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(Theme.Text.secondary)
            .contentTransition(.numericText())
          Spacer()
          Button("Pause") { appState.store.pauseDownload(spec) }
            .buttonStyle(QuietCapsuleButtonStyle())
            .disabled(isVerifying || isPausing)
          Button("Cancel", role: .cancel) { appState.store.cancelDownload(spec) }
            .buttonStyle(QuietCapsuleButtonStyle(tint: Theme.Text.secondary))
            .disabled(isVerifying)
        }
      }
    case .paused(let progress):
      HStack {
        StatusBadge(
          text: isPausing
            ? String(localized: "Pausing…")
            : String(localized: "Paused at \(Int(progress * 100))%"),
          tone: Theme.Status.guarded)
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
        Button(deletingModelID == spec.id ? "Deleting…" : "Delete", role: .destructive) {
          confirmDelete = true
        }
        .buttonStyle(QuietCapsuleButtonStyle(tint: Theme.Status.critical))
        .disabled(deletingModelID != nil)
        .accessibilityIdentifier("models.delete.\(spec.id.rawValue)")
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

  private func downloadingStatusText(progress: Double) -> String {
    if isVerifying {
      return String(localized: "Verifying…")
    }
    if appState.store.waitingForWiFi.contains(spec.id) {
      return Platform.waitingForUnmeteredNetwork
    }
    return String(localized: "Downloading… \(Int(progress * 100))%")
  }
}
