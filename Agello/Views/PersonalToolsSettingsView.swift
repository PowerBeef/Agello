import SwiftUI

/// Opt-in permissions for native on-device personal context tools (Calendar, Reminders,
/// Contacts, and Apple Maps). All toggles default to Off; creating events or reminders always
/// requires explicit confirmation in the chat stream before saving.
struct PersonalToolsSettingsView: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    @Bindable var appState = appState
    Form {
      Section {
        Toggle(isOn: $appState.personalTools.calendar) {
          RowLabel(
            title: String(localized: "Calendar"), symbol: "calendar",
            tint: Theme.Brand.glacier)
        }
        .accessibilityIdentifier("personalTools.calendar")

        Toggle(isOn: $appState.personalTools.reminders) {
          RowLabel(
            title: String(localized: "Reminders"), symbol: "checklist",
            tint: Theme.Brand.lavender)
        }
        .accessibilityIdentifier("personalTools.reminders")

        Toggle(isOn: $appState.personalTools.contacts) {
          RowLabel(
            title: String(localized: "Contacts"), symbol: "person.2.fill",
            tint: Theme.Brand.teal)
        }
        .accessibilityIdentifier("personalTools.contacts")

        Toggle(isOn: $appState.personalTools.maps) {
          RowLabel(
            title: String(localized: "Maps & Places"), symbol: "map.fill",
            tint: Theme.Brand.gold)
        }
        .accessibilityIdentifier("personalTools.maps")
      } header: {
        Text("Personal tools").eyebrowStyle()
      } footer: {
        Text(
          "Every personal tool runs locally on this \(Platform.deviceName) and requests system permission only when first used. Creating a calendar event or reminder always asks for your confirmation in chat before saving."
        )
        .foregroundStyle(Theme.Text.tertiary)
      }
      .themedRow()
      .disabled(!appState.enableTools)
    }
    .themedList(Theme.Brand.gold)
    .navigationTitle("Personal tools")
  }
}
