import SwiftData
import SwiftUI

/// A conversation, or a new chat (`thread == nil`) that is saved when its first message is sent.
///
/// Composer draft, attachments, dictation, recording, and focus live inside ``ChatComposerView``
/// so keystrokes never trigger layout or diffing of the message list here.
struct ChatView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var context
  let thread: ChatThread?

  @State private var showLibrary = false
  @State private var composerBridge = ComposerBridge()
  /// Voice mode while open, made once per opening: built in the cover's closure, a new session
  /// (audio engine, speech synthesizer, camera session) was made and thrown away at every update
  /// of this view. The cover follows it (`item:`), so it never opens without its session.
  @State private var voiceSession: VoiceSession?
  @State private var reader = SpeechReader()
  /// The developer screen's "Show performance details": time to first token, speed, backend.
  @AppStorage("showPerformanceDetails") private var showStats = false

  var body: some View {
    ChatMessagesList(
      thread: thread,
      composerBridge: composerBridge,
      reader: reader,
      showStats: showStats)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .safeAreaBar(edge: .top, spacing: 0) {
        ChatBannersView(threadID: thread?.id, showLibrary: $showLibrary)
      }
      .safeAreaBar(edge: .bottom, spacing: 0) {
        // Composer rows keep their full height; the messages area above dissolves cleanly
        // beneath the Liquid Glass chrome via safeAreaBar + scrollEdgeEffectStyle.
        ChatComposerView(
          thread: thread,
          bridge: composerBridge,
          onStopReading: { reader.stop() },
          onOpenVoice: { openVoiceMode(startWithCamera: false) },
          makeThread: newThread
        )
      }
      .background {
        ChatBackdropView(bridge: composerBridge)
      }
      .background {
        ChatKeyboardShortcuts {
          AppRouter.shared.handle(.newChat)
        }
      }
      .inlineTitleDisplay()
      .sheet(isPresented: $showLibrary) {
        NavigationStack {
          ModelLibraryView()
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button(role: .close) { showLibrary = false }
              }
            }
        }
        .environment(appState)
      }
      .fullScreenCover(item: $voiceSession) { session in
        VoiceModeView(session: session)
      }
    .onChange(of: AppRouter.shared.voiceRequested, initial: true) { _, requested in
      guard requested else { return }
      AppRouter.shared.voiceRequested = false
      openVoiceMode(startWithCamera: false)
    }
    .onChange(of: AppRouter.shared.voiceWithCameraRequested, initial: true) { _, requested in
      guard requested else { return }
      AppRouter.shared.voiceWithCameraRequested = false
      openVoiceMode(startWithCamera: true)
    }
    .task(id: thread?.id) {
      if let thread {
        await appState.activate(thread)
      } else if !appState.requiresLocalModel || appState.store.activeSpecDownloaded {
        // Warm the model up while the first message is typed.
        await appState.ensureEngineLoaded()
      }
    }
    .onChange(of: thread?.id) { old, _ in
      guard old != nil else { return }
      reader.stop()
    }
    .onDisappear {
      reader.stop()
    }
  }

  private func openVoiceMode(startWithCamera: Bool) {
    reader.stop()
    composerBridge.send(.cancelDictation)
    voiceSession?.end()
    voiceSession = VoiceSession(
      appState: appState, thread: thread, startWithCamera: startWithCamera, makeThread: newThread)
  }

  /// A new chat, in the project it was started from (if any).
  private func newThread() -> ChatThread {
    let thread = appState.newThread(in: context)
    if let projectID = appState.newChatProjectID {
      thread.projectID = projectID
      try? context.save()
    }
    return thread
  }
}

/// Isolated ambient backdrop observing only mode toggles so switching Think/Search never
/// invalidates the chat message list.
private struct ChatBackdropView: View {
  @Environment(AppState.self) private var appState
  let bridge: ComposerBridge

  private var mode: Theme.Mode {
    bridge.searchWeb ? .search : appState.options.enableThinking ? .think : .chat
  }

  var body: some View {
    AmbientBackdrop(tint: mode.tint)
      .appAnimation(Theme.Motion.modeCrossfade, value: mode, kind: .dissolve)
  }
}

/// Hardware keyboard shortcuts scoped to the chat screen: `⌘N` opens a new chat, and `⌘.` / `Esc`
/// stop active generation without subscribing `ChatView.body` to `appState.isBusy`.
private struct ChatKeyboardShortcuts: View {
  @Environment(AppState.self) private var appState
  let onNewChat: () -> Void

  var body: some View {
    ZStack {
      Button("New chat", action: onNewChat)
        .keyboardShortcut("n", modifiers: .command)
      if appState.isBusy {
        Button("Stop generating") {
          Haptics.selection()
          appState.stop()
        }
        .keyboardShortcut(".", modifiers: .command)
        Button("Stop generating") {
          Haptics.selection()
          appState.stop()
        }
        .keyboardShortcut(.escape, modifiers: [])
      }
    }
    .frame(width: 0, height: 0)
    .hidden()
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

/// Isolated banner stack observing engine/notice/error/confirmation state without invalidating
/// the message list below it.
private struct ChatBannersView: View {
  private struct BannerState: Equatable {
    var engineState: ChatEngineState
    var needsDownload: Bool
    var pendingShortcutName: String?
    var generationError: String?
    var notice: String?
    var pendingConfirmationID: UUID?
  }

  @Environment(AppState.self) private var appState
  let threadID: UUID?
  @Binding var showLibrary: Bool

  static func hasBanners(appState: AppState, threadID: UUID?) -> Bool {
    let hasEngineBanner: Bool = switch appState.engineState {
    case .idle:
      appState.requiresLocalModel && !appState.store.isDownloaded(appState.store.activeSpec)
    case .loading, .failed:
      true
    case .ready, .generating:
      false
    }
    if hasEngineBanner { return true }
    if appState.pendingToolConfirmation != nil,
      let ownerID = appState.generatingThreadID ?? appState.pendingToolConfirmationThreadID,
      threadID != ownerID
    {
      return true
    }
    return appState.pendingShortcutReturnName != nil
      || appState.generationError != nil
      || appState.notice != nil
  }

  private var bannerState: BannerState {
    let otherThreadConfirmationID: UUID? = {
      guard let confirmation = appState.pendingToolConfirmation,
        let ownerID = appState.generatingThreadID ?? appState.pendingToolConfirmationThreadID,
        threadID != ownerID
      else { return nil }
      return confirmation.id
    }()
    return BannerState(
      engineState: appState.engineState,
      needsDownload: appState.requiresLocalModel
        && !appState.store.isDownloaded(appState.store.activeSpec),
      pendingShortcutName: appState.pendingShortcutReturnName,
      generationError: appState.generationError,
      notice: appState.notice,
      pendingConfirmationID: otherThreadConfirmationID)
  }

  var body: some View {
    GlassEffectContainer(spacing: Theme.Spacing.sm) {
      VStack(spacing: 0) {
        engineBanner
        pendingConfirmationBanner
        noticeBanner
      }
    }
    .appAnimation(Theme.Motion.panel, value: bannerState)
    // The banner appears without moving VoiceOver's focus: say it.
    .onChange(of: appState.generationError) { _, message in
      if let message { Haptics.announce(message) }
    }
    .onChange(of: appState.notice) { _, message in
      if let message { Haptics.announce(message) }
    }
  }

  @ViewBuilder
  private var engineBanner: some View {
    switch appState.engineState {
    case .idle:
      if appState.requiresLocalModel, !appState.store.isDownloaded(appState.store.activeSpec) {
        InlineBanner(
          symbol: "arrow.down.circle",
          message: String(localized: "Download \(appState.store.activeSpec.displayName) to start chatting."),
          identifier: "chat.banner.download"
        ) {
          Button("Models") { showLibrary = true }
            .frame(minHeight: Theme.Size.target)
            .contentShape(.rect)
        }
        .bannerInsets()
      }
    case .loading(let progress):
      InlineBanner(
        symbol: "hourglass", message: progress, showsProgress: true, identifier: "chat.banner.loading"
      )
      .bannerInsets()
    case .failed(let message):
      InlineBanner(
        symbol: "exclamationmark.triangle", message: message, tint: Theme.Status.critical,
        identifier: "chat.banner.failed"
      ) {
        Button("Retry") { Task { await appState.ensureEngineLoaded() } }
          .frame(minHeight: Theme.Size.target)
          .contentShape(.rect)
      }
      .bannerInsets()
    case .ready, .generating:
      EmptyView()
    }
  }

  /// Subtle reminder when another chat has a mutating action parked on user approval.
  @ViewBuilder
  private var pendingConfirmationBanner: some View {
    if let confirmation = appState.pendingToolConfirmation,
      let ownerID = appState.generatingThreadID ?? appState.pendingToolConfirmationThreadID,
      threadID != ownerID
    {
      InlineBanner(
        symbol: "hand.raised.circle",
        message: String(localized: "“\(confirmation.title)” is waiting for approval in another chat."),
        tint: confirmation.risk == .destructive ? Theme.Status.critical : Theme.Status.guarded,
        identifier: "chat.banner.pendingApproval"
      ) {
        Button("Review") { AppRouter.shared.handle(.openChat(ownerID)) }
          .frame(minHeight: Theme.Size.target)
          .contentShape(.rect)
      }
      .bannerInsets()
    }
  }

  /// An error first, else a notice (same place and identifier; errors look like warnings).
  @ViewBuilder
  private var noticeBanner: some View {
    if let shortcutName = appState.pendingShortcutReturnName {
      InlineBanner(
        symbol: "bolt.horizontal.circle",
        message: String(localized: "Waiting for “\(shortcutName)” to return from Shortcuts."),
        tint: Theme.Brand.glacier,
        identifier: "chat.banner.shortcut"
      ) {
        Button("Continue") { appState.continueWithoutShortcutCallback() }
          .frame(minHeight: Theme.Size.target)
          .contentShape(.rect)
      }
      .bannerInsets()
    } else if let error = appState.generationError {
      InlineBanner(
        symbol: "exclamationmark.triangle", message: error, tint: Theme.Status.guarded,
        identifier: "chat.banner.notice"
      ) {
        Button("Dismiss") { appState.generationError = nil }
          .frame(minHeight: Theme.Size.target)
          .contentShape(.rect)
      }
      .bannerInsets()
    } else if let notice = appState.notice {
      InlineBanner(symbol: "info.circle", message: notice, identifier: "chat.banner.notice") {
        Button("Dismiss") { appState.notice = nil }
          .frame(minHeight: Theme.Size.target)
          .contentShape(.rect)
      }
      .bannerInsets()
    }
  }
}

/// Isolated modifier switching top scroll edge separation between `.hard` (when banners are
/// pinned) and `.soft` without subscribing `ChatMessagesList` to banner state.
private struct ChatTopScrollEdgeEffect: ViewModifier {
  @Environment(AppState.self) private var appState
  let threadID: UUID?

  func body(content: Content) -> some View {
    let hasBanners = ChatBannersView.hasBanners(appState: appState, threadID: threadID)
    content.scrollEdgeEffectStyle(hasBanners ? .hard : .soft, for: .top)
  }
}

/// Floating Liquid Glass scroll-to-bottom control observing live stream & mode state in isolation
/// so mode toggles never re-evaluate `ChatMessagesList`.
private struct ScrollToBottomButton: View {
  @Environment(AppState.self) private var appState
  let threadID: UUID?
  let composerBridge: ComposerBridge
  let action: () -> Void

  private var isStreamingBelow: Bool {
    appState.generatingThreadID == threadID && appState.isGenerating
  }

  private var mode: Theme.Mode {
    composerBridge.searchWeb ? .search : appState.options.enableThinking ? .think : .chat
  }

  var body: some View {
    Button(action: action) {
      Image(systemName: "arrow.down")
        .font(.system(.body, weight: .semibold))
        .foregroundStyle(isStreamingBelow ? mode.tint : Theme.Text.primary)
        .frame(width: Theme.Size.target, height: Theme.Size.target)
        .chromeSurface(
          in: Circle(),
          tint: isStreamingBelow ? mode.tint : nil,
          interactive: true)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .appAnimation(Theme.Motion.modeCrossfade, value: isStreamingBelow, kind: .dissolve)
    .appAnimation(Theme.Motion.modeCrossfade, value: mode, kind: .dissolve)
    .accessibilityLabel("Scroll to bottom")
    .accessibilityIdentifier("chat.scrollToBottom")
  }
}

/// Dedicated scroll container isolating `followsLatest` and O(1) turn lookups so streaming,
/// banners, reading aloud, and mode toggles never re-evaluate historical `MessageBubbleView` rows.
private struct ChatMessagesList: View {
  @Environment(AppState.self) private var appState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let thread: ChatThread?
  let composerBridge: ComposerBridge
  let reader: SpeechReader
  let showStats: Bool

  /// The list keeps the latest text in view (the user hasn't scrolled up).
  @State private var followsLatest = true

  private struct VersionKey: Hashable {
    var parentID: UUID?
    var role: String
    init(_ turn: ChatTurn) {
      parentID = turn.parentID
      role = turn.roleRaw
    }
  }

  /// Stable slot identity across sibling version switches so `VersionSwitcherView`'s
  /// `.contentTransition(.numericText())` animates in place rather than tearing down the row.
  private struct TurnSlotID: Hashable {
    var isLinkedTree: Bool
    var parentID: UUID?
    var roleRaw: String
    var fallbackTurnID: UUID?

    init(turn: ChatTurn, isLinkedTree: Bool) {
      self.isLinkedTree = isLinkedTree
      if isLinkedTree {
        parentID = turn.parentID
        roleRaw = turn.roleRaw
        fallbackTurnID = nil
      } else {
        parentID = nil
        roleRaw = ""
        fallbackTurnID = turn.id
      }
    }
  }

  private struct TurnSlot: Identifiable {
    let id: TurnSlotID
    let turn: ChatTurn
  }

  var body: some View {
    let allTurns = thread?.turns ?? []
    let turnsByID = Dictionary(allTurns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let turns = orderedTurns(in: thread, allTurns: allTurns, byID: turnsByID)
    let versions = versionGroups(in: thread, allTurns: allTurns)
    let isLinkedTree = thread?.activeLeafID != nil
    let turnSlots = turns.map {
      TurnSlot(id: TurnSlotID(turn: $0, isLinkedTree: isLinkedTree), turn: $0)
    }
    let activeConfirmation: ToolConfirmationRequest? = {
      guard let confirmation = appState.pendingToolConfirmation,
        let ownerID = appState.generatingThreadID ?? appState.pendingToolConfirmationThreadID,
        thread?.id == ownerID
      else { return nil }
      return confirmation
    }()
    let showScrollToBottom = !followsLatest && !turns.isEmpty

    Group {
      if turns.isEmpty {
        ChatEmptyStateView(isNewChat: thread == nil, composerBridge: composerBridge)
      } else {
        ScrollViewReader { proxy in
          ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
              ForEach(turnSlots) { slot in
                let turn = slot.turn
                MessageBubbleView(
                  turn: turn,
                  thread: thread,
                  isStreaming: isLiveBubble(turn, in: turns),
                  versions: versions[VersionKey(turn)] ?? [],
                  canRegenerate: canRegenerate(turn, turnsByID: turnsByID),
                  showsStats: showStats,
                  reader: reader,
                  composerBridge: composerBridge)
                  .id(slot.id)
              }
              if let confirmation = activeConfirmation {
                ToolConfirmationCard(
                  request: confirmation,
                  onApprove: {
                    appState.resolvePendingToolConfirmation(id: confirmation.id, approved: true)
                  },
                  onApproveSteps: { selected in
                    appState.resolvePendingToolConfirmation(id: confirmation.id, approvedSteps: selected)
                  },
                  onDeny: {
                    appState.resolvePendingToolConfirmation(id: confirmation.id, approved: false)
                  })
                  .id(confirmation.id)
                  .transition(
                    reduceMotion
                      ? .opacity
                      : .scale(scale: 0.96).combined(with: .opacity))
              }
            }
            .appAnimation(Theme.Motion.panel, value: activeConfirmation?.id)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.sm)
          }
          .id(thread?.id)
          .scrollDismissesKeyboard(.interactively)
          .scrollEdgeEffectStyle(.soft, for: .bottom)
          .modifier(ChatTopScrollEdgeEffect(threadID: thread?.id))
          // A chat opens on its latest message, and a short one sits at the top. At the bottom,
          // growth (streaming text, a new message, action cards, the keyboard) keeps the latest
          // line in view within the same layout pass. One-shot ScrollViewReader scrolling avoids
          // sticky ScrollPosition(id:) bindings that shift X or overscroll Y when a row grows.
          .defaultScrollAnchor(.bottom, for: .initialOffset)
          .defaultScrollAnchor(.top, for: .alignment)
          .defaultScrollAnchor(followsLatest ? .bottom : .top, for: .sizeChanges)
          .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height <= geometry.bounds.height
              || geometry.visibleRect.maxY
                >= geometry.contentSize.height + geometry.contentInsets.bottom - Theme.Spacing.xxxl
          } action: { _, atBottom in
            followsLatest = atBottom
          }
          .overlay(alignment: .bottomTrailing) {
            if showScrollToBottom {
              ScrollToBottomButton(threadID: thread?.id, composerBridge: composerBridge) {
                Haptics.selection()
                followsLatest = true
                if let confirmation = activeConfirmation {
                  withAppAnimation(Theme.Motion.easeOut) {
                    proxy.scrollTo(confirmation.id, anchor: .bottom)
                  }
                } else if let latest = turns.last {
                  let latestSlot = TurnSlotID(turn: latest, isLinkedTree: isLinkedTree)
                  withAppAnimation(Theme.Motion.easeOut) {
                    proxy.scrollTo(latestSlot, anchor: .bottom)
                  }
                }
              }
              .padding(.trailing, Theme.Spacing.lg)
              .padding(.bottom, Theme.Spacing.sm)
              .transition(
                reduceMotion
                  ? .opacity
                  : .scale(scale: 0.85).combined(with: .opacity))
            }
          }
          .appAnimation(Theme.Motion.panel, value: showScrollToBottom)
          .onChange(of: appState.scrollToLatestToken) { _, _ in
            guard appState.scrollToLatestThreadID == thread?.id, let latest = turns.last else { return }
            let latestSlot = TurnSlotID(turn: latest, isLinkedTree: isLinkedTree)
            followsLatest = true
            withAppAnimation(Theme.Motion.easeOut) {
              proxy.scrollTo(latestSlot, anchor: .bottom)
            }
          }
          .onChange(of: appState.pendingToolConfirmation?.id) { _, newID in
            guard let newID, let confirmation = appState.pendingToolConfirmation,
              let ownerID = appState.generatingThreadID ?? appState.pendingToolConfirmationThreadID,
              thread?.id == ownerID
            else { return }
            followsLatest = true
            withAppAnimation(Theme.Motion.easeOut) {
              proxy.scrollTo(newID, anchor: .bottom)
            }
            Haptics.announce(confirmation.summary)
          }
        }
      }
    }
    .onChange(of: thread?.id) { _, _ in
      followsLatest = true
    }
  }

  private func orderedTurns(
    in thread: ChatThread?, allTurns: [ChatTurn], byID: [UUID: ChatTurn]
  ) -> [ChatTurn] {
    guard let thread else { return [] }
    guard let activeLeafID = thread.activeLeafID else {
      return allTurns.sorted { $0.createdAt < $1.createdAt }
    }
    var path: [ChatTurn] = []
    var cursor = byID[activeLeafID]
    var seen = Set<UUID>()
    while let turn = cursor, seen.insert(turn.id).inserted {
      path.append(turn)
      cursor = turn.parentID.flatMap { byID[$0] }
    }
    return path.reversed()
  }

  /// Turns that are versions of each other (same parent and role), only where there is more than one.
  private func versionGroups(in thread: ChatThread?, allTurns: [ChatTurn]) -> [VersionKey: [ChatTurn]] {
    // Unlinked (legacy, never migrated) threads have no parents to group by.
    guard let thread, thread.activeLeafID != nil else { return [:] }
    return Dictionary(grouping: allTurns, by: VersionKey.init)
      .filter { $0.value.count > 1 }
      .mapValues { $0.sorted { $0.createdAt < $1.createdAt } }
  }

  private func canRegenerate(_ turn: ChatTurn, turnsByID: [UUID: ChatTurn]) -> Bool {
    guard !turn.isUser, let parentID = turn.parentID,
      let prompt = turnsByID[parentID], prompt.isUser
    else { return false }
    return !prompt.hasAudio || !prompt.text.isEmpty
  }

  private func isLiveBubble(_ turn: ChatTurn, in turns: [ChatTurn]) -> Bool {
    appState.generatingThreadID == thread?.id && turn.id == turns.last?.id && !turn.isUser
  }
}

/// A new chat: the greeting, optional project eyebrow (resolved via `.task`, never synchronously
/// inside `body`), and a few ways to start.
private struct ChatEmptyStateView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var context
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let isNewChat: Bool
  let composerBridge: ComposerBridge

  @State private var projectName: String?

  private enum Suggestion: CaseIterable {
    case explain, summarize, write, plan

    var title: LocalizedStringKey {
      switch self {
      case .explain: "Explain a topic"
      case .summarize: "Summarize a file"
      case .write: "Help me write"
      case .plan: "Plan a trip"
      }
    }

    var symbol: String {
      switch self {
      case .explain: "lightbulb"
      case .summarize: "doc.text.magnifyingglass"
      case .write: "pencil.line"
      case .plan: "map"
      }
    }

    /// Text that starts the draft (nil: the action is a file picker).
    var starter: String? {
      switch self {
      case .explain: String(localized: "Explain how ")
      case .summarize: nil
      case .write: String(localized: "Help me write ")
      case .plan: String(localized: "Plan a three-day trip to ")
      }
    }
  }

  var body: some View {
    GeometryReader { proxy in
      ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: Theme.Spacing.xxl) {
          Spacer(minLength: Theme.Spacing.lg)
          VStack(spacing: Theme.Spacing.sm) {
            if let projectName {
              Label(projectName, systemImage: "folder")
                .eyebrowStyle(Theme.Brand.glacier)
                .accessibilityIdentifier("chat.project")
            }
            Text(greeting)
              .font(.greeting)
              .foregroundStyle(Theme.Text.primary)
              .multilineTextAlignment(.center)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("chat.empty")
          }
          suggestions
          Spacer(minLength: Theme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
        .padding(.horizontal, Theme.Spacing.xl)
        .contentShape(.rect)
        .onTapGesture { composerBridge.send(.dismissKeyboard) }
      }
      .scrollBounceBehavior(.basedOnSize)
      .scrollDismissesKeyboard(.interactively)
    }
    .task(id: isNewChat ? appState.newChatProjectID : nil) {
      guard isNewChat, let id = appState.newChatProjectID else {
        projectName = nil
        return
      }
      var descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })
      descriptor.fetchLimit = 1
      projectName = (try? context.fetch(descriptor).first)?.name
    }
  }

  private var suggestions: some View {
    let columns =
      dynamicTypeSize.isAccessibilitySize
      ? [GridItem(.flexible())]
      : [GridItem(.flexible(), spacing: Theme.Spacing.sm), GridItem(.flexible())]
    return LazyVGrid(columns: columns, spacing: Theme.Spacing.sm) {
      ForEach(Suggestion.allCases, id: \.self) { suggestion in
        Button {
          Haptics.selection()
          if let starter = suggestion.starter {
            composerBridge.send(.insertStarter(starter))
          } else {
            composerBridge.send(.openFiles)
          }
        } label: {
          HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: suggestion.symbol)
              .foregroundStyle(Theme.Brand.glacier)
              .accessibilityHidden(true)
            // Fills the chip and wraps rather than truncating at larger text sizes (beside a
            // Spacer it would get half the width and wrap early).
            Text(suggestion.title)
              .foregroundStyle(Theme.Text.secondary)
              .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
              .multilineTextAlignment(.leading)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .font(.system(.subheadline, weight: .medium))
          .padding(.horizontal, Theme.Spacing.md)
          .padding(.vertical, Theme.Spacing.xs)
          .frame(maxHeight: .infinity)
          .frame(minHeight: Theme.Size.target + Theme.Spacing.xs)
          .surfaceCard(radius: Theme.Radius.card)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.suggestion")
      }
    }
  }

  private var greeting: String {
    let name = appState.personalization.enabled
      ? appState.personalization.name.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    return name.isEmpty
      ? String(localized: "What can I help with?")
      : String(localized: "What can I help with, \(name)?")
  }
}

private extension View {
  /// Banners sit just under the toolbar, inset like the composer.
  func bannerInsets() -> some View {
    padding(.horizontal, Theme.Spacing.md).padding(.top, Theme.Spacing.tight)
  }
}
