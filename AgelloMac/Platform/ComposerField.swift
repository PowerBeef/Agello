import SwiftUI

/// The composer's message field: for now the iPhone's growing text field; M4 brings a desktop
/// editor where Return sends (docs/MAC.md).
struct ComposerField: View {
  @Binding var text: String
  var focus: FocusState<Bool>.Binding

  var body: some View {
    TextField(
      "Ask anything", text: $text,
      prompt: Text("Ask anything").foregroundStyle(Theme.Text.placeholder), axis: .vertical
    )
    .font(.body)
    .foregroundStyle(Theme.Text.primary)
    .lineLimit(1...8)
    .textFieldStyle(.plain)
    .focused(focus)
  }
}
