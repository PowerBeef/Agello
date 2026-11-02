import SwiftData
import SwiftUI

/// The Mac's first shell (M2): the iPhone's chat list as a sidebar beside the chat, driven by
/// the shared ``ShellModel``. M4 turns it into the desktop shell one screen at a time
/// (docs/MAC.md).
struct MacRootView: View {
  @Environment(AppState.self) private var appState
  @Environment(ShellModel.self) private var shell
  @Environment(\.scenePhase) private var scenePhase
  @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]
  @AppStorage("onboardingDone") private var onboardingDone = false
  /// Decided once at launch, as on iPhone.
  @State private var presentOnboarding = false

  /// Vocello's minimum window, the smallest its screens were checked at.
  private static let minimumSize = CGSize(width: 780, height: 560)

  private var currentThread: ChatThread? {
    guard let id = appState.selectedThreadID else { return nil }
    return threads.first { $0.id == id }
  }

  var body: some View {
    @Bindable var shell = shell
    NavigationSplitView {
      DrawerView(
        onSelect: shell.select,
        onNewChat: shell.newChat,
        onRename: shell.startRename,
        onTogglePin: shell.togglePin,
        onDelete: { shell.deleting = $0 },
        onSettings: { shell.showSettings = true },
        onOpenProject: { shell.openProject = $0 },
        onNewProject: shell.newProject,
        onMove: shell.move)
    } detail: {
      NavigationStack {
        ChatView(thread: currentThread)
          .toolbar {
            ToolbarItem(placement: .primaryAction) {
              Button("New chat", systemImage: "square.and.pencil", action: shell.newChat)
                .accessibilityIdentifier("chat.new")
            }
          }
      }
    }
    .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
    .routesExternalRequests(perform: shell.perform)
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { shell.answerSharedItems() }
    }
    .task {
      AudioRecorder.removeLeftovers()
      shell.answerSharedItems()
      SpotlightIndex.refresh(in: shell.context)
      appState.pruneEmptyThreads()
      appState.knowledge.indexPendingIfAvailable()
      presentOnboarding = OnboardingView.shouldShow(
        done: onboardingDone, isMock: appState.isMock,
        downloaded: appState.store.activeSpecDownloaded)
    }
    .onChange(of: appState.selectedThreadID) { appState.pruneEmptyThreads() }
    .sheet(isPresented: $shell.showSettings) {
      SettingsView()
        .environment(appState)
    }
    .sheet(item: $shell.openProject) { project in
      ProjectView(
        project: project,
        onOpenChat: shell.openChat(fromProject:),
        onNewChat: { shell.newChat(in: project) },
        onDelete: { shell.delete(project) }
      )
      .environment(appState)
    }
    .sheet(isPresented: $presentOnboarding, onDismiss: { onboardingDone = true }) {
      OnboardingView { presentOnboarding = false }
        .environment(appState)
    }
    .shellDialogs(shell)
  }
}
