import SwiftUI

/// The canvas with a soft radial glow in the active mode's color, anchored
/// to the top edge and fading out by mid-screen: what gives each mode its
/// identity before any control is drawn. Reduce Transparency gets the flat
/// canvas.
struct AmbientBackdrop: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  var tint: Color = Theme.Mode.chat.tint
  var intensity: Intensity = .warm

  enum Intensity {
    case whisper, warm, loud

    var topOpacity: Double {
      switch self {
      case .whisper: 0.22
      case .warm: 0.38
      case .loud: 0.62
      }
    }
  }

  var body: some View {
    GeometryReader { proxy in
      let radius = max(proxy.size.width * 0.72, proxy.size.height * 0.52)
      ZStack {
        LinearGradient(
          colors: [Theme.Surface.canvas, Theme.Surface.canvasBottom],
          startPoint: .top, endPoint: .bottom)
        if !reduceTransparency {
          RadialGradient(
            stops: [
              .init(color: tint.opacity(intensity.topOpacity), location: 0),
              .init(color: tint.opacity(intensity.topOpacity * 0.42), location: 0.34),
              .init(color: .clear, location: 0.62),
            ],
            center: UnitPoint(x: 0.5, y: 0), startRadius: 0, endRadius: radius
          )
          .scaleEffect(x: 1.55, y: 0.92, anchor: .top)
          .blendMode(.plusLighter)
        }
      }
    }
    .ignoresSafeArea()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

extension View {
  /// Full-screen backdrop behind a screen's content.
  func ambientBackdrop(_ tint: Color = Theme.Mode.chat.tint, intensity: AmbientBackdrop.Intensity = .warm)
    -> some View
  {
    background { AmbientBackdrop(tint: tint, intensity: intensity) }
  }
}
