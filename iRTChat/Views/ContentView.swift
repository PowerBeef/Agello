import CoreSpotlight
import SwiftData
import SwiftUI

/// One chat screen with a side drawer (chats, search, settings). The chat
/// slides aside to reveal the drawer: tap the menu button or swipe from the
/// left edge; tap or swipe the chat back to close.
struct ContentView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var context
  @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]

  @State private var drawerOpen = false
  /// Live finger offset while dragging the drawer (relative to its resting place).
  @State private var dragOffset: CGFloat = 0
  @State private var dragging = false
  @State private var showSettings = false
  @State private var renaming: ChatThread?
  @State private var renameText = ""
  @State private var deleting: ChatThread?
  @State private var openProject: Project?
  @AppStorage("onboardingDone") private var onboardingDone = false
  /// Decided once at launch, so finishing the download doesn't dismiss the
  /// welcome screen before "Start chatting".
  @State private var presentOnboarding = false

  private var currentThread: ChatThread? {
    guard let id = appState.selectedThreadID else { return nil }
    return threads.first { $0.id == id }
  }

  var body: some View {
    GeometryReader { geometry in
      let width = min(geometry.size.width * 0.84, 360)
      let offset = min(max((drawerOpen ? width : 0) + dragOffset, 0), width)
      let progress = offset / width
      ZStack(alignment: .leading) {
        if progress > 0 {
          drawer
            .frame(width: width)
            .background(Color(.secondarySystemBackground).ignoresSafeArea())
            .accessibilityHidden(!drawerOpen)
        }
        // The chat lays out in the safe area; its card and dimming extend
        // edge to edge so it slides aside as one panel.
        chat
          .background {
            RoundedRectangle(cornerRadius: progress > 0 ? 44 : 0)
              .fill(Color(.systemBackground))
              .shadow(color: .black.opacity(0.12 * progress), radius: 12)
              .ignoresSafeArea()
          }
          .overlay {
            if progress > 0 {
              RoundedRectangle(cornerRadius: 44)
                .fill(Color.black.opacity(0.12 * progress))
                .ignoresSafeArea()
                .contentShape(.rect)
                .onTapGesture { setDrawer(open: false) }
                .accessibilityLabel("Close menu")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("drawer.close")
            }
          }
          .offset(x: offset)
          .accessibilityHidden(drawerOpen)
      }
      .simultaneousGesture(drawerDrag(width: width))
    }
    .onContinueUserActivity(CSSearchableItemActionType) { activity in
      if let id = SpotlightIndex.chatID(from: activity) { AppRouter.shared.handle(.openChat(id)) }
    }
    .onOpenURL { url in
      if let action = AppRouter.action(for: url) { AppRouter.shared.handle(action) }
    }
    .onChange(of: AppRouter.shared.pending, initial: true) {
      if let action = AppRouter.shared.take() { perform(action) }
    }
    .task {
      SpotlightIndex.refresh(in: context)
      appState.pruneEmptyThreads()
      presentOnboarding = OnboardingView.shouldShow(
        done: onboardingDone, isMock: appState.isMock,
        downloaded: appState.store.activeSpecDownloaded)
    }
    .onChange(of: appState.selectedThreadID) { appState.pruneEmptyThreads() }
    .sheet(isPresented: $showSettings) {
      SettingsView()
    }
    .sheet(item: $openProject) { project in
      ProjectView(
        project: project,
        onOpenChat: { thread in
          openProject = nil
          appState.newChatProjectID = nil
          appState.selectedThreadID = thread.id
          setDrawer(open: false)
        },
        onNewChat: {
          openProject = nil
          appState.selectedThreadID = nil
          appState.newChatProjectID = project.id
          setDrawer(open: false)
        },
        onDelete: { appState.deleteProject(project, in: context) })
    }
    .fullScreenCover(isPresented: $presentOnboarding, onDismiss: { onboardingDone = true }) {
      OnboardingView { presentOnboarding = false }
    }
    .alert("Rename chat", isPresented: isRenaming) {
      TextField("Title", text: $renameText)
        .submitLabel(.done)
        .onSubmit {
          commitRename()
          renaming = nil
        }
        .accessibilityIdentifier("rename.field")
      Button("Save") { commitRename() }
      Button("Cancel", role: .cancel) {}
    }
    .confirmationDialog(
      "Delete this chat?", isPresented: isDeleting, titleVisibility: .visible,
      presenting: deleting
    ) { thread in
      Button("Delete", role: .destructive) {
        appState.deleteThread(thread, in: context)
      }
    } message: { _ in
      Text("It will be removed from this iPhone.")
    }
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
            }
            .accessibilityLabel("Chats")
            .accessibilityIdentifier("chat.drawer")
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button(action: newChat) {
              Image(systemName: "square.and.pencil")
            }
            .accessibilityLabel("New chat")
            .accessibilityIdentifier("chat.new")
          }
          if let thread = currentThread {
            ToolbarItem(placement: .topBarTrailing) {
              Menu {
                Button(
                  thread.isPinned ? "Unpin" : "Pin",
                  systemImage: thread.isPinned ? "pin.slash" : "pin"
                ) {
                  togglePin(thread)
                }
                Button("Rename", systemImage: "pencil") { startRename(thread) }
                Button("Delete", systemImage: "trash", role: .destructive) { deleting = thread }
                  .disabled(appState.generatingThreadID == thread.id)
              } label: {
                Image(systemName: "ellipsis")
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
        appState.newChatProjectID = nil
        appState.selectedThreadID = thread.id
        setDrawer(open: false)
      },
      onNewChat: newChat,
      onRename: startRename,
      onTogglePin: togglePin,
      onDelete: { deleting = $0 },
      onSettings: {
        showSettings = true
      },
      onOpenProject: { openProject = $0 },
      onNewProject: {
        openProject = appState.newProject(named: String(localized: "New project"), in: context)
      },
      onMove: { thread, projectID in appState.move(thread, toProject: projectID) })
  }

  /// Carry out a request from Siri, Shortcuts, widgets, Spotlight, or a link.
  private func perform(_ action: AppRouter.Action) {
    showSettings = false
    openProject = nil
    setDrawer(open: false)
    switch action {
    case .newChat:
      newChat()
    case .voice:
      newChat()
      AppRouter.shared.voiceRequested = true
    case .openChat(let id):
      appState.newChatProjectID = nil
      if threads.contains(where: { $0.id == id }) { appState.selectedThreadID = id }
    case .ask(let question):
      guard !appState.isBusy else {
        appState.generationError = String(localized: "Finish or stop the current reply first.")
        return
      }
      newChat()
      let thread = appState.newThread(in: context)
      appState.selectedThreadID = thread.id
      Task { await appState.send(text: question, imageData: nil, audioFileURL: nil, in: thread) }
    }
  }

  private func newChat() {
    // Saved on the first message, so unused new chats never pile up.
    appState.newChatProjectID = nil
    appState.selectedThreadID = nil
    setDrawer(open: false)
  }

  private func setDrawer(open: Bool) {
    if open {
      UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
    withAnimation(.snappy(duration: 0.3)) {
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

  // MARK: - Rename / delete

  private var isRenaming: Binding<Bool> {
    Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
  }

  private var isDeleting: Binding<Bool> {
    Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
  }

  private func togglePin(_ thread: ChatThread) {
    thread.isPinned.toggle()
    try? context.save()
    Haptics.complete()
  }

  private func startRename(_ thread: ChatThread) {
    renameText = thread.title
    renaming = thread
  }

  private func commitRename() {
    let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let thread = renaming, !title.isEmpty else { return }
    thread.title = String(title.prefix(80))
    try? context.save()
  }
}

extension ModelStore {
  var activeSpecDownloaded: Bool { isDownloaded(activeSpec) }
}
