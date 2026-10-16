import SwiftUI

/// The notices for the software and models Agello includes (the repository's NOTICE, bundled).
struct LicensesView: View {
  /// Bundled copy of the repository's NOTICE (`Agello/Resources/NOTICE.txt`).
  static let notice: String = {
    Bundle.main.url(forResource: "NOTICE", withExtension: "txt")
      .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
  }()

  var body: some View {
    ScrollView {
      Text(Self.notice)
        .font(.footnote.monospaced())
        .foregroundStyle(Theme.Text.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.lg)
        .accessibilityIdentifier("licenses.text")
    }
    .ambientBackdrop(Theme.Brand.silver, intensity: .whisper)
    .navigationTitle("Licenses")
    .navigationBarTitleDisplayMode(.inline)
  }
}
