import SwiftUI

/// The notices for the software and models Agello includes (the repository's NOTICE, bundled).
struct LicensesView: View {
  /// Bundled copy of the repository's NOTICE (`Agello/Resources/NOTICE.txt`), read on demand so
  /// ~270 KB isn't pinned permanently in static memory under the 12 GB jetsam budget.
  nonisolated static var notice: String { loadNotice() }

  /// The notice's paragraphs, split on demand for unit tests; the view loads and releases them
  /// via `@State` in `.task`.
  nonisolated static var paragraphs: [String] { splitParagraphs(loadNotice()) }

  nonisolated static func loadNotice() -> String {
    Bundle.main.url(forResource: "NOTICE", withExtension: "txt")
      .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
  }

  nonisolated static func splitParagraphs(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    return text.components(separatedBy: "\n\n")
  }

  @State private var loadedParagraphs: [String]?

  var body: some View {
    ScrollView {
      if let paragraphs = loadedParagraphs {
        LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
          Text("Open-source & model notices")
            .eyebrowStyle()
            .accessibilityAddTraits(.isHeader)
          ForEach(paragraphs.indices, id: \.self) { index in
            Text(paragraphs[index])
              .font(.footnote.monospaced())
              .foregroundStyle(Theme.Text.secondary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(Theme.Spacing.lg)
        .accessibilityIdentifier("licenses.text")
      } else {
        ProgressView()
          .frame(maxWidth: .infinity, minHeight: 160)
          .padding(Theme.Spacing.lg)
      }
    }
    .ambientBackdrop(Theme.Brand.silver, intensity: .whisper)
    .navigationTitle("Licenses")
    .inlineTitleDisplay()
    .task {
      guard loadedParagraphs == nil else { return }
      let loaded = await Task.detached(priority: .userInitiated) {
        Self.splitParagraphs(Self.loadNotice())
      }.value
      guard !Task.isCancelled else { return }
      loadedParagraphs = loaded
    }
  }
}
