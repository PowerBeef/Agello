import SwiftUI

// MARK: - Buttons

/// The primary action: a full-width (or hugging) lit-tint capsule with an
/// off-white label. One per screen.
struct LitButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  var tint: Color = Theme.Mode.chat.tint
  var fullWidth = true
  @ScaledMetric(relativeTo: .headline) private var height: CGFloat = 52

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .tracking(-0.17)
      .foregroundStyle(isEnabled ? Theme.Text.primary : Theme.Text.secondary)
      .symbolRenderingMode(.hierarchical)
      .padding(.horizontal, fullWidth ? 0 : Theme.Spacing.xxl)
      .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: height)
      .background { LitTintBackground(shape: Capsule(), tint: tint, isEnabled: isEnabled) }
      .contentShape(Capsule())
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .animation(Theme.Motion.press, value: configuration.isPressed)
  }
}

/// The composer's send / voice / stop button: a lit-tint circle with an
/// off-white glyph (never accent on accent).
struct LitCircleButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  var tint: Color
  var size: CGFloat = Theme.Size.target

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size > Theme.Size.target ? .title3 : .body, weight: .semibold))
      .foregroundStyle(isEnabled ? Theme.Text.primary : Theme.Text.tertiary)
      .frame(width: size, height: size)
      .background { LitTintBackground(shape: Circle(), tint: tint, isEnabled: isEnabled) }
      .contentShape(Circle())
      .scaleEffect(configuration.isPressed ? 0.94 : 1)
      .animation(Theme.Motion.press, value: configuration.isPressed)
  }
}

/// Secondary round controls (attach, mic, close): quiet fill and hairline,
/// 44 pt target.
struct QuietCircleButtonStyle: ButtonStyle {
  var size: CGFloat = Theme.Size.target
  var tint: Color = Theme.Text.primary

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(.body, weight: .medium))
      .foregroundStyle(tint)
      .frame(width: size, height: size)
      .background { QuietBackground(shape: Circle(), isPressed: configuration.isPressed) }
      .contentShape(Circle())
      .frame(minWidth: Theme.Size.target, minHeight: Theme.Size.target)
      .animation(Theme.Motion.press, value: configuration.isPressed)
  }
}

/// Secondary capsule buttons (Pause, Cancel, Delete): quiet fill and
/// hairline; the label carries the color.
struct QuietCapsuleButtonStyle: ButtonStyle {
  var tint: Color = Theme.Text.primary
  @ScaledMetric(relativeTo: .footnote) private var height: CGFloat = Theme.Size.pill

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(.footnote, weight: .semibold))
      .foregroundStyle(tint)
      .padding(.horizontal, Theme.Spacing.lg)
      .frame(minHeight: height)
      .background { QuietBackground(shape: Capsule(), isPressed: configuration.isPressed) }
      .contentShape(Capsule())
      .frame(minHeight: Theme.Size.target)
      .animation(Theme.Motion.press, value: configuration.isPressed)
  }
}

/// A mode toggle (Think, Search): quiet when off, lit in its mode color when
/// on. The title never truncates; `iconOnly` is the compact fallback.
struct ModePillStyle: ButtonStyle {
  let isOn: Bool
  let tint: Color
  var iconOnly = false
  @ScaledMetric(relativeTo: .subheadline) private var height: CGFloat = Theme.Size.pill

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .labelStyle(PillLabelStyle(iconOnly: iconOnly))
      .font(.system(.subheadline, weight: .medium))
      .foregroundStyle(isOn ? Theme.Text.primary : Theme.Text.secondary)
      .padding(.horizontal, iconOnly ? Theme.Spacing.snug : Theme.Spacing.md)
      .frame(minWidth: iconOnly ? max(height, Theme.Size.target) : nil, minHeight: height)
      .background {
        if isOn {
          LitTintBackground(shape: Capsule(), tint: tint, strength: .pill)
        } else {
          QuietBackground(shape: Capsule(), isPressed: configuration.isPressed)
        }
      }
      .contentShape(Capsule())
      .frame(minHeight: Theme.Size.target)
      .animation(Theme.Motion.stateChange, value: isOn)
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
    let side = size * scale
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
  let title: String
  let symbol: String
  var tint: Color = Theme.Brand.glacier
  var value: String?

  var body: some View {
    HStack(spacing: Theme.Spacing.md) {
      TintTile(symbol: symbol, tint: tint)
      Text(title).foregroundStyle(Theme.Text.primary)
      if let value {
        Spacer(minLength: Theme.Spacing.sm)
        Text(value).foregroundStyle(Theme.Text.tertiary).lineLimit(1)
      }
    }
  }
}

/// State said in words and color (never color alone).
struct StatusBadge: View {
  let text: String
  var tone: Color = Theme.Status.healthy

  var body: some View {
    HStack(spacing: Theme.Spacing.tight) {
      Circle().fill(tone).frame(width: 6, height: 6)
      Text(text)
    }
    .font(.system(.caption, weight: .semibold))
    .foregroundStyle(tone)
    .padding(.horizontal, Theme.Spacing.snug)
    .padding(.vertical, Theme.Spacing.xs)
    .background { Capsule().fill(tone.opacity(0.16)) }
    .overlay { Capsule().stroke(tone.opacity(0.30), lineWidth: Theme.Stroke.hairline) }
  }
}

/// A quiet message above the composer (download, loading, errors, notices).
struct InlineBanner<Actions: View>: View {
  let symbol: String
  let message: String
  var tint: Color = Theme.Brand.glacier
  var showsProgress = false
  /// Accessibility identifier of the message text (UI tests).
  var identifier: String = ""
  @ViewBuilder var actions: Actions

  var body: some View {
    HStack(spacing: Theme.Spacing.snug) {
      if showsProgress {
        ProgressView().controlSize(.small).tint(tint)
      } else {
        Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
      }
      Text(message)
        .font(.footnote)
        .foregroundStyle(Theme.Text.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(identifier)
      actions
        .buttonStyle(.plain)
        .font(.system(.footnote, weight: .semibold))
        .foregroundStyle(tint)
    }
    .padding(.horizontal, Theme.Spacing.lg)
    .padding(.vertical, Theme.Spacing.md)
    .chromeSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous))
    .transition(.move(edge: .top).combined(with: .opacity))
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
