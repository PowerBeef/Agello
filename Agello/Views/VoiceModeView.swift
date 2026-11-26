import SwiftUI

/// Full-screen voice conversation in the voice mode's gold: an orb that
/// reacts to the voices, live captions, the camera, mute, and end.
struct VoiceModeView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(ShellModel.self) private var shell: ShellModel?
  let session: VoiceSession

  private let tint = Theme.Mode.voice.tint

  init(session: VoiceSession) {
    self.session = session
  }

  var body: some View {
    let isCompact = verticalSizeClass == .compact
    VStack(spacing: Theme.Spacing.md) {
      GeometryReader { geometry in
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: isCompact ? Theme.Spacing.md : Theme.Spacing.xl) {
              if session.cameraOn, let captureSession = session.camera.session {
                CameraPreview(session: captureSession, device: session.camera.captureDevice)
                  .clipShape(.rect(cornerRadius: Theme.Radius.composer, style: .continuous))
                  .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous)
                      .stroke(Theme.Surface.stroke, lineWidth: Theme.Stroke.hairline)
                  }
                  .frame(
                    minHeight: isCompact ? 120 : 160,
                    maxHeight: isCompact ? 160 : (session.pendingToolConfirmation != nil ? 180 : 320))
                  .padding(.horizontal, Theme.Spacing.lg)
                  .accessibilityLabel("Camera preview")
                  .accessibilityIdentifier("voice.camera")
              } else {
                Spacer(minLength: 0)
              }
              VoiceOrbView(session: session, isCompact: isCompact, tint: tint)
              Text(session.state.label)
                .font(.system(.headline, weight: .semibold))
                .foregroundStyle(Theme.Text.secondary)
                .contentTransition(.opacity)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.lg)
                .accessibilityIdentifier("voice.state")
              captions(isCompact: isCompact)
              if let confirmation = session.pendingToolConfirmation {
                ToolConfirmationCard(
                  request: confirmation,
                  onApprove: { session.resolveToolConfirmation(id: confirmation.id, approved: true) },
                  onApproveSteps: { selected in
                    session.resolveToolConfirmation(id: confirmation.id, approvedSteps: selected)
                  },
                  onDeny: { session.resolveToolConfirmation(id: confirmation.id, approved: false) }
                )
                .id(confirmation.id)
                .layoutPriority(1)
                .padding(.horizontal, Theme.Spacing.lg)
              } else if !session.latestActionCards.isEmpty {
                ActionCardStack(cards: session.latestActionCards, isCompact: true)
                  .padding(.horizontal, Theme.Spacing.lg)
                  .accessibilityIdentifier("voice.actionCards")
              }
              Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            .padding(.top, Theme.Spacing.sm)
            .padding(.bottom, Theme.Spacing.md)
          }
          .scrollBounceBehavior(.basedOnSize)
          .onChange(of: session.pendingToolConfirmation?.id) { _, newID in
            if let newID, let confirmation = session.pendingToolConfirmation {
              withAppAnimation(Theme.Motion.easeOut) {
                proxy.scrollTo(newID, anchor: .bottom)
              }
              Haptics.announce(confirmation.summary)
            }
          }
        }
      }
      if let cameraError = session.cameraError {
        Text(cameraError)
          .font(.footnote)
          .foregroundStyle(Theme.Status.guarded)
          .multilineTextAlignment(.center)
          .padding(.horizontal, Theme.Spacing.lg)
      }
      controls
        .layoutPriority(1)
    }
    .padding(.vertical, Theme.Spacing.md)
    .frame(maxWidth: .infinity)
    .ambientBackdrop(tint, intensity: .loud)
    .task { await session.start() }
    .onDisappear {
      session.end()
      if let shell {
        Task { @MainActor in shell.handleModalDismissed() }
      }
    }
    .onChange(of: shell?.dismissCoversToken) { old, new in
      if old != nil, old != new { dismiss() }
    }
    // Only failures and explicit tool confirmations are announced: speech would reach the mic.
    .onChange(of: session.state) { _, state in
      if case .failed(let message) = state { Haptics.announce(message) }
    }
    .preferredColorScheme(.dark)
  }

  /// The words being said, newest at the bottom: a long answer scrolls rather than stopping at
  /// six lines of its start.
  @ViewBuilder
  private func captions(isCompact: Bool) -> some View {
    if !session.heard.isEmpty || !session.answer.isEmpty {
      ScrollView {
        captionText
      }
      .defaultScrollAnchor(.bottom)
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxHeight: session.pendingToolConfirmation != nil ? 100 : (isCompact ? 120 : 240))
    }
  }

  private var captionText: some View {
    VStack(spacing: Theme.Spacing.snug) {
      if !session.heard.isEmpty {
        Text(session.heard)
          .font(.callout)
          .foregroundStyle(Theme.Text.tertiary)
          .accessibilityIdentifier("voice.heard")
      }
      if !session.answer.isEmpty {
        Text(session.answer)
          .font(.system(.title3, weight: .medium))
          .foregroundStyle(Theme.Text.primary)
          .accessibilityIdentifier("voice.answer")
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity)
    .padding(.horizontal, Theme.Spacing.xxl)
    .appAnimation(Theme.Motion.easeOut, value: session.answer)
  }

  private var controls: some View {
    HStack(spacing: Theme.Spacing.xxl) {
      Button {
        Task { await session.toggleCamera() }
      } label: {
        Image(systemName: session.cameraOn ? "camera.fill" : "camera")
          .font(.title3)
      }
      .buttonStyle(QuietCircleButtonStyle(size: 56))
      .disabled(!CameraFeed.isAvailable)
      .accessibilityLabel("Camera")
      .accessibilityValue(session.cameraOn ? "On" : "Off")
      .accessibilityAddTraits(.isToggle)
      .accessibilityIdentifier("voice.toggleCamera")
      Button {
        session.toggleMute()
      } label: {
        Image(systemName: session.muted ? "mic.slash.fill" : "mic.fill")
          .font(.title3)
          .contentTransition(.symbolEffect(.replace))
      }
      .buttonStyle(QuietCircleButtonStyle(size: 56, tint: session.muted ? tint : Theme.Text.primary))
      .accessibilityLabel(session.muted ? "Unmute" : "Mute")
      .accessibilityIdentifier("voice.mute")
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(LitCircleButtonStyle(tint: Theme.Status.critical, size: 56))
      .accessibilityLabel("End voice mode")
      .accessibilityIdentifier("voice.end")
    }
  }
}

/// Isolated orb view so ~25 Hz `session.level` updates never re-diff the rest of ``VoiceModeView``.
/// Uses a zero-offscreen-pass `RadialGradient` halo instead of an animated Gaussian blur and runs
/// `phaseAnimator` strictly while `.thinking` or `.speaking` (0 frames while idle `.listening`).
private struct VoiceOrbView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let session: VoiceSession
  let isCompact: Bool
  let tint: Color

  var body: some View {
    let active = session.state == .hearing
    let hasConfirmation = session.pendingToolConfirmation != nil
    let size: CGFloat =
      if isCompact {
        hasConfirmation ? 64 : (session.cameraOn ? 72 : 112)
      } else {
        hasConfirmation ? 80 : (session.cameraOn ? 96 : 200)
      }
    let scale = 1 + (active ? session.level * 0.35 : 0)
    let shouldPulse = !reduceMotion && (session.state == .thinking || session.state == .speaking)
    let core = ZStack {
      // Halo: zero-offscreen-pass soft radial bloom replacing a 44 pt Gaussian `.blur`.
      Circle()
        .fill(
          RadialGradient(
            stops: [
              .init(color: tint.opacity(0.32), location: 0.0),
              .init(color: tint.opacity(0.22), location: 0.48),
              .init(color: tint.opacity(0.08), location: 0.72),
              .init(color: .clear, location: 1.0),
            ],
            center: .center, startRadius: 0, endRadius: size * 0.92))
        .frame(width: size * 1.84, height: size * 1.84)
        .allowsHitTesting(false)
      // Core: warm light at the center fading to deep gold.
      Circle()
        .fill(
          RadialGradient(
            colors: [Theme.Text.primary, tint, tint.mix(with: .black, by: 0.55, in: .perceptual)],
            center: UnitPoint(x: 0.42, y: 0.38), startRadius: 2, endRadius: size * 0.62))
        .frame(width: size, height: size)
      Circle()
        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
        .frame(width: size, height: size)
    }
    .frame(width: size, height: size)
    .scaleEffect(reduceMotion ? 1 : scale)
    .opacity(session.state == .thinking ? 0.75 : 1)
    .appAnimation(Theme.Motion.stateChange, value: session.level)
    .appAnimation(Theme.Motion.slide, value: session.cameraOn)
    .appAnimation(Theme.Motion.slide, value: hasConfirmation)

    Group {
      if shouldPulse {
        core.phaseAnimator([1.0, 1.06]) { view, pulse in
          view.scaleEffect(pulse)
        } animation: { _ in .easeInOut(duration: 0.9) }
      } else {
        core
      }
    }
    .contentShape(Circle())
    .onTapGesture { session.interrupt() }
    .accessibilityLabel("Voice conversation")
    .accessibilityValue(session.state.label)
    .accessibilityHint("Double-tap to interrupt the answer")
    .accessibilityAddTraits(.isButton)
  }
}
