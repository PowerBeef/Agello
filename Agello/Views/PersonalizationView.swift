import SwiftUI

/// About you and how Agello should respond. Saved when leaving the screen,
/// so the conversation is rebuilt once rather than on every keystroke.
struct PersonalizationView: View {
  @Environment(AppState.self) private var appState
  @State private var draft = Personalization()
  @State private var loaded = false

  var body: some View {
    Form {
      Section {
        Toggle("Use personalization", isOn: $draft.enabled)
          .accessibilityIdentifier("personalization.enabled")
      } footer: {
        Text("Shared only with the on-device model, in every new reply.")
      }
      .themedRow()

      Section("Response style") {
        Picker("Style", selection: $draft.style) {
          ForEach(Personalization.Style.allCases, id: \.self) { style in
            Text(style.displayName).tag(style)
          }
        }
        .accessibilityIdentifier("personalization.style")
      }
      .themedRow()
      .disabled(!draft.enabled)

      Section("What should Agello call you?") {
        TextField("Name", text: $draft.name)
          .textContentType(.givenName)
          .accessibilityIdentifier("personalization.name")
      }
      .themedRow()
      .disabled(!draft.enabled)

      Section {
        editor($draft.aboutYou, identifier: "personalization.about")
      } header: {
        Text("Anything else Agello should know about you?")
      } footer: {
        Text("Interests, values, what you do. \(counter(draft.aboutYou))")
      }
      .themedRow()
      .disabled(!draft.enabled)

      Section {
        editor($draft.instructions, identifier: "personalization.instructions")
      } header: {
        Text("How should Agello respond?")
      } footer: {
        Text("Language, format, tone. \(counter(draft.instructions))")
      }
      .themedRow()
      .disabled(!draft.enabled)
    }
    .themedList(Theme.Brand.glacier)
    .navigationTitle("Personalization")
    .onAppear {
      guard !loaded else { return }
      draft = appState.personalization
      loaded = true
    }
    .onDisappear(perform: save)
  }

  private func editor(_ text: Binding<String>, identifier: String) -> some View {
    TextEditor(text: text)
      .frame(minHeight: 90)
      .onChange(of: text.wrappedValue) { _, value in
        if value.count > Personalization.fieldLimit {
          text.wrappedValue = String(value.prefix(Personalization.fieldLimit))
        }
      }
      .accessibilityIdentifier(identifier)
  }

  private func counter(_ text: String) -> String {
    "\(text.count)/\(Personalization.fieldLimit)"
  }

  private func save() {
    guard loaded, draft != appState.personalization else { return }
    appState.personalization = draft
    appState.scheduleApplyOptions()
  }
}
