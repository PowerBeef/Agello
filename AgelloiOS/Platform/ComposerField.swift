import SwiftUI

/// The composer's message field: on iPhone, a text field that grows to eight lines.
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
