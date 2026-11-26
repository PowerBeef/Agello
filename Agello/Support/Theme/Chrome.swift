import SwiftUI

/// Chrome surfaces: Liquid Glass with lit-edge hairlines (outer 0.8 pt,
/// inner 0.55 pt inset). Glass stays on chrome only (composer, banners,
/// floating controls). Reduce Transparency drops the glass and fills with
/// a solid stage surface; Increased Contrast strengthens the outer stroke.
struct ChromeSurface<S: InsettableShape>: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  let shape: S
  var tint: Color?
  var interactive = false

  func body(content: Content) -> some View {
    content
      .background {
        if reduceTransparency {
          shape.fill(Theme.Surface.stage)
        }
      }
      .overlay {
        shape
          .strokeBorder(
            contrast == .increased ? Theme.Surface.increasedContrastStroke : Theme.Surface.glassOuterStroke,
            lineWidth: Theme.Stroke.chrome
          )
          .allowsHitTesting(false)
      }
      .overlay {
        shape
          .inset(by: Theme.Stroke.innerInset)
          .strokeBorder(Theme.Surface.glassInnerStroke, lineWidth: Theme.Stroke.inner)
          .allowsHitTesting(false)
      }
      .glassEffect(glass, in: shape)
  }

  private var glass: Glass {
    guard !reduceTransparency else { return .identity }
    let base: Glass = tint.map { Glass.regular.tint(Theme.glassTint($0)) } ?? .regular
    return interactive ? base.interactive() : base
  }
}

extension View {
  func chromeSurface<S: InsettableShape>(
    in shape: S, tint: Color? = nil, interactive: Bool = false
  ) -> some View {
    modifier(ChromeSurface(shape: shape, tint: tint, interactive: interactive))
  }

  /// Content-layer card: a faint fill and a cream hairline, no glass.
  func surfaceCard(
    radius: CGFloat = Theme.Radius.card, fill: Color = Theme.Surface.group,
    stroke: Color = Theme.Surface.hairline
  ) -> some View {
    modifier(SurfaceCard(radius: radius, fill: fill, stroke: stroke))
  }
}

private struct SurfaceCard: ViewModifier {
  @Environment(\.colorSchemeContrast) private var contrast
  let radius: CGFloat
  let fill: Color
  let stroke: Color

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    content
      .background { shape.fill(fill) }
      .overlay {
        shape
          .strokeBorder(
            resolvedStroke,
            lineWidth: contrast == .increased ? Theme.Stroke.chrome : Theme.Stroke.hairline
          )
          .allowsHitTesting(false)
      }
  }

  private var resolvedStroke: Color {
    guard contrast == .increased else { return stroke }
    return stroke == Theme.Surface.hairline
      ? Theme.Surface.increasedContrastStroke
      : stroke.mix(with: .white, by: 0.45, in: .perceptual)
  }
}

/// The primary action's "lit tint": a translucent tint gradient, hairline
/// strokes, a lit top edge and a tint bloom. The brightest surface on
/// screen; one per context. Reduce Transparency gets an opaque deep tint.
struct LitTintBackground<S: InsettableShape>: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  let shape: S
  let tint: Color
  var isEnabled = true
  var isPressed = false
  /// The selector pills use a softer version of the same recipe.
  var strength: Strength = .primary

  enum Strength {
    case primary, pill

    /// Top stop keeps `Theme.Text.primary` >= 4.5:1 (WCAG 2.1 AA) over `Theme.Surface.stage` even
    /// for the brightest accent (`Theme.Brand.gold`: `5.39:1` resting at `0.38`, `4.59:1` pressed
    /// at `0.44`).
    var top: Double { self == .primary ? 0.38 : 0.30 }
    var bottom: Double { self == .primary ? 0.20 : 0.14 }
  }

  var body: some View {
    shape
      .fill(fillStyle)
      .shadow(
        color: reduceTransparency || !isEnabled
          ? .clear : (strength == .primary ? Theme.Elevation.ctaGlow(tint) : Theme.Elevation.glow(tint)),
        radius: strength == .primary ? Theme.Elevation.ctaGlowRadius : Theme.Elevation.glowRadius,
        y: strength == .primary ? Theme.Elevation.ctaGlowOffsetY : Theme.Elevation.glowOffsetY
      )
      .overlay {
        shape
          .strokeBorder(
            contrast == .increased ? Theme.Surface.increasedContrastStroke : Theme.Surface.litOuterStroke,
            lineWidth: Theme.Stroke.chrome
          )
          .allowsHitTesting(false)
      }
      .overlay {
        shape
          .inset(by: Theme.Stroke.innerInset)
          .strokeBorder(Theme.Surface.litInnerStroke, lineWidth: Theme.Stroke.inner)
          .allowsHitTesting(false)
      }
      .overlay {
        shape
          .strokeBorder(
            LinearGradient(
              colors: [Theme.Surface.litTopEdge, .clear],
              startPoint: .top, endPoint: .center),
            lineWidth: Theme.Stroke.topEdge
          )
          .allowsHitTesting(false)
      }
      .allowsHitTesting(false)
  }

  private var fillStyle: AnyShapeStyle {
    if reduceTransparency {
      let darken: Double =
        if !isEnabled {
          0.70
        } else if isPressed {
          0.48
        } else {
          0.52
        }
      return AnyShapeStyle(tint.mix(with: .black, by: darken, in: .perceptual))
    }
    let top = isPressed ? min(1, strength.top + 0.06) : strength.top
    let bottom = isPressed ? min(1, strength.bottom + 0.04) : strength.bottom
    return AnyShapeStyle(
      LinearGradient(
        colors: isEnabled
          ? [tint.opacity(top), tint.opacity(bottom)]
          : [tint.opacity(0.14), tint.opacity(0.08)],
        startPoint: .top, endPoint: .bottom))
  }
}

/// Neutral chrome for secondary controls: a faint fill and hairline.
/// Reduce Transparency uses an opaque stage fill; Increased Contrast boosts the stroke.
struct QuietBackground<S: InsettableShape>: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast
  let shape: S
  var isPressed = false

  var body: some View {
    shape
      .fill(fillColor)
      .overlay {
        shape
          .strokeBorder(
            contrast == .increased ? Theme.Surface.increasedContrastStroke : Theme.Surface.quietStroke,
            lineWidth: Theme.Stroke.chrome
          )
          .allowsHitTesting(false)
      }
      .allowsHitTesting(false)
  }

  private var fillColor: Color {
    if reduceTransparency {
      return isPressed
        ? Theme.Surface.stage.mix(with: .white, by: 0.08, in: .perceptual)
        : Theme.Surface.stage
    }
    return isPressed ? Theme.Surface.quietPressedFill : Theme.Surface.quietFill
  }
}
