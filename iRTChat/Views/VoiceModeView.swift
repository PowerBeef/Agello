import SwiftUI

/// Full-screen voice conversation: an orb that reacts to the voices,
/// live captions, the camera, mute, and end.
struct VoiceModeView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var session: VoiceSession

  init(session: VoiceSession) {
    _session = State(initialValue: session)
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color.black, Color.accentColor.opacity(0.35)], startPoint: .top, endPoint: .bottom
      )
      .ignoresSafeArea()

      VStack(spacing: 24) {
        if session.cameraOn {
          CameraPreview(session: session.camera.session)
            .clipShape(.rect(cornerRadius: 28))
            .frame(maxHeight: 360)
            .padding(.horizontal)
            .accessibilityLabel("Camera")
            .accessibilityIdentifier("voice.camera")
        } else {
          Spacer()
        }
        orb
        Text(session.state.label)
          .font(.headline)
          .foregroundStyle(.white.opacity(0.85))
          .accessibilityIdentifier("voice.state")
        captions
        Spacer()
        controls
      }
      .padding(.vertical)
    }
    .task { await session.start() }
    .onDisappear { session.end() }
    .preferredColorScheme(.dark)
  }

  private var orb: some View {
    let active = session.state == .hearing || session.state == .speaking
    let scale = 1 + (active ? session.level * 0.35 : 0)
    return Circle()
      .fill(
        RadialGradient(
          colors: [Color.white, Color.accentColor, Color.accentColor.opacity(0.2)],
          center: .center, startRadius: 4, endRadius: 110)
      )
      .frame(width: session.cameraOn ? 90 : 190, height: session.cameraOn ? 90 : 190)
      .scaleEffect(scale)
      .opacity(session.state == .thinking ? 0.7 : 1)
      .phaseAnimator([1.0, 1.06]) { view, pulse in
        view.scaleEffect(session.state == .thinking || session.state == .speaking ? pulse : 1)
      } animation: { _ in .easeInOut(duration: 0.8) }
      .animation(.easeOut(duration: 0.12), value: session.level)
      .onTapGesture { session.interrupt() }
      .accessibilityLabel("Voice")
      .accessibilityHint("Tap to interrupt the answer")
      .accessibilityAddTraits(.isButton)
  }

  private var captions: some View {
    VStack(spacing: 10) {
      if !session.heard.isEmpty {
        Text(session.heard)
          .font(.callout)
          .foregroundStyle(.white.opacity(0.6))
          .accessibilityIdentifier("voice.heard")
      }
      if !session.answer.isEmpty {
        Text(session.answer)
          .font(.title3)
          .foregroundStyle(.white)
          .accessibilityIdentifier("voice.answer")
      }
    }
    .multilineTextAlignment(.center)
    .lineLimit(6)
    .padding(.horizontal, 28)
    .animation(.default, value: session.answer)
  }

  private var controls: some View {
    HStack(spacing: 28) {
      control(session.cameraOn ? "camera.fill" : "camera", label: "Camera", id: "voice.toggleCamera") {
        Task { await session.toggleCamera() }
      }
      .disabled(!CameraFeed.isAvailable)
      control(session.muted ? "mic.slash.fill" : "mic.fill", label: session.muted ? "Unmute" : "Mute", id: "voice.mute") {
        session.toggleMute()
      }
      control("xmark", label: "End voice mode", id: "voice.end", tint: .red) {
        dismiss()
      }
    }
  }

  private func control(
    _ symbol: String, label: String, id: String, tint: Color? = nil, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.title2)
        .foregroundStyle(.white)
        .frame(width: 64, height: 64)
        .glassEffect(tint.map { .regular.tint($0).interactive() } ?? .regular.interactive(), in: .circle)
    }
    .accessibilityLabel(label)
    .accessibilityIdentifier(id)
  }
}
