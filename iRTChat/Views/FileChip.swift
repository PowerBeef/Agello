import SwiftUI

/// An attached file: icon, name, and pages; optionally removable.
struct FileChip: View {
  let name: String
  let kind: DocumentKind
  let pageCount: Int
  var onRemove: (() -> Void)?

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: kind.symbol)
        .font(.callout)
        .foregroundStyle(Color.accentColor)
      VStack(alignment: .leading, spacing: 0) {
        Text(name)
          .font(.caption.weight(.medium))
          .lineLimit(1)
        if pageCount > 0 {
          Text(pageCount == 1 ? "1 page" : "\(pageCount) pages")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      if let onRemove {
        Button(action: onRemove) {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(name)")
      }
    }
    .frame(maxWidth: 220, alignment: .leading)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusInner))
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
