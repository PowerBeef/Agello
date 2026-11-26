import AVFoundation
import SwiftUI

/// Full-screen voice conversation in the voice mode's gold: an orb that
/// reacts to the voices, live captions, the camera, mute, and end.
struct VoiceModeView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(ShellModel.self) private var shell: ShellModel?
  let session: VoiceSession

  private let tint = Theme.Mode.voice.tint

  init(session: VoiceSession) {
    self.session = session
  }

  private var panelTransition: AnyTransition {
    reduceMotion
      ? .opacity
      : .asymmetric(
        insertion: .scale(scale: 0.96).combined(with: .opacity),
        removal: .opacity)
  }

  private var isFailed: Bool {
    if case .failed = session.state { return true }
    return false
  }

  private var hasSecondaryContent: Bool {
    (session.cameraOn && session.camera.session != nil)
      || !session.heard.isEmpty
      || !session.answer.isEmpty
      || session.pendingToolConfirmation != nil
      || !session.latestActionCards.isEmpty
  }

  var body: some View {
    let isCompact = verticalSizeClass == .compact
    Group {
      if isCompact {
        compactLayout
      } else {
        portraitLayout
      }
    }
    .padding(.vertical, Theme.Spacing.md)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .ambientBackdrop(tint, intensity: .loud)
    .environment(
      \.onActionCardSheetPresented,
      ActionCardSheetHandler(id: ObjectIdentifier(session)) {
        session.setExternalSheetPresented($0)
      })
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

  // MARK: - Portrait & Compact Landscape Layouts

  private var portraitLayout: some View {
    VStack(spacing: Theme.Spacing.md) {
      GeometryReader { geometry in
        ScrollViewReader { proxy in
          ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
              if session.cameraOn, let captureSession = session.camera.session {
                cameraPreview(captureSession: captureSession, isCompact: false)
              } else {
                Spacer(minLength: 0)
              }
              VoiceOrbView(session: session, isCompact: false, tint: tint)
              stateSection
              captions(isCompact: false)
              interactiveAttachment
              Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            .padding(.top, Theme.Spacing.sm)
            .padding(.bottom, Theme.Spacing.md)
            .appAnimation(Theme.Motion.panel, value: session.cameraOn)
            .appAnimation(Theme.Motion.panel, value: session.pendingToolConfirmation?.id)
            .appAnimation(Theme.Motion.panel, value: session.latestActionCards.map(\.id))
          }
          .scrollBounceBehavior(.basedOnSize)
          .onChange(of: session.pendingToolConfirmation?.id) { _, newID in
            scrollToConfirmation(id: newID, proxy: proxy)
          }
        }
      }
      cameraErrorNotice
      controls
        .layoutPriority(1)
    }
    .appAnimation(Theme.Motion.stateChange, value: session.cameraError, kind: .dissolve)
  }

  private var compactLayout: some View {
    HStack(spacing: Theme.Spacing.lg) {
      VStack(spacing: Theme.Spacing.md) {
        Spacer(minLength: 0)
        VoiceOrbView(session: session, isCompact: true, tint: tint)
        stateSection
        cameraErrorNotice
        Spacer(minLength: 0)
        controls
      }
      .frame(maxWidth: hasSecondaryContent ? 260 : .infinity, maxHeight: .infinity)
      .padding(.leading, Theme.Spacing.lg)
      .padding(.trailing, hasSecondaryContent ? 0 : Theme.Spacing.lg)
      .appAnimation(Theme.Motion.stateChange, value: session.cameraError, kind: .dissolve)

      if hasSecondaryContent {
        GeometryReader { geometry in
          ScrollViewReader { proxy in
            ScrollView {
              VStack(spacing: Theme.Spacing.md) {
                if session.cameraOn, let captureSession = session.camera.session {
                  cameraPreview(captureSession: captureSession, isCompact: true)
                }
                captions(isCompact: true)
                interactiveAttachment
              }
              .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
              .padding(.vertical, Theme.Spacing.xs)
              .appAnimation(Theme.Motion.panel, value: session.cameraOn)
              .appAnimation(Theme.Motion.panel, value: session.pendingToolConfirmation?.id)
              .appAnimation(Theme.Motion.panel, value: session.latestActionCards.map(\.id))
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: session.pendingToolConfirmation?.id) { _, newID in
              scrollToConfirmation(id: newID, proxy: proxy)
            }
          }
        }
        .padding(.trailing, Theme.Spacing.lg)
        .transition(panelTransition)
      }
    }
    .appAnimation(Theme.Motion.panel, value: hasSecondaryContent)
  }

  // MARK: - Subviews

  private func cameraPreview(captureSession: AVCaptureSession, isCompact: Bool) -> some View {
    CameraPreview(session: captureSession, device: session.camera.captureDevice)
      .clipShape(.rect(cornerRadius: Theme.Radius.composer, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous)
          .stroke(Theme.Surface.stroke, lineWidth: Theme.Stroke.hairline)
      }
      .frame(
        minHeight: isCompact ? 112 : 160,
        maxHeight: isCompact ? 156 : (session.pendingToolConfirmation != nil ? 180 : 320))
      .padding(.horizontal, isCompact ? 0 : Theme.Spacing.lg)
      .transition(panelTransition)
      .accessibilityLabel("Camera preview")
      .accessibilityIdentifier("voice.camera")
  }

  private var stateSection: some View {
    VStack(spacing: Theme.Spacing.sm) {
      Text(session.state.label)
        .font(.system(.headline, weight: .semibold))
        .foregroundStyle(isFailed ? Theme.Status.critical : Theme.Text.secondary)
        .contentTransition(.opacity)
        .multilineTextAlignment(.center)
        .padding(.horizontal, Theme.Spacing.lg)
        .appAnimation(Theme.Motion.stateChange, value: session.state, kind: .dissolve)
        .accessibilityIdentifier("voice.state")
      if isFailed {
        Button("Retry") {
          Haptics.selection()
          Task { await session.retry() }
        }
        .buttonStyle(QuietCapsuleButtonStyle(tint: tint))
        .transition(panelTransition)
        .accessibilityIdentifier("voice.retry")
      }
    }
    .appAnimation(Theme.Motion.stateChange, value: isFailed, kind: .dissolve)
  }

  @ViewBuilder
  private var interactiveAttachment: some View {
    if let confirmation = session.pendingToolConfirmation {
      ToolConfirmationCard(
        request: confirmation,
        isCompact: true,
        onApprove: { session.resolveToolConfirmation(id: confirmation.id, approved: true) },
        onApproveSteps: { selected in
          session.resolveToolConfirmation(id: confirmation.id, approvedSteps: selected)
        },
        onDeny: { session.resolveToolConfirmation(id: confirmation.id, approved: false) }
      )
      .id(confirmation.id)
      .layoutPriority(1)
      .padding(.horizontal, verticalSizeClass == .compact ? 0 : Theme.Spacing.lg)
      .transition(panelTransition)
    } else if !session.latestActionCards.isEmpty {
      ActionCardStack(cards: session.latestActionCards, isCompact: true)
        .padding(.horizontal, verticalSizeClass == .compact ? 0 : Theme.Spacing.lg)
        .transition(panelTransition)
        .accessibilityIdentifier("voice.actionCards")
    }
  }

  @ViewBuilder
  private var cameraErrorNotice: some View {
    if let cameraError = session.cameraError {
      HStack(spacing: Theme.Spacing.sm) {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(Theme.Status.guarded)
          .accessibilityHidden(true)
        Text(cameraError)
          .font(.footnote)
          .foregroundStyle(Theme.Status.guarded)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, Theme.Spacing.md)
      .padding(.vertical, Theme.Spacing.sm)
      .surfaceCard(radius: Theme.Radius.row)
      .padding(.horizontal, Theme.Spacing.lg)
      .transition(panelTransition)
      .accessibilityIdentifier("voice.cameraError")
    }
  }

  private func scrollToConfirmation(id: UUID?, proxy: ScrollViewProxy) {
    guard let id, let confirmation = session.pendingToolConfirmation else { return }
    withAppAnimation(Theme.Motion.easeOut) {
      proxy.scrollTo(id, anchor: .bottom)
    }
    Haptics.announce(confirmation.summary)
  }

  /// The words being said, newest at the bottom: a long answer scrolls rather than stopping at
  /// six lines of its start.
  @ViewBuilder
  private func captions(isCompact: Bool) -> some View {
    if !session.heard.isEmpty || !session.answer.isEmpty {
      ScrollView {
        captionText(isCompact: isCompact)
      }
      .defaultScrollAnchor(.bottom)
      .scrollBounceBehavior(.basedOnSize)
      .frame(maxHeight: session.pendingToolConfirmation != nil ? 100 : (isCompact ? 132 : 240))
    }
  }

  private func captionText(isCompact: Bool) -> some View {
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
    .padding(.horizontal, isCompact ? Theme.Spacing.sm : Theme.Spacing.xxl)
  }

  private var controls: some View {
    GlassEffectContainer(spacing: Theme.Spacing.lg) {
      HStack(spacing: Theme.Spacing.lg) {
        Button {
          Haptics.selection()
          Task { await session.toggleCamera() }
        } label: {
          Image(systemName: session.cameraOn ? "camera.fill" : "camera")
            .font(.title3.weight(.medium))
            .foregroundStyle(session.cameraOn ? tint : Theme.Text.primary)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 56, height: 56)
            .chromeSurface(in: Circle(), tint: session.cameraOn ? tint : nil, interactive: true)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .opacity(!CameraFeed.isAvailable || session.isCameraToggling ? 0.45 : 1)
        .disabled(!CameraFeed.isAvailable || session.isCameraToggling)
        .accessibilityLabel("Camera")
        .accessibilityValue(session.cameraOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier("voice.toggleCamera")

        Button {
          Haptics.selection()
          session.toggleMute()
        } label: {
          Image(systemName: session.muted ? "mic.slash.fill" : "mic.fill")
            .font(.title3.weight(.medium))
            .foregroundStyle(session.muted ? tint : Theme.Text.primary)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 56, height: 56)
            .chromeSurface(in: Circle(), tint: session.muted ? tint : nil, interactive: true)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(session.muted ? "Unmute" : "Mute")
        .accessibilityIdentifier("voice.mute")

        Button {
          Haptics.selection()
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.title3.weight(.semibold))
            .foregroundStyle(Theme.Text.primary)
            .frame(width: 56, height: 56)
            .chromeSurface(in: Circle(), tint: Theme.Status.critical, interactive: true)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("End voice mode")
        .accessibilityIdentifier("voice.end")
      }
    }
  }
}

/// Isolated orb view so ~25 Hz `session.level` updates never re-diff the rest of ``VoiceModeView``.
/// Uses a zero-offscreen-pass `RadialGradient` halo instead of an animated Gaussian blur and runs
/// `phaseAnimator` strictly while `.thinking` or `.speaking` (0 frames while idle `.listening`).
private struct VoiceOrbView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  let session: VoiceSession
  let isCompact: Bool
  let tint: Color

  private var canInterrupt: Bool {
    session.state == .thinking || session.state == .speaking
  }

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
    let shouldPulse = !reduceMotion && canInterrupt
    let core = ZStack {
      // Halo: zero-offscreen-pass soft radial bloom replacing a 44 pt Gaussian `.blur`,
      // suppressed when Reduce Transparency is enabled.
      if !reduceTransparency {
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
      }
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
    .appAnimation(Theme.Motion.stateChange, value: session.state, kind: .dissolve)
    .appAnimation(Theme.Motion.panel, value: session.cameraOn)
    .appAnimation(Theme.Motion.panel, value: hasConfirmation)

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
    .accessibilityHint(canInterrupt ? String(localized: "Double-tap to interrupt") : "")
    .accessibilityAddTraits(.isButton)
  }
}
