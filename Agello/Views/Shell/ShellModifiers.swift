import CoreSpotlight
import SwiftUI

extension View {
  /// Requests from outside the app: Spotlight results, `agello://` links, and Siri, Shortcuts
  /// and widgets through ``AppRouter``, each handed to `perform` once.
  func routesExternalRequests(perform: @escaping (AppRouter.Action) -> Void) -> some View {
    onContinueUserActivity(CSSearchableItemActionType) { activity in
      if let id = SpotlightIndex.chatID(from: activity) { AppRouter.shared.handle(.openChat(id)) }
    }
    .onOpenURL { url in
      if let action = AppRouter.action(for: url) { AppRouter.shared.handle(action) }
    }
    .onChange(of: AppRouter.shared.pending, initial: true) {
      if let action = AppRouter.shared.take() { perform(action) }
    }
  }

  /// The shell's rename alert and delete confirmation.
  func shellDialogs(_ shell: ShellModel) -> some View {
    modifier(ShellDialogs(shell: shell))
  }
}

private struct ShellDialogs: ViewModifier {
  @Bindable var shell: ShellModel

  func body(content: Content) -> some View {
    content
      .alert("Rename chat", isPresented: isRenaming) {
        TextField("Title", text: $shell.renameText)
          .submitLabel(.done)
          .onSubmit {
            shell.commitRename()
            shell.renaming = nil
          }
          .accessibilityIdentifier("rename.field")
        Button("Save") { shell.commitRename() }
        Button("Cancel", role: .cancel) {}
      }
      .confirmationDialog(
        "Delete this chat?", isPresented: isDeleting, titleVisibility: .visible,
        presenting: shell.deleting
      ) { thread in
        Button("Delete", role: .destructive) {
          shell.delete(thread)
        }
      } message: { _ in
        Text("It will be removed from this \(Platform.deviceName).")
      }
  }

  private var isRenaming: Binding<Bool> {
    Binding(get: { shell.renaming != nil }, set: { if !$0 { shell.renaming = nil } })
  }

  private var isDeleting: Binding<Bool> {
    Binding(get: { shell.deleting != nil }, set: { if !$0 { shell.deleting = nil } })
  }
}
