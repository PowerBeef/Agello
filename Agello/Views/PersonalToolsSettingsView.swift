import SwiftUI

/// Opt-in permissions for native on-device personal context tools (Calendar, Reminders,
/// Contacts, Maps & Places, Weather, Alarms & Timers, and Photos OCR). All toggles default
/// to Off, respect active Focus Filters, and require explicit confirmation in the chat stream
/// before executing any mutating action.
struct PersonalToolsSettingsView: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    @Bindable var appState = appState
    Form {
      if appState.focusFilter.hidePersonalTools {
        Section {
          HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "moon.fill")
              .foregroundStyle(Theme.Mode.voice.tint)
              .accessibilityHidden(true)
            Text(
              "Your current Focus hides personal tools from the assistant. Your choices below stay saved for when Focus ends."
            )
            .font(.footnote)
            .foregroundStyle(Theme.Text.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.vertical, Theme.Spacing.xxs)
          .themedRow()
          .accessibilityIdentifier("personalTools.focusBanner")
        }
      }

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

        Toggle(isOn: $appState.personalTools.weather) {
          RowLabel(
            title: String(localized: "Weather"), symbol: "cloud.sun.fill",
            tint: Theme.Brand.glacier)
        }
        .accessibilityIdentifier("personalTools.weather")

        Toggle(isOn: $appState.personalTools.alarms) {
          RowLabel(
            title: String(localized: "Alarms & Timers"), symbol: "alarm.fill",
            tint: Theme.Brand.gold)
        }
        .accessibilityIdentifier("personalTools.alarms")

        Toggle(isOn: $appState.personalTools.photos) {
          RowLabel(
            title: String(localized: "Photos (OCR)"), symbol: "photo.on.rectangle.angled",
            tint: Theme.Brand.lavender)
        }
        .accessibilityIdentifier("personalTools.photos")
      } header: {
        Text("Personal tools").eyebrowStyle()
      } footer: {
        Text(
          "Every personal tool runs locally on this \(Platform.deviceName) and requests system permission only when first used. Creating, updating, or deleting events, reminders, drafts, timers, or alarms always asks for your confirmation in chat first."
        )
        .foregroundStyle(Theme.Text.tertiary)
      }
      .tint(Theme.Mode.voice.tint)
      .themedRow()
      .disabled(!appState.enableTools)
    }
    .themedList(Theme.Brand.gold)
    .navigationTitle("Personal tools")
    .inlineTitleDisplay()
    .onChange(of: appState.personalTools) { _, _ in Haptics.selection() }
  }
}
