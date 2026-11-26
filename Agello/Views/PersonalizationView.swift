import SwiftUI

/// About you and how Agello should respond. Saved when leaving the screen,
/// so the conversation is rebuilt once rather than on every keystroke.
struct PersonalizationView: View {
  private enum Field { case name, aboutYou, instructions }
  private static let nameLimit = 80

  @Environment(AppState.self) private var appState
  @Environment(\.scenePhase) private var scenePhase
  @State private var draft = Personalization()
  @State private var loaded = false
  @FocusState private var focusedField: Field?

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

      Section {
        TextField("Name", text: $draft.name)
          .textContentType(.givenName)
          .focused($focusedField, equals: .name)
          .onChange(of: draft.name) { _, value in
            if value.count > Self.nameLimit {
              draft.name = String(value.prefix(Self.nameLimit))
            }
          }
          .accessibilityIdentifier("personalization.name")
      } header: {
        Text("What should Agello call you?")
      } footer: {
        if !draft.name.isEmpty {
          Text("\(draft.name.count)/\(Self.nameLimit)")
        }
      }
      .themedRow()
      .disabled(!draft.enabled)

      Section {
        editor(
          $draft.aboutYou, label: "About you", field: .aboutYou,
          identifier: "personalization.about")
      } header: {
        Text("Anything else Agello should know about you?")
      } footer: {
        Text("Interests, values, what you do. \(counter(draft.aboutYou))")
      }
      .themedRow()
      .disabled(!draft.enabled)

      Section {
        editor(
          $draft.instructions, label: "How Agello should respond", field: .instructions,
          identifier: "personalization.instructions")
      } header: {
        Text("How should Agello respond?")
      } footer: {
        Text("Language, format, tone. \(counter(draft.instructions))")
      }
      .themedRow()
      .disabled(!draft.enabled)
    }
    .scrollDismissesKeyboard(.interactively)
    .themedList(Theme.Brand.glacier)
    .navigationTitle("Personalization")
    .toolbar {
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") { focusedField = nil }
      }
    }
    .onAppear {
      guard !loaded else { return }
      draft = appState.personalization
      loaded = true
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .background { save() }
    }
    .onDisappear(perform: save)
  }

  private func editor(
    _ text: Binding<String>, label: LocalizedStringKey, field: Field, identifier: String
  ) -> some View {
    TextEditor(text: text)
      .scrollContentBackground(.hidden)
      .foregroundStyle(Theme.Text.primary)
      .focused($focusedField, equals: field)
      .accessibilityLabel(label)
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
