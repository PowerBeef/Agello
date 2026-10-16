import SwiftUI

/// Chrome surfaces: Liquid Glass over a solid panel with the lit-edge
/// hairlines (outer 0.8 pt, inner 0.55 pt inset). Glass stays on chrome only
/// (composer, banners, floating controls). Reduce Transparency drops the
/// glass and keeps the solid panel.
struct ChromeSurface<S: InsettableShape>: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  let shape: S
  var tint: Color?
  var interactive = false
  var fill: Color = Theme.Surface.panel

  func body(content: Content) -> some View {
    content
      .background { shape.fill(reduceTransparency ? Theme.Surface.stage : fill) }
      .overlay {
        shape.stroke(
          contrast == .increased ? Color.white.opacity(0.5) : Theme.Surface.glassOuterStroke,
          lineWidth: 0.8
        ).allowsHitTesting(false)
      }
      .overlay {
        shape.inset(by: 0.65).stroke(Theme.Surface.glassInnerStroke, lineWidth: 0.55)
          .allowsHitTesting(false)
      }
      .glassEffect(glass, in: shape)
  }

  private var glass: Glass {
    guard !reduceTransparency else { return .identity }
    let tinted = Glass.regular.tint(Theme.glassTint(tint))
    return interactive ? tinted.interactive() : tinted
  }
}

extension View {
  func chromeSurface<S: InsettableShape>(
    in shape: S, tint: Color? = nil, interactive: Bool = false, fill: Color = Theme.Surface.panel
  ) -> some View {
    modifier(ChromeSurface(shape: shape, tint: tint, interactive: interactive, fill: fill))
  }

  /// Content-layer card: a faint fill and a cream hairline, no glass.
  func surfaceCard(
    radius: CGFloat = Theme.Radius.card, fill: Color = Theme.Surface.group,
    stroke: Color = Theme.Surface.hairline
  ) -> some View {
    background {
      RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill)
    }
    .overlay {
      RoundedRectangle(cornerRadius: radius, style: .continuous)
        .stroke(stroke, lineWidth: Theme.Stroke.hairline)
    }
  }
}

/// The primary action's "lit tint": a translucent tint gradient, hairline
/// strokes, a lit top edge and a tint bloom. The brightest surface on
/// screen; one per context. Reduce Transparency gets an opaque deep tint.
struct LitTintBackground<S: InsettableShape>: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  let shape: S
  let tint: Color
  var isEnabled = true
  /// The selector pills use a softer version of the same recipe.
  var strength: Strength = .primary

  enum Strength {
    case primary, pill

    var top: Double { self == .primary ? 0.46 : 0.30 }
    var bottom: Double { self == .primary ? 0.24 : 0.14 }
  }

  var body: some View {
    shape
      .fill(fillStyle)
      .overlay { shape.stroke(Color.white.opacity(0.16), lineWidth: 0.8) }
      .overlay { shape.inset(by: 0.65).stroke(Color.white.opacity(0.06), lineWidth: 0.55) }
      .overlay {
        shape.stroke(Color.white.opacity(0.22), lineWidth: 0.6)
          .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
      }
      .shadow(
        color: reduceTransparency || !isEnabled
          ? .clear : (strength == .primary ? Theme.Elevation.ctaGlow(tint) : Theme.Elevation.glow(tint)),
        radius: strength == .primary ? Theme.Elevation.ctaGlowRadius : Theme.Elevation.glowRadius,
        y: strength == .primary ? 4 : 1
      )
  }

  private var fillStyle: AnyShapeStyle {
    if reduceTransparency {
      return AnyShapeStyle(tint.mix(with: .black, by: isEnabled ? 0.42 : 0.70, in: .perceptual))
    }
    return AnyShapeStyle(
      LinearGradient(
        colors: isEnabled
          ? [tint.opacity(strength.top), tint.opacity(strength.bottom)]
          : [tint.opacity(0.14), tint.opacity(0.08)],
        startPoint: .top, endPoint: .bottom))
  }
}

/// Neutral chrome for secondary controls: a faint fill and hairline.
struct QuietBackground<S: InsettableShape>: View {
  @Environment(\.colorSchemeContrast) private var contrast
  let shape: S
  var isPressed = false

  var body: some View {
    shape
      .fill(Color.white.opacity(isPressed ? 0.10 : 0.06))
      .overlay {
        shape.stroke(Color.white.opacity(contrast == .increased ? 0.5 : 0.10), lineWidth: 0.8)
      }
  }
}
