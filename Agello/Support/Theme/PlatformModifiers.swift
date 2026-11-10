import SwiftUI

// Navigation and input modifiers under the names the views use. They were the one place with
// `#if os(iOS)` while Agello also had a Mac app (removed 2026-11-10); now they're plain iOS.
extension View {
  /// The title in the navigation bar, small.
  func inlineTitleDisplay() -> some View {
    navigationBarTitleDisplayMode(.inline)
  }

  /// The title large above the content.
  func largeTitleDisplay() -> some View {
    navigationBarTitleDisplayMode(.large)
  }

  /// A field for a web address: the URL keyboard, no capitals or corrections.
  func urlField() -> some View {
    keyboardType(.URL)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
  }

  /// Full screen.
  func fullScreenOrSheet<Item: Identifiable, Content: View>(
    item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    fullScreenCover(item: item, content: content)
  }
}
