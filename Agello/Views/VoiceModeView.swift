import SwiftUI

/// Full-screen voice conversation in the voice mode's gold: an orb that
/// reacts to the voices, live captions, the camera, mute, and end.
struct VoiceModeView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var session: VoiceSession

  private let tint = Theme.Mode.voice.tint

  init(session: VoiceSession) {
    _session = State(initialValue: session)
  }

  var body: some View {
    VStack(spacing: Theme.Spacing.xxl) {
      if session.cameraOn {
        CameraPreview(session: session.camera.session)
          .clipShape(.rect(cornerRadius: Theme.Radius.composer, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous)
              .stroke(Theme.Surface.stroke, lineWidth: Theme.Stroke.hairline)
          }
          .frame(maxHeight: 360)
          .padding(.horizontal, Theme.Spacing.lg)
          .accessibilityLabel("Camera")
          .accessibilityIdentifier("voice.camera")
      } else {
        Spacer()
      }
      orb
      Text(session.state.label)
        .font(.system(.headline, weight: .semibold))
        .foregroundStyle(Theme.Text.secondary)
        .contentTransition(.opacity)
        .accessibilityIdentifier("voice.state")
      captions
      Spacer()
      controls
    }
    .padding(.vertical, Theme.Spacing.lg)
    .frame(maxWidth: .infinity)
    .ambientBackdrop(tint, intensity: .loud)
    .task { await session.start() }
    .onDisappear { session.end() }
    .preferredColorScheme(.dark)
  }

  private var orb: some View {
    let active = session.state == .hearing || session.state == .speaking
    let size: CGFloat = session.cameraOn ? 96 : 200
    let scale = 1 + (active ? session.level * 0.35 : 0)
    let core = ZStack {
      // Halo: a soft bloom in the voice color.
      Circle()
        .fill(tint.opacity(0.35))
        .blur(radius: size * 0.22)
        .scaleEffect(1.25)
      // Core: warm light at the center fading to deep gold.
      Circle()
        .fill(
          RadialGradient(
            colors: [Theme.Text.primary, tint, tint.mix(with: .black, by: 0.55, in: .perceptual)],
            center: UnitPoint(x: 0.42, y: 0.38), startRadius: 2, endRadius: size * 0.62))
      Circle()
        .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
    }
    .frame(width: size, height: size)
    .scaleEffect(scale)
    .opacity(session.state == .thinking ? 0.75 : 1)
    .animation(Theme.Motion.stateChange, value: session.level)
    .animation(Theme.Motion.slide, value: session.cameraOn)
    return Group {
      if reduceMotion {
        core
      } else {
        core.phaseAnimator([1.0, 1.06]) { view, pulse in
          view.scaleEffect(session.state == .thinking || session.state == .speaking ? pulse : 1)
        } animation: { _ in .easeInOut(duration: 0.9) }
      }
    }
    .contentShape(Circle())
    .onTapGesture { session.interrupt() }
    .accessibilityLabel("Voice")
    .accessibilityHint("Tap to interrupt the answer")
    .accessibilityAddTraits(.isButton)
  }

  private var captions: some View {
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
    .lineLimit(6)
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
