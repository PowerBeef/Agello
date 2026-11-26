import SwiftUI

private struct EngineSettingsSnapshot: Equatable {
  var enableTools: Bool
  var personalTools: PersonalToolsSettings
  var webInfo: SystemPrompt.CurrentInfo
  var personalization: Personalization
  var automationRegistryVersion: Int

  @MainActor
  init(_ appState: AppState) {
    enableTools = appState.enableTools
    personalTools = appState.personalTools
    webInfo = SystemPrompt.CurrentInfo(webSettings: appState.webSettings)
    personalization = appState.personalization
    automationRegistryVersion = appState.automationRegistryVersion
  }
}

private struct AppliesEngineSettingsModifier: ViewModifier {
  let appState: AppState
  @State private var baseline: EngineSettingsSnapshot?
  @State private var settingsDirty = false

  private var current: EngineSettingsSnapshot {
    EngineSettingsSnapshot(appState)
  }

  func body(content: Content) -> some View {
    content
      .onAppear {
        if baseline == nil { baseline = current }
      }
      .onChange(of: current) { _, updated in
        markDirtyIfNeeded(updated)
      }
      .onDisappear {
        applyEngineSettingsIfNeeded()
      }
  }

  private func markDirtyIfNeeded(_ updated: EngineSettingsSnapshot) {
    settingsDirty = baseline.map { $0 != updated } ?? true
    // Defer GPU reseed until the Settings sheet dismisses so toggles never stall mid-navigation.
    appState.applyOptionsTask?.cancel()
    appState.applyOptionsTask = nil
  }

  private func applyEngineSettingsIfNeeded() {
    let changed = settingsDirty || (baseline.map { $0 != current } ?? false)
    settingsDirty = false
    baseline = nil
    guard changed else { return }
    appState.scheduleApplyOptions()
  }
}

extension View {
  /// Marks engine-relevant settings dirty while Settings is open and defers GPU conversation
  /// reseed until the Settings sheet dismisses. Attach to the Settings root `NavigationStack` so
  /// child pushes do not trigger premature dismissal applies.
  func appliesEngineSettings(_ appState: AppState) -> some View {
    modifier(AppliesEngineSettingsModifier(appState: appState))
  }
}
