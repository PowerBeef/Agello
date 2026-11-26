import SwiftUI

/// An attached file: a tinted icon tile, the name and pages; optionally
/// removable.
struct FileChip: View {
  let name: String
  let kind: DocumentKind
  let pageCount: Int
  /// Only the file's start was read (it's longer than Agello reads).
  var cut = false
  var onRemove: (() -> Void)?
  @ScaledMetric(relativeTo: .body) private var maxChipWidth: CGFloat = 240
  @ScaledMetric(relativeTo: .caption2) private var removeBadgeSize: CGFloat = 22

  var body: some View {
    HStack(spacing: Theme.Spacing.sm) {
      TintTile(symbol: kind.symbol)
      VStack(alignment: .leading, spacing: 0) {
        Text(name)
          .font(.system(.caption, weight: .semibold))
          .foregroundStyle(Theme.Text.primary)
          .lineLimit(2)
          .truncationMode(.middle)
        if cut {
          Text(pageCount > 0 ? "First \(pageCount) pages read" : "Only its start was read")
            .font(.caption2)
            .foregroundStyle(Theme.Text.tertiary)
            .accessibilityIdentifier("message.file.cut")
        } else if pageCount > 0 {
          Text(pageCount == 1 ? "1 page" : "\(pageCount) pages")
            .font(.caption2)
            .foregroundStyle(Theme.Text.tertiary)
        }
      }
      if let onRemove {
        let badge = min(removeBadgeSize, Theme.Size.glyph)
        Button(action: onRemove) {
          Image(systemName: "xmark")
            .font(.system(.caption2, weight: .bold))
            .foregroundStyle(Theme.Text.secondary)
            .frame(width: badge, height: badge)
            .background { Circle().fill(Color.white.opacity(0.08)) }
            .frame(width: Theme.Size.target, height: Theme.Size.target)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(name)")
      }
    }
    .frame(maxWidth: min(maxChipWidth, 320), alignment: .leading)
    .padding(.leading, Theme.Spacing.sm)
    .padding(.trailing, onRemove == nil ? Theme.Spacing.md : Theme.Spacing.xs)
    .padding(.vertical, onRemove == nil ? Theme.Spacing.sm : Theme.Spacing.xs)
    .surfaceCard(radius: Theme.Radius.card, fill: Theme.Surface.stage)
    // Its own element for the Remove button, not folded into the chip's label.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("message.file")
  }
}

extension FileChip {
  init(record: FileRecord) {
    self.init(
      name: record.name, kind: DocumentKind(rawValue: record.kind) ?? .text,
      pageCount: record.pageCount, cut: record.cut ?? false)
  }
}
