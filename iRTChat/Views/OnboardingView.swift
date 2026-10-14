import SwiftUI

/// First launch: what iRTChat is, and the one-time model download (which
/// continues in the background). "Not now" leaves it for the chat banner.
struct OnboardingView: View {
  @Environment(AppState.self) private var appState
  var onFinish: () -> Void

  private var spec: ModelSpec { appState.store.activeSpec }
  private var state: ModelStore.DownloadState {
    appState.store.states[spec.id] ?? .notDownloaded
  }

  /// Shown until the user finishes or skips it, and only when there's
  /// something to download (existing installs skip it).
  nonisolated static func shouldShow(done: Bool, isMock: Bool, downloaded: Bool) -> Bool {
    !done && !isMock && !downloaded
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxxl) {
          header
          features
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.top, Theme.Spacing.xxxl + Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.xxl)
      }
      footer
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.md)
    }
    .ambientBackdrop(Theme.Brand.glacier, intensity: .loud)
    .onAppear { appState.store.refreshStates() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      Image(systemName: "sparkles")
        .font(.system(.title, weight: .semibold))
        .foregroundStyle(Theme.Text.primary)
        .frame(width: Theme.Size.hero, height: Theme.Size.hero)
        .background {
          LitTintBackground(
            shape: RoundedRectangle(cornerRadius: Theme.Radius.group + 2, style: .continuous),
            tint: Theme.Brand.glacier)
        }
        .accessibilityHidden(true)
        .padding(.bottom, Theme.Spacing.xs)
      Text("iRTChat")
        .font(.wordmark)
        .foregroundStyle(Theme.Brand.glacier)
      Text("Your own AI, entirely on this iPhone.")
        .font(.system(.largeTitle, weight: .bold))
        .tracking(-0.6)
        .foregroundStyle(Theme.Text.primary)
        .fixedSize(horizontal: false, vertical: true)
      Text("Gemma 4 runs on the iPhone's GPU. No account, no cloud, no data leaving your phone.")
        .font(.body)
        .foregroundStyle(Theme.Text.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var features: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
      feature(
        "lock.shield.fill", Theme.Brand.glacier, "Private by design",
        "Your chats, photos and voice never leave this iPhone.")
      feature(
        "airplane", Theme.Brand.teal, "Works offline",
        "Once downloaded, the model needs no connection or account.")
      feature(
        "eye.fill", Theme.Brand.gold, "Sees and listens",
        "Ask about photos, read documents, or just talk.")
      feature(
        "lightbulb.fill", Theme.Brand.lavender, "Thinks it through",
        "Turn on Think for step-by-step reasoning on harder questions.")
    }
  }

  private func feature(
    _ symbol: String, _ tint: Color, _ title: LocalizedStringKey, _ detail: LocalizedStringKey
  ) -> some View {
    HStack(alignment: .top, spacing: Theme.Spacing.lg) {
      TintTile(symbol: symbol, tint: tint, size: 36)
      VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
        Text(title)
          .font(.headline)
          .foregroundStyle(Theme.Text.primary)
        Text(detail)
          .font(.subheadline)
          .foregroundStyle(Theme.Text.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private var footer: some View {
    VStack(spacing: Theme.Spacing.md) {
      switch state {
      case .notDownloaded:
        note("\(spec.displayName) · \(spec.sizeDisplay) one-time download. Wi-Fi recommended.")
        primary("Download \(spec.displayName)", id: "onboarding.download") {
          appState.store.startDownload(spec)
        }
      case .downloading(let progress):
        ProgressView(value: progress) {
          HStack {
            Text("Downloading \(spec.displayName)…")
            Spacer()
            Text("\(Int(progress * 100))%")
              .monospacedDigit()
              .contentTransition(.numericText())
          }
          .font(.subheadline)
          .foregroundStyle(Theme.Text.secondary)
        }
        .tint(Theme.Brand.glacier)
        .accessibilityIdentifier("onboarding.progress")
        note("You can leave the app: the download continues in the background.")
        Button("Pause") { appState.store.pauseDownload(spec) }
          .buttonStyle(QuietCapsuleButtonStyle())
      case .paused(let progress):
        note("Paused at \(Int(progress * 100))%.")
        primary("Resume download", id: "onboarding.download") {
          appState.store.startDownload(spec)
        }
      case .failed(let message):
        note(message)
          .foregroundStyle(Theme.Status.critical)
        primary("Try again", id: "onboarding.download") { appState.store.startDownload(spec) }
      case .ready:
        note("\(spec.displayName) is ready.")
        primary("Start chatting", id: "onboarding.start", action: onFinish)
      }
      if state != .ready {
        Button("Not now", action: onFinish)
          .font(.system(.subheadline, weight: .medium))
          .foregroundStyle(Theme.Text.secondary)
          .frame(minHeight: Theme.Size.target)
          .accessibilityIdentifier("onboarding.skip")
      }
    }
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(.footnote)
      .foregroundStyle(Theme.Text.tertiary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
  }

  private func primary(_ title: String, id: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
    }
    .buttonStyle(LitButtonStyle(tint: Theme.Brand.glacier))
    .accessibilityIdentifier(id)
  }
}
