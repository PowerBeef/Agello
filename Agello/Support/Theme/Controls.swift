import SwiftUI

// MARK: - Buttons

/// The primary action: a full-width (or hugging) lit-tint capsule with an
/// off-white label. One per screen.
struct LitButtonStyle: ButtonStyle {
  var tint: Color = Theme.Mode.chat.tint
  var fullWidth = true

  func makeBody(configuration: Configuration) -> some View {
    StyleBody(configuration: configuration, tint: tint, fullWidth: fullWidth)
  }

  private struct StyleBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = Theme.Size.target + Theme.Spacing.sm
    let configuration: Configuration
    let tint: Color
    let fullWidth: Bool

    var body: some View {
      let pressed = isEnabled && configuration.isPressed
      configuration.label
        .font(.headline)
        .tracking(Theme.Typography.ctaTracking)
        .foregroundStyle(isEnabled ? Theme.Text.primary : Theme.Text.secondary)
        .symbolRenderingMode(.hierarchical)
        .padding(.horizontal, fullWidth ? Theme.Spacing.lg : Theme.Spacing.xxl)
        .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
        .background {
          LitTintBackground(shape: Capsule(), tint: tint, isEnabled: isEnabled, isPressed: pressed)
        }
        .contentShape(Capsule())
        .opacity(isEnabled ? 1 : 0.55)
        .appAnimation(Theme.Motion.press, value: pressed, kind: .dissolve)
        .appAnimation(Theme.Motion.stateChange, value: isEnabled, kind: .dissolve)
        .scaleEffect(reduceMotion || !pressed ? 1 : 0.98)
        .appAnimation(Theme.Motion.press, value: pressed)
    }
  }
}

/// The composer's send / voice / stop button: a lit-tint circle with an
/// off-white glyph (never accent on accent).
struct LitCircleButtonStyle: ButtonStyle {
  var tint: Color
  var size: CGFloat = Theme.Size.target

  func makeBody(configuration: Configuration) -> some View {
    StyleBody(configuration: configuration, tint: tint, size: size)
  }

  private struct StyleBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: Configuration
    let tint: Color
    let size: CGFloat

    var body: some View {
      let pressed = isEnabled && configuration.isPressed
      configuration.label
        .font(.system(size > Theme.Size.target ? .title3 : .body, weight: .semibold))
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .foregroundStyle(isEnabled ? Theme.Text.primary : Theme.Text.tertiary)
        .frame(width: size, height: size)
        .background {
          LitTintBackground(shape: Circle(), tint: tint, isEnabled: isEnabled, isPressed: pressed)
        }
        .contentShape(Circle())
        .opacity(isEnabled ? 1 : 0.55)
        .appAnimation(Theme.Motion.press, value: pressed, kind: .dissolve)
        .appAnimation(Theme.Motion.stateChange, value: isEnabled, kind: .dissolve)
        .scaleEffect(reduceMotion || !pressed ? 1 : 0.94)
        .appAnimation(Theme.Motion.press, value: pressed)
    }
  }
}

/// Secondary round controls (attach, mic, close): quiet fill and hairline,
/// 44 pt target.
struct QuietCircleButtonStyle: ButtonStyle {
  var size: CGFloat = Theme.Size.target
  var tint: Color = Theme.Text.primary

  func makeBody(configuration: Configuration) -> some View {
    StyleBody(configuration: configuration, size: size, tint: tint)
  }

  private struct StyleBody: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: Configuration
    let size: CGFloat
    let tint: Color

    var body: some View {
      let pressed = isEnabled && configuration.isPressed
      configuration.label
        .font(.system(.body, weight: .medium))
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .foregroundStyle(tint)
        .frame(width: size, height: size)
        .background { QuietBackground(shape: Circle(), isPressed: pressed) }
        .frame(minWidth: Theme.Size.target, minHeight: Theme.Size.target)
        .contentShape(Circle())
        .opacity(isEnabled ? 1 : 0.42)
        .appAnimation(Theme.Motion.press, value: pressed, kind: .dissolve)
        .appAnimation(Theme.Motion.stateChange, value: isEnabled, kind: .dissolve)
    }
  }
}

/// Secondary capsule buttons (Pause, Cancel, Delete): quiet fill and
/// hairline; the label carries the color.
struct QuietCapsuleButtonStyle: ButtonStyle {
  var tint: Color = Theme.Text.primary

  func makeBody(configuration: Configuration) -> some View {
    StyleBody(configuration: configuration, tint: tint)
  }

  private struct StyleBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .footnote) private var height: CGFloat = Theme.Size.pill
    let configuration: Configuration
    let tint: Color

    var body: some View {
      let pressed = isEnabled && configuration.isPressed
      configuration.label
        .font(.system(.footnote, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(minHeight: height)
        .background { QuietBackground(shape: Capsule(), isPressed: pressed) }
        .frame(minHeight: Theme.Size.target)
        .contentShape(.rect)
        .opacity(isEnabled ? 1 : 0.42)
        .appAnimation(Theme.Motion.press, value: pressed, kind: .dissolve)
        .appAnimation(Theme.Motion.stateChange, value: isEnabled, kind: .dissolve)
    }
  }
}

/// A mode toggle (Think, Search): quiet when off, lit in its mode color when
/// on. The title never truncates; `iconOnly` is the compact fallback.
struct ModePillStyle: ButtonStyle {
  let isOn: Bool
  let tint: Color
  var iconOnly = false

  func makeBody(configuration: Configuration) -> some View {
    StyleBody(configuration: configuration, isOn: isOn, tint: tint, iconOnly: iconOnly)
  }

  private struct StyleBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = Theme.Size.pill
    let configuration: Configuration
    let isOn: Bool
    let tint: Color
    let iconOnly: Bool

    var body: some View {
      let pressed = isEnabled && configuration.isPressed
      configuration.label
        .labelStyle(PillLabelStyle(iconOnly: iconOnly))
        .font(.system(.subheadline, weight: .medium))
        .foregroundStyle(isOn ? Theme.Text.primary : Theme.Text.secondary)
        .padding(.horizontal, iconOnly ? Theme.Spacing.snug : Theme.Spacing.md)
        .frame(minWidth: iconOnly ? max(height, Theme.Size.target) : nil, minHeight: height)
        .background {
          if isOn {
            LitTintBackground(
              shape: Capsule(), tint: tint, isEnabled: isEnabled, isPressed: pressed, strength: .pill)
          } else {
            QuietBackground(shape: Capsule(), isPressed: pressed)
          }
        }
        .frame(minHeight: Theme.Size.target)
        .contentShape(.rect)
        // On is said by the glyph too (filled), not by color alone.
        .symbolVariant(isOn ? .fill : .none)
        .opacity(isEnabled ? 1 : (isOn ? 0.58 : 0.42))
        .appAnimation(Theme.Motion.stateChange, value: isOn, kind: .dissolve)
        .appAnimation(Theme.Motion.press, value: pressed, kind: .dissolve)
        .appAnimation(Theme.Motion.stateChange, value: isEnabled, kind: .dissolve)
        .scaleEffect(reduceMotion || !pressed ? 1 : 0.96)
        .appAnimation(Theme.Motion.press, value: pressed)
    }
  }
}

private struct PillLabelStyle: LabelStyle {
  let iconOnly: Bool

  func makeBody(configuration: Configuration) -> some View {
    if iconOnly {
      configuration.icon
    } else {
      HStack(spacing: Theme.Spacing.tight) {
        configuration.icon
        configuration.title
      }
      .lineLimit(1)
      .fixedSize()
    }
  }
}

// MARK: - Small pieces

/// A tinted icon tile for grouped rows and cards.
struct TintTile: View {
  let symbol: String
  var tint: Color = Theme.Brand.glacier
  var size: CGFloat = Theme.Size.tile
  @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

  var body: some View {
    let side = size * min(scale, 1.5)
    Image(systemName: symbol)
      .font(.system(size: side * 0.48, weight: .semibold))
      .foregroundStyle(tint)
      .frame(width: side, height: side)
      .background {
        RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
          .fill(tint.opacity(0.12))
      }
      .overlay {
        RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
          .stroke(tint.opacity(0.18), lineWidth: Theme.Stroke.hairline)
      }
      .accessibilityHidden(true)
  }
}

/// A settings-style row label: tinted tile, title, optional value.
struct RowLabel: View {
  @Environment(\.dynamicTypeSize) private var typeSize
  let title: String
  let symbol: String
  var tint: Color = Theme.Brand.glacier
  var value: String?

  var body: some View {
    if typeSize.isAccessibilitySize {
      HStack(alignment: .top, spacing: Theme.Spacing.md) {
        TintTile(symbol: symbol, tint: tint)
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
          Text(title).foregroundStyle(Theme.Text.primary)
          if let value { Text(value).foregroundStyle(Theme.Text.tertiary) }
        }
      }
    } else {
      compact
    }
  }

  private var compact: some View {
    HStack(spacing: Theme.Spacing.md) {
      TintTile(symbol: symbol, tint: tint)
      Text(title).foregroundStyle(Theme.Text.primary).layoutPriority(1)
      if let value {
        // Fills the rest of the row, right-aligned: a Spacer would add two
        // more stack gaps and cut short values like "Wikipedia".
        Text(value)
          .foregroundStyle(Theme.Text.tertiary)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
  }
}

/// State said in words and color (never color alone).
struct StatusBadge: View {
  let text: String
  var tone: Color = Theme.Status.healthy
  @ScaledMetric(relativeTo: .caption) private var dotSize: CGFloat = Theme.Spacing.tight

  var body: some View {
    HStack(spacing: Theme.Spacing.tight) {
      Circle()
        .fill(tone)
        .frame(width: min(dotSize, Theme.Spacing.snug), height: min(dotSize, Theme.Spacing.snug))
      Text(text)
    }
    .font(.system(.caption, weight: .semibold))
    .foregroundStyle(tone)
    .lineLimit(1)
    .fixedSize()
    .padding(.horizontal, Theme.Spacing.snug)
    .padding(.vertical, Theme.Spacing.xs)
    .background { Capsule().fill(Theme.badgeSurface(tone)) }
    .overlay { Capsule().stroke(Theme.badgeStroke(tone), lineWidth: Theme.Stroke.hairline) }
  }
}

/// Ensures inline banner action buttons meet the 44 pt HIG touch target without inflating
/// actionless banners.
private struct InlineBannerActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(.horizontal, Theme.Spacing.xs)
      .frame(minHeight: Theme.Size.target)
      .contentShape(.rect)
      .opacity(configuration.isPressed ? 0.65 : 1)
  }
}

/// A quiet message above the composer (download, loading, errors, notices).
struct InlineBanner<Actions: View>: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let symbol: String
  let message: String
  var tint: Color = Theme.Brand.glacier
  var showsProgress = false
  /// Accessibility identifier of the message text (UI tests).
  var identifier: String = ""
  let actions: Actions

  init(
    symbol: String, message: String, tint: Color = Theme.Brand.glacier, showsProgress: Bool = false,
    identifier: String = "", @ViewBuilder actions: () -> Actions
  ) {
    self.symbol = symbol
    self.message = message
    self.tint = tint
    self.showsProgress = showsProgress
    self.identifier = identifier
    self.actions = actions()
  }

  var body: some View {
    HStack(spacing: Theme.Spacing.snug) {
      if showsProgress {
        ProgressView().controlSize(.small).tint(tint)
      } else {
        Image(systemName: symbol).foregroundStyle(tint)
          .accessibilityLabel(Self.severity(of: symbol) ?? "")
          .accessibilityHidden(Self.severity(of: symbol) == nil)
      }
      Text(message)
        .font(.footnote)
        .foregroundStyle(Theme.Text.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(identifier)
      actions
        .buttonStyle(InlineBannerActionButtonStyle())
        .font(.system(.footnote, weight: .semibold))
        .foregroundStyle(tint)
    }
    .padding(.horizontal, Theme.Spacing.lg)
    .padding(.vertical, Actions.self == EmptyView.self ? Theme.Spacing.md : Theme.Spacing.xs)
    .chromeSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous))
    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
  }

  /// What VoiceOver says for the banner's icon: a warning and a notice look alike otherwise.
  static func severity(of symbol: String) -> String? {
    switch symbol {
    case "exclamationmark.triangle": return String(localized: "Warning")
    case "info.circle": return String(localized: "Notice")
    default: return nil
    }
  }
}

extension InlineBanner where Actions == EmptyView {
  init(
    symbol: String, message: String, tint: Color = Theme.Brand.glacier, showsProgress: Bool = false,
    identifier: String = ""
  ) {
    self.init(
      symbol: symbol, message: message, tint: tint, showsProgress: showsProgress, identifier: identifier
    ) { EmptyView() }
  }
}

/// A one-sentence empty state with a tinted symbol.
struct EmptyStateView: View {
  let symbol: String
  let title: String
  var message: String?
  var tint: Color = Theme.Brand.glacier

  var body: some View {
    VStack(spacing: Theme.Spacing.sm) {
      Image(systemName: symbol)
        .font(.system(.title2, weight: .semibold))
        .foregroundStyle(tint)
        .accessibilityHidden(true)
      Text(title)
        .font(.headline)
        .foregroundStyle(Theme.Text.primary)
      if let message {
        Text(message)
          .font(.footnote)
          .foregroundStyle(Theme.Text.tertiary)
          .multilineTextAlignment(.center)
      }
    }
    .padding(Theme.Spacing.xxl)
    .frame(maxWidth: .infinity)
    .surfaceCard(radius: Theme.Radius.group)
  }
}

// MARK: - Screen styling

extension View {
  /// A grouped `Form` / `List` on the dark canvas: hidden system background,
  /// the backdrop glow, and faint row cards.
  func themedList(_ tint: Color = Theme.Brand.silver) -> some View {
    self
      .scrollContentBackground(.hidden)
      .ambientBackdrop(tint, intensity: .whisper)
      .foregroundStyle(Theme.Text.primary)
  }

  /// Row background for themed lists.
  func themedRow() -> some View {
    listRowBackground(Theme.Surface.group)
      .listRowSeparatorTint(Theme.Surface.hairline)
  }
}
