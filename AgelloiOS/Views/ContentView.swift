import SwiftData
import SwiftUI

/// One chat screen with a side drawer (chats, search, settings). The chat
/// slides aside to reveal the drawer: tap the menu button or swipe from the
/// left edge; tap or swipe the chat back to close.
struct ContentView: View {
  @Environment(AppState.self) private var appState
  @Environment(ShellModel.self) private var shell
  @Environment(\.modelContext) private var context
  @Environment(\.scenePhase) private var scenePhase

  @State private var drawerOpen = false
  /// Keeps the drawer, backdrop, and scrim mounted through the close animation, then unmounts
  /// on completion (removing `drawer.close` cleanly).
  @State private var drawerVisible = false
  @State private var drawerSearchFocused = false
  /// Non-observed bridge so `setDrawer`'s close completion can check active drags without
  /// re-evaluating `ContentView.body` on drag frames.
  @State private var dragActivity = DrawerDragActivity()
  /// Cached active thread resolved via `fetchLimit = 1` instead of a root `@Query` scan.
  @State private var cachedThread: ChatThread?
  @AppStorage("onboardingDone") private var onboardingDone = false

  private var currentThread: ChatThread? {
    guard let id = appState.selectedThreadID else { return nil }
    if let cached = cachedThread, !cached.isDeleted, cached.modelContext != nil, cached.id == id {
      return cached
    }
    return fetchThread(id: id)
  }

  private func fetchThread(id: UUID) -> ChatThread? {
    var descriptor = FetchDescriptor<ChatThread>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return try? context.fetch(descriptor).first
  }

  var body: some View {
    @Bindable var shell = shell
    DrawerSlideHost(
      drawerOpen: drawerOpen,
      drawerVisible: drawerVisible,
      drawerSearchFocused: drawerSearchFocused,
      dragActivity: dragActivity,
      onSetDrawer: setDrawer,
      onResignFirstResponder: resignFirstResponder,
      drawerContent: drawer,
      chatContent: chat
    )
    .routesExternalRequests(perform: perform)
    .onAppear {
      if let id = appState.selectedThreadID, cachedThread?.id != id {
        cachedThread = fetchThread(id: id)
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { shell.answerSharedItems() }
    }
    .task {
      AudioRecorder.removeLeftovers()
      shell.answerSharedItems()
      SpotlightIndex.refresh(in: shell.context)
      appState.pruneEmptyThreads()
      appState.knowledge.indexPendingIfAvailable()
      let hasExternalLaunch =
        AppRouter.shared.pending != nil
        || AppRouter.shared.voiceRequested
        || AppRouter.shared.voiceWithCameraRequested
        || AppRouter.shared.cameraRequested
        || AppRouter.shared.draftRequested != nil
        || appState.voiceModeActive
        || shell.hasPendingPresentation
      if !hasExternalLaunch {
        shell.presentOnboarding = OnboardingView.shouldShow(
          done: onboardingDone, isMock: !appState.requiresLocalModel,
          downloaded: appState.store.activeSpecDownloaded)
      }
    }
    .onChange(of: appState.selectedThreadID) { _, id in
      cachedThread = id.flatMap(fetchThread(id:))
      appState.pruneEmptyThreads()
    }
    // Presented screens get AppState explicitly: running on a Mac, the
    // onboarding cover didn't inherit it and the app crashed at launch.
    .sheet(isPresented: $shell.showSettings, onDismiss: { shell.handleModalDismissed() }) {
      SettingsView()
        .environment(appState)
    }
    .sheet(item: $shell.openProject, onDismiss: { shell.handleModalDismissed() }) { project in
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
    .fullScreenCover(
      isPresented: $shell.presentOnboarding,
      onDismiss: {
        onboardingDone = true
        shell.handleModalDismissed()
      }
    ) {
      OnboardingView { shell.presentOnboarding = false }
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
          if let title = currentThread?.title, !title.isEmpty {
            ToolbarItem(placement: .principal) {
              Text(title)
                .font(.headline)
                .foregroundStyle(Theme.Text.primary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            }
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
                  .disabled(
                    appState.generatingThreadID == thread.id
                      || appState.preparingThreadID == thread.id)
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
      onMove: shell.move,
      onSearchFocusChanged: { drawerSearchFocused = $0 })
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

  private func resignFirstResponder() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
  }

  private func setDrawer(open: Bool) {
    let changed = drawerOpen != open
    if changed {
      resignFirstResponder()
    }
    if open {
      drawerVisible = true
    }
    if Platform.reduceMotion {
      drawerOpen = open
      if !open && !dragActivity.isActive {
        drawerVisible = false
      }
    } else {
      withAnimation(Theme.Motion.panel) {
        drawerOpen = open
      } completion: {
        if !drawerOpen && !dragActivity.isActive {
          drawerVisible = false
        }
      }
    }
    if changed {
      // VoiceOver moves to what's now on screen.
      UIAccessibility.post(notification: .screenChanged, argument: nil)
    }
  }
}

@MainActor
private final class DrawerDragActivity {
  var isActive = false
}

/// Isolates 60–120 Hz `@GestureState` drag updates from `ContentView`, `DrawerView`, and `ChatView`
/// so dragging never reconstructs `DrawerView` closures or re-diffs the chat stream.
private struct DrawerSlideHost<DrawerContent: View, ChatContent: View>: View {
  private struct DragState: Equatable {
    var offset: CGFloat = 0
    var active = false
  }

  @Environment(\.layoutDirection) private var layoutDirection
  @GestureState private var dragState = DragState()

  let drawerOpen: Bool
  let drawerVisible: Bool
  let drawerSearchFocused: Bool
  let dragActivity: DrawerDragActivity
  let onSetDrawer: (Bool) -> Void
  let onResignFirstResponder: () -> Void
  let drawerContent: DrawerContent
  let chatContent: ChatContent

  var body: some View {
    let isRTL = layoutDirection == .rightToLeft
    GeometryReader { geometry in
      let containerWidth = max(0, geometry.size.width)
      let width = min(containerWidth * 0.84, 360)
      let offset = width > 0 ? min(max((drawerOpen ? width : 0) + dragState.offset, 0), width) : 0
      let progress: CGFloat = width > 0 ? offset / width : 0
      let visualOffset = isRTL ? -offset : offset
      let showDrawer = drawerVisible || drawerOpen || progress > 0
      let cornerRadius = showDrawer ? 44 * progress : 0
      ZStack(alignment: .leading) {
        if showDrawer {
          // Its own layer, not the drawer's background: the drawer's accessibilityHidden(false)
          // while open would expose the glow to VoiceOver.
          AmbientBackdrop(tint: Theme.Brand.glacier, intensity: .whisper)
            .frame(width: width)
          drawerContent
            .frame(width: width)
            .accessibilityHidden(!drawerOpen)
            // A named container. VoiceOver closes it with "Close menu", over the chat (an escape
            // action here made an unnamed element the size of the drawer).
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Chats")
        }
        // The chat lays out in the safe area; its card clip and floating shadow activate only
        // while the drawer is visible (zero offscreen mask or 18 pt shadow during normal streaming).
        chatContent
          .clipShape(
            DrawerCardClipShape(
              cornerRadius: cornerRadius, insets: geometry.safeAreaInsets, isRTL: isRTL)
          )
          .background {
            if showDrawer {
              RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.Surface.canvas)
                .shadow(color: Theme.Elevation.floating.opacity(progress), radius: 18, y: 14)
                .ignoresSafeArea()
            }
          }
          .offset(x: visualOffset)
          .accessibilityHidden(drawerOpen)
        // Over the chat, but not inside it: the chat is hidden from VoiceOver while the drawer is
        // open, and this was the only way back to it.
        if showDrawer {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color.black.opacity(0.18 * progress))
            .ignoresSafeArea()
            .contentShape(.rect)
            .allowsHitTesting(drawerOpen)
            .onTapGesture { onSetDrawer(false) }
            .offset(x: visualOffset)
            .accessibilityLabel("Close menu")
            .accessibilityAddTraits(.isButton)
            .accessibilityHidden(!drawerOpen)
            .accessibilityIdentifier("drawer.close")
        }
      }
      .simultaneousGesture(drawerDrag(width: width, containerWidth: containerWidth, isRTL: isRTL))
    }
    .onChange(of: dragState.active) { _, active in
      dragActivity.isActive = active
      if active { onResignFirstResponder() }
    }
  }

  private func dragStartAllowed(
    at location: CGPoint, drawerOpen: Bool, width: CGFloat, containerWidth: CGFloat, isRTL: Bool
  ) -> Bool {
    guard width > 0, containerWidth > 0 else { return false }
    if drawerOpen {
      if drawerSearchFocused {
        // While editing Drawer Search, only drag-close from the chat scrim outside the drawer.
        return isRTL ? location.x < containerWidth - width : location.x > width
      }
      // Keep the Drawer Search bar free for cursor/selection drags.
      let insideDrawer = isRTL ? location.x > containerWidth - width : location.x < width
      if insideDrawer && location.y < 140 { return false }
      return true
    }
    // Narrow leading edge (< 20 pt) so horizontal code blocks, tables, and chips scroll freely.
    return isRTL ? location.x > containerWidth - 20 : location.x < 20
  }

  /// Opens from the leading edge (mirrored for RTL so code blocks and tables still scroll
  /// sideways), closes from anywhere outside the Drawer Search field.
  private func drawerDrag(width: CGFloat, containerWidth: CGFloat, isRTL: Bool) -> some Gesture {
    DragGesture(minimumDistance: 12)
      .updating($dragState) { value, state, _ in
        let signedWidth = isRTL ? -value.translation.width : value.translation.width
        if !state.active {
          let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.5
          let correctDirection = drawerOpen ? signedWidth < 0 : signedWidth > 0
          guard horizontal, correctDirection,
            dragStartAllowed(
              at: value.startLocation, drawerOpen: drawerOpen, width: width,
              containerWidth: containerWidth, isRTL: isRTL)
          else { return }
          state.active = true
        }
        state.offset = drawerOpen ? min(0, signedWidth) : max(0, signedWidth)
      }
      .onEnded { value in
        guard width > 0,
          dragStartAllowed(
            at: value.startLocation, drawerOpen: drawerOpen, width: width,
            containerWidth: containerWidth, isRTL: isRTL)
        else { return }
        let signedWidth = isRTL ? -value.translation.width : value.translation.width
        let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.5
        let correctDirection = drawerOpen ? signedWidth < 0 : signedWidth > 0
        guard dragState.active || (horizontal && correctDirection) else { return }
        let projected = isRTL ? -value.predictedEndTranslation.width : value.predictedEndTranslation.width
        onSetDrawer(drawerOpen ? projected > -width / 3 : projected > width / 3)
      }
  }
}

/// Edge-to-edge continuous rounded clip for the chat panel while the drawer is open; collapses to
/// an unclipped bounding rect when closed so normal streaming pays zero offscreen mask passes
/// while keeping `ChatView`'s structural identity intact.
private struct DrawerCardClipShape: Shape {
  var cornerRadius: CGFloat
  var insets: EdgeInsets
  var isRTL: Bool

  var animatableData: CGFloat {
    get { cornerRadius }
    set { cornerRadius = newValue }
  }

  func path(in rect: CGRect) -> Path {
    guard cornerRadius > 0.5 else {
      return Path(rect.insetBy(dx: -1_000, dy: -1_000))
    }
    let leftInset = isRTL ? insets.trailing : insets.leading
    let rightInset = isRTL ? insets.leading : insets.trailing
    let full = CGRect(
      x: rect.minX - leftInset,
      y: rect.minY - insets.top,
      width: rect.width + leftInset + rightInset,
      height: rect.height + insets.top + insets.bottom)
    return Path(roundedRect: full, cornerRadius: cornerRadius, style: .continuous)
  }
}
