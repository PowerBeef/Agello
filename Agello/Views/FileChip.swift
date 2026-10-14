import SwiftUI

/// An attached file: a tinted icon tile, the name and pages; optionally
/// removable.
struct FileChip: View {
  let name: String
  let kind: DocumentKind
  let pageCount: Int
  var onRemove: (() -> Void)?

  var body: some View {
    HStack(spacing: Theme.Spacing.sm) {
      TintTile(symbol: kind.symbol)
      VStack(alignment: .leading, spacing: 0) {
        Text(name)
          .font(.system(.caption, weight: .semibold))
          .foregroundStyle(Theme.Text.primary)
          .lineLimit(1)
        if pageCount > 0 {
          Text(pageCount == 1 ? "1 page" : "\(pageCount) pages")
            .font(.caption2)
            .foregroundStyle(Theme.Text.tertiary)
        }
      }
      if let onRemove {
        Button(action: onRemove) {
          Image(systemName: "xmark")
            .font(.system(.caption2, weight: .bold))
            .foregroundStyle(Theme.Text.secondary)
            .frame(width: 22, height: 22)
            .background { Circle().fill(Color.white.opacity(0.08)) }
            .frame(width: Theme.Size.glyph, height: Theme.Size.glyph)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(name)")
      }
    }
    .frame(maxWidth: 240, alignment: .leading)
    .padding(.leading, Theme.Spacing.sm)
    .padding(.trailing, onRemove == nil ? Theme.Spacing.md : Theme.Spacing.xs)
    .padding(.vertical, Theme.Spacing.sm)
    .surfaceCard(radius: Theme.Radius.card, fill: Theme.Surface.stage)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("message.file")
  }
}

extension FileChip {
  init(record: FileRecord) {
    self.init(
      name: record.name, kind: DocumentKind(rawValue: record.kind) ?? .text,
      pageCount: record.pageCount)
  }
}
