import SwiftUI

// Modifiers that only iOS has, and what the Mac does instead. The one shared file with
// `#if os(iOS)`: views call these and stay the same on both platforms.
extension View {
  /// The title in the navigation bar, small (iPhone); the Mac shows titles its own way.
  func inlineTitleDisplay() -> some View {
    #if os(iOS)
      navigationBarTitleDisplayMode(.inline)
    #else
      self
    #endif
  }

  /// The title large above the content (iPhone).
  func largeTitleDisplay() -> some View {
    #if os(iOS)
      navigationBarTitleDisplayMode(.large)
    #else
      self
    #endif
  }

  /// A field for a web address: the URL keyboard, no capitals or corrections.
  func urlField() -> some View {
    #if os(iOS)
      keyboardType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    #else
      autocorrectionDisabled()
    #endif
  }

  /// Full screen on iPhone; a sheet in the window on the Mac.
  func fullScreenOrSheet<Item: Identifiable, Content: View>(
    item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    #if os(iOS)
      fullScreenCover(item: item, content: content)
    #else
      sheet(item: item, content: content)
    #endif
  }
}
