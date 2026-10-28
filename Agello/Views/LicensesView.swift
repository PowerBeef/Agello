import SwiftUI

/// The notices for the software and models Agello includes (the repository's NOTICE, bundled).
struct LicensesView: View {
  /// Bundled copy of the repository's NOTICE (`Agello/Resources/NOTICE.txt`).
  static let notice: String = {
    Bundle.main.url(forResource: "NOTICE", withExtension: "txt")
      .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
  }()

  /// The notice's paragraphs. With the runtime's license texts it runs to about 2,600 lines, too
  /// long to lay out as one `Text`, so the list builds only the paragraphs on screen.
  static let paragraphs: [String] = notice.components(separatedBy: "\n\n")

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
        ForEach(Self.paragraphs.indices, id: \.self) { index in
          Text(Self.paragraphs[index])
            .font(.footnote.monospaced())
            .foregroundStyle(Theme.Text.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(Theme.Spacing.lg)
      .accessibilityIdentifier("licenses.text")
    }
    .ambientBackdrop(Theme.Brand.silver, intensity: .whisper)
    .navigationTitle("Licenses")
    .navigationBarTitleDisplayMode(.inline)
  }
}
