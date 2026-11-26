import SwiftUI

/// The canvas with a soft radial glow in the active mode's color, anchored
/// to the top edge and fading out by mid-screen: what gives each mode its
/// identity before any control is drawn. Reduce Transparency and Increase
/// Contrast get the flat canvas.
struct AmbientBackdrop: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  var tint: Color = Theme.Mode.chat.tint
  var intensity: Intensity = .warm

  enum Intensity {
    case whisper, warm, loud

    /// Normal-blended alpha over `Theme.Surface.canvas` (`#161823`, relative luminance `0.0094`).
    /// Worst-case top-edge luminance occurs with `Theme.Brand.gold` (`0.929, 0.800, 0.541`) at
    /// `.loud` (`0.135`), compositing to `#333031` (`L = 0.0306`):
    /// - `Theme.Text.primary` (`L = 0.8704`): `11.42:1`
    /// - `Theme.Text.secondary` (`L = 0.5407`): `7.33:1`
    /// - `Theme.Text.tertiary` (`L = 0.3196`): `4.59:1`
    /// - `Theme.Status.critical` (`L = 0.3157`): `4.54:1`
    /// All four text roles clear WCAG 2.1 AA (`>= 4.5:1`) across all five brand accents.
    var topOpacity: Double {
      switch self {
      case .whisper: 0.08
      case .warm: 0.11
      case .loud: 0.135
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
        if !reduceTransparency, contrast != .increased {
          RadialGradient(
            stops: [
              .init(color: tint.opacity(intensity.topOpacity), location: 0),
              .init(color: tint.opacity(intensity.topOpacity * 0.50), location: 0.34),
              .init(color: .clear, location: 0.66),
            ],
            center: UnitPoint(x: 0.5, y: 0), startRadius: 0, endRadius: radius
          )
          .scaleEffect(x: 1.55, y: 0.92, anchor: .top)
        }
      }
      .clipped()
      .drawingGroup(opaque: true)
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
    background {
      AmbientBackdrop(tint: tint, intensity: intensity)
        .ignoresSafeArea(.keyboard)
    }
  }
}
