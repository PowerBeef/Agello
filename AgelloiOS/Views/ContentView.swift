import SwiftData
import SwiftUI

/// One chat screen with a side drawer (chats, search, settings). The chat
/// slides aside to reveal the drawer: tap the menu button or swipe from the
/// left edge; tap or swipe the chat back to close.
struct ContentView: View {
  @Environment(AppState.self) private var appState
  @Environment(ShellModel.self) private var shell
  @Environment(\.scenePhase) private var scenePhase
  @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]

  @State private var drawerOpen = false
  /// Live finger offset while dragging the drawer (relative to its resting place).
  @State private var dragOffset: CGFloat = 0
  @State private var dragging = false
  @AppStorage("onboardingDone") private var onboardingDone = false
  /// Decided once at launch, so finishing the download doesn't dismiss the
  /// welcome screen before "Start chatting".
  @State private var presentOnboarding = false

  private var currentThread: ChatThread? {
    guard let id = appState.selectedThreadID else { return nil }
    return threads.first { $0.id == id }
  }

  var body: some View {
    @Bindable var shell = shell
    GeometryReader { geometry in
      let width = min(geometry.size.width * 0.84, 360)
      let offset = min(max((drawerOpen ? width : 0) + dragOffset, 0), width)
      let progress = offset / width
      ZStack(alignment: .leading) {
        if progress > 0 {
          // Its own layer, not the drawer's background: the drawer's accessibilityHidden(false)
          // while open would expose the glow to VoiceOver.
          AmbientBackdrop(tint: Theme.Brand.glacier, intensity: .whisper)
            .frame(width: width)
          drawer
            .frame(width: width)
            .accessibilityHidden(!drawerOpen)
            // A named container. VoiceOver closes it with "Close menu", over the chat (an escape
            // action here made an unnamed element the size of the drawer).
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Chats")
        }
        // The chat lays out in the safe area; its card and dimming extend
        // edge to edge so it slides aside as one panel.
        chat
          // The chat slides aside as one rounded card, backdrop included.
          .mask {
            RoundedRectangle(cornerRadius: progress > 0 ? 44 : 0, style: .continuous)
              .ignoresSafeArea()
          }
          .background {
            RoundedRectangle(cornerRadius: progress > 0 ? 44 : 0, style: .continuous)
              .fill(Theme.Surface.canvas)
              .shadow(color: Theme.Elevation.floating.opacity(progress), radius: 18, y: 14)
              .ignoresSafeArea()
          }
          .offset(x: offset)
          .accessibilityHidden(drawerOpen)
        // Over the chat, but not inside it: the chat is hidden from VoiceOver while the drawer is
        // open, and this was the only way back to it.
        if progress > 0 {
          RoundedRectangle(cornerRadius: 44, style: .continuous)
            .fill(Color.black.opacity(0.18 * progress))
            .ignoresSafeArea()
            .contentShape(.rect)
            .onTapGesture { setDrawer(open: false) }
            .offset(x: offset)
            .accessibilityLabel("Close menu")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("drawer.close")
        }
      }
      .simultaneousGesture(drawerDrag(width: width))
    }
    .routesExternalRequests(perform: perform)
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
    // Presented screens get AppState explicitly: running on a Mac, the
    // onboarding cover didn't inherit it and the app crashed at launch.
    .sheet(isPresented: $shell.showSettings) {
      SettingsView()
        .environment(appState)
    }
    .sheet(item: $shell.openProject) { project in
      ProjectView(
        project: project,
        onOpenChat: { thread in
          shell.openChat(fromProject: thread)
          setDrawer(open: false)
        },
        onNewChat: {
          shell.newChat(in: project)
          setDrawer(open: false)
        },
        onDelete: { shell.delete(project) }
      )
      .environment(appState)
    }
    .fullScreenCover(isPresented: $presentOnboarding, onDismiss: { onboardingDone = true }) {
      OnboardingView { presentOnboarding = false }
        .environment(appState)
    }
    .shellDialogs(shell)
  }

  // MARK: - Chat

  private var chat: some View {
    NavigationStack {
      ChatView(thread: currentThread)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              setDrawer(open: true)
            } label: {
              Image(systemName: "line.3.horizontal")
                .foregroundStyle(Theme.Text.primary)
            }
            .accessibilityLabel("Chats")
            .accessibilityIdentifier("chat.drawer")
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button(action: newChat) {
              Image(systemName: "square.and.pencil")
                .foregroundStyle(Theme.Text.primary)
            }
            .accessibilityLabel("New chat")
            .accessibilityIdentifier("chat.new")
          }
          ToolbarItem(placement: .principal) {
            Text(currentThread?.title ?? "")
              .font(.headline)
              .foregroundStyle(Theme.Text.primary)
              .lineLimit(1)
              .accessibilityAddTraits(.isHeader)
          }
          if let thread = currentThread {
            ToolbarItem(placement: .topBarTrailing) {
              Menu {
                Button(
                  thread.isPinned ? "Unpin" : "Pin",
                  systemImage: thread.isPinned ? "pin.slash" : "pin"
                ) {
                  shell.togglePin(thread)
                }
                Button("Rename", systemImage: "pencil") { shell.startRename(thread) }
                Button("Delete", systemImage: "trash", role: .destructive) { shell.deleting = thread }
                  .disabled(appState.generatingThreadID == thread.id)
              } label: {
                Image(systemName: "ellipsis")
                  .foregroundStyle(Theme.Text.primary)
              }
              .accessibilityLabel("Chat options")
              .accessibilityIdentifier("chat.menu")
            }
          }
        }
    }
  }

  // MARK: - Drawer

  private var drawer: some View {
    DrawerView(
      onSelect: { thread in
        shell.select(thread)
        setDrawer(open: false)
      },
      onNewChat: newChat,
      onRename: shell.startRename,
      onTogglePin: shell.togglePin,
      onDelete: { shell.deleting = $0 },
      onSettings: {
        shell.showSettings = true
      },
      onOpenProject: { shell.openProject = $0 },
      onNewProject: shell.newProject,
      onMove: shell.move)
  }

  /// Carry out a request from Siri, Shortcuts, widgets, Spotlight, or a link, with the drawer
  /// closed.
  private func perform(_ action: AppRouter.Action) {
    setDrawer(open: false)
    shell.perform(action)
  }

  private func newChat() {
    shell.newChat()
    setDrawer(open: false)
  }

  private func setDrawer(open: Bool) {
    if open {
      UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    // VoiceOver moves to what's now on screen.
    defer { UIAccessibility.post(notification: .screenChanged, argument: nil) }
    withAppAnimation(Theme.Motion.panel) {
      drawerOpen = open
      dragOffset = 0
    }
  }

  /// Opens from the left edge (so code blocks and tables still scroll
  /// sideways), closes from anywhere.
  private func drawerDrag(width: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 12)
      .onChanged { value in
        if !dragging {
          let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.5
          guard horizontal, drawerOpen || value.startLocation.x < 28 else { return }
          dragging = true
        }
        dragOffset = drawerOpen ? min(0, value.translation.width) : max(0, value.translation.width)
      }
      .onEnded { value in
        guard dragging else { return }
        dragging = false
        let projected = value.predictedEndTranslation.width
        setDrawer(open: drawerOpen ? projected > -width / 3 : projected > width / 3)
      }
  }

}

extension ModelStore {
  var activeSpecDownloaded: Bool { isDownloaded(activeSpec) }
}
