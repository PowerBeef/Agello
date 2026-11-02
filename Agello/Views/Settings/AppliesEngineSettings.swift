import SwiftUI

extension View {
  /// Applies engine settings as they change (debounced by ``AppState/scheduleApplyOptions()``).
  /// On the view that hosts every settings screen, so the hooks stay alive while any shows.
  func appliesEngineSettings(_ appState: AppState) -> some View {
    onChange(of: appState.options) {
      appState.scheduleApplyOptions()
    }
    .onChange(of: appState.enableTools) {
      appState.scheduleApplyOptions()
    }
  }
}
