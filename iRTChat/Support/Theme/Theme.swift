import SwiftUI
import UIKit

/// The design system: one dark palette, warm neutrals, and a mode accent
/// that lights the backdrop, the composer and the primary action.
///
/// Rules:
/// - Color lives in the content layer; Liquid Glass stays on chrome
///   (toolbar, composer, floating controls) and is tinted only for the
///   primary action.
/// - Text is warm off-white, never pure white; hairlines are cream.
/// - Every shape uses continuous corners; spacing snaps to `Spacing`.
/// - Motion uses `Motion` and collapses under Reduce Motion.
enum Theme {
  // MARK: - Modes

  /// What the next message will do. Each mode has one accent; the active
  /// mode tints the backdrop glow, the pills and the send button.
  enum Mode: Sendable, Equatable {
    case chat, think, search, voice

    var tint: Color {
      switch self {
      case .chat: Theme.Brand.glacier
      case .think: Theme.Brand.lavender
      case .search: Theme.Brand.teal
      case .voice: Theme.Brand.gold
      }
    }
  }

  enum Brand {
    /// Signature accent: chat, links, selection.
    static let glacier = Color(red: 0.541, green: 0.690, blue: 0.784)
    /// Think: reasoning.
    static let lavender = Color(red: 0.749, green: 0.667, blue: 0.863)
    /// Search: the web.
    static let teal = Color(red: 0.549, green: 0.780, blue: 0.749)
    /// Voice: talk, read aloud.
    static let gold = Color(red: 0.929, green: 0.800, blue: 0.541)
    /// Neutral for chrome with no mode (settings, sheets).
    static let silver = Color(red: 0.68, green: 0.71, blue: 0.76)
  }

  // MARK: - Surfaces (dark ramp)

  enum Surface {
    static let canvas = Color(red: 0.086, green: 0.094, blue: 0.137)
    static let canvasBottom = Color(red: 0.038, green: 0.044, blue: 0.056)
    /// Raised content: the user's bubble, cards on the canvas.
    static let stage = Color(red: 0.110, green: 0.118, blue: 0.149)
    /// Inset content: code blocks, tables.
    static let card = Color(red: 0.051, green: 0.055, blue: 0.071)
    static let inline = Color(red: 0.067, green: 0.075, blue: 0.102)
    static let field = Color(red: 0.120, green: 0.126, blue: 0.148)
    /// Chrome panels (composer, banners) under their glass.
    static let panel = Color(red: 0.105, green: 0.112, blue: 0.132, opacity: 0.86)
    /// The drawer.
    static let drawer = Color(red: 0.075, green: 0.083, blue: 0.102, opacity: 0.97)
    /// Grouped rows (settings, drawer sections).
    static let group = Color.white.opacity(0.035)
    static let groupPressed = Color.white.opacity(0.07)
    /// Warm cream hairlines.
    static let hairline = Color(red: 0.97, green: 0.92, blue: 0.82, opacity: 0.08)
    static let stroke = Color(red: 0.97, green: 0.92, blue: 0.82, opacity: 0.12)
    static let glassOuterStroke = Color.white.opacity(0.12)
    static let glassInnerStroke = Color.white.opacity(0.04)
  }

  // MARK: - Text

  enum Text {
    static let primary = Color(red: 0.95, green: 0.94, blue: 0.92)
    static let secondary = Color(red: 0.78, green: 0.76, blue: 0.72)
    static let tertiary = Color(red: 0.62, green: 0.60, blue: 0.55)
    /// Clears WCAG-AA 4.5:1 on every surface.
    static let placeholder = Color(red: 0.60, green: 0.63, blue: 0.68)
  }

  // MARK: - Status

  enum Status {
    static let healthy = Color(red: 0.55, green: 0.70, blue: 0.55)
    static let guarded = Color(red: 0.85, green: 0.70, blue: 0.45)
    static let critical = Color(red: 0.85, green: 0.50, blue: 0.50)
  }

  // MARK: - Accent helpers

  static func accentSurface(_ tint: Color) -> Color { tint.opacity(0.10) }
  static func accentWash(_ tint: Color) -> Color { tint.opacity(0.20) }
  static func accentStroke(_ tint: Color) -> Color { tint.opacity(0.34) }

  static func glassTint(_ tint: Color?) -> Color {
    tint.map { $0.opacity(0.14 * 0.9) } ?? Brand.silver.opacity(0.10 * 0.9)
  }

  // MARK: - Geometry

  enum Radius {
    static let chip: CGFloat = 8
    static let tile: CGFloat = 9
    static let input: CGFloat = 10
    static let row: CGFloat = 12
    static let card: CGFloat = 16
    static let group: CGFloat = 18
    static let bubble: CGFloat = 22
    static let composer: CGFloat = 28
  }

  enum Stroke {
    static let hairline: CGFloat = 0.5
    static let standard: CGFloat = 1
  }

  enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    /// Glyph to label inside a control.
    static let tight: CGFloat = 6
    static let sm: CGFloat = 8
    /// A row's internal gaps.
    static let snug: CGFloat = 10
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    /// Screen gutter for text.
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
  }

  enum Size {
    /// Minimum tappable control (HIG).
    static let target: CGFloat = 44
    /// Composer pills and chips.
    static let pill: CGFloat = 36
    /// Icon tiles in grouped rows.
    static let tile: CGFloat = 30
    /// Inline glyph buttons (message actions); the hit area stays 44.
    static let glyph: CGFloat = 32
    static let hero: CGFloat = 64
  }

  // MARK: - Elevation

  enum Elevation {
    static func glow(_ tint: Color) -> Color { tint.opacity(0.28) }
    static let glowRadius: CGFloat = 8
    static func ctaGlow(_ tint: Color) -> Color { tint.opacity(0.35) }
    static let ctaGlowRadius: CGFloat = 16
    static let ctaDrop = Color.black.opacity(0.22)
    static let floating = Color.black.opacity(0.40)
  }

  // MARK: - Motion

  /// One ease-out curve everywhere (0.22, 1, 0.36, 1); no bounce.
  enum Motion {
    static let press = Animation.easeOut(duration: 0.09)
    static let stateChange = Animation.easeOut(duration: 0.15)
    static let easeOut = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.22)
    static let slide = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.32)
    static let sheet = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.36)
    static let panel = Animation.spring(response: 0.31, dampingFraction: 0.84, blendDuration: 0.12)
    static let modeCrossfade = Animation.easeInOut(duration: 0.18)
  }
}

// MARK: - Typography

extension Font {
  /// Page titles (Settings, Projects).
  static let pageTitle = Font.system(.largeTitle, weight: .bold)
  /// Sheet titles.
  static let sheetTitle = Font.system(.title2, weight: .bold)
  /// The empty chat's greeting: the largest text in the chat.
  static let greeting = Font.system(.title2, weight: .medium)
  /// Row titles in grouped lists.
  static let rowTitle = Font.system(.subheadline, weight: .medium)
  /// Uppercase section labels.
  static let eyebrow = Font.system(.caption, weight: .semibold)
  /// The wordmark.
  static let wordmark = Font.system(.title3, design: .rounded, weight: .semibold)
}

extension View {
  /// Uppercase, tracked section label in the secondary color (or a tint).
  func eyebrowStyle(_ tint: Color = Theme.Text.secondary) -> some View {
    self.font(.eyebrow)
      .textCase(.uppercase)
      .tracking(0.9)
      .foregroundStyle(tint)
  }

  /// `animation` unless Reduce Motion is on.
  func appAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
    modifier(ReduceMotionAnimation(animation: animation, value: value))
  }
}

private struct ReduceMotionAnimation<V: Equatable>: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let animation: Animation
  let value: V

  func body(content: Content) -> some View {
    content.animation(reduceMotion ? nil : animation, value: value)
  }
}

/// `withAnimation` that respects Reduce Motion.
@MainActor
func withAppAnimation<Result>(_ animation: Animation, _ body: () throws -> Result) rethrows -> Result {
  if UIAccessibility.isReduceMotionEnabled { return try body() }
  return try withAnimation(animation, body)
}
