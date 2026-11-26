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
    VStack(spacing: 0) {
      ChatBannersView(threadID: thread?.id, showLibrary: $showLibrary)
      ChatMessagesList(
        thread: thread,
        composerBridge: composerBridge,
        reader: reader,
        showStats: showStats)
        .frame(maxHeight: .infinity)
      // Composer rows keep their full height; the messages area above shrinks instead (e.g. above
      // the keyboard), so nothing is pushed under it.
      ChatComposerView(
        thread: thread,
        bridge: composerBridge,
        onStopReading: { reader.stop() },
        onOpenVoice: { openVoiceMode(startWithCamera: false) },
        makeThread: newThread
      )
      .layoutPriority(1)
    }
    .background {
      ChatBackdropView(bridge: composerBridge)
    }
    .navigationTitle(thread?.title ?? "")
    .inlineTitleDisplay()
    .sheet(isPresented: $showLibrary) {
      NavigationStack {
        ModelLibraryView()
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showLibrary = false }
            }
          }
      }
      .environment(appState)
    }
    .fullScreenOrSheet(item: $voiceSession) { session in
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
      .appAnimation(Theme.Motion.modeCrossfade, value: mode)
  }
}

/// Isolated banner stack observing engine/notice/error/confirmation state without invalidating
/// the message list below it.
private struct ChatBannersView: View {
  @Environment(AppState.self) private var appState
  let threadID: UUID?
  @Binding var showLibrary: Bool

  var body: some View {
    VStack(spacing: 0) {
      engineBanner
      pendingConfirmationBanner
      noticeBanner
    }
    .appAnimation(Theme.Motion.easeOut, value: appState.generationError)
    .appAnimation(Theme.Motion.easeOut, value: appState.notice)
    .appAnimation(Theme.Motion.easeOut, value: appState.pendingToolConfirmation?.id)
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
      }
      .bannerInsets()
    } else if let error = appState.generationError {
      InlineBanner(
        symbol: "exclamationmark.triangle", message: error, tint: Theme.Status.guarded,
        identifier: "chat.banner.notice"
      ) {
        Button("Dismiss") { appState.generationError = nil }
      }
      .bannerInsets()
    } else if let notice = appState.notice {
      InlineBanner(symbol: "info.circle", message: notice, identifier: "chat.banner.notice") {
        Button("Dismiss") { appState.notice = nil }
      }
      .bannerInsets()
    }
  }
}

/// Dedicated scroll container isolating `followsLatest` and O(1) turn lookups so streaming,
/// banners, reading aloud, and mode toggles never re-evaluate historical `MessageBubbleView` rows.
private struct ChatMessagesList: View {
  @Environment(AppState.self) private var appState
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

  var body: some View {
    let allTurns = thread?.turns ?? []
    let turnsByID = Dictionary(allTurns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let turns = orderedTurns(in: thread, allTurns: allTurns, byID: turnsByID)
    let versions = versionGroups(in: thread, allTurns: allTurns)
    Group {
      if turns.isEmpty {
        ChatEmptyStateView(isNewChat: thread == nil, composerBridge: composerBridge)
      } else {
        ScrollViewReader { proxy in
          ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
              ForEach(turns) { turn in
                MessageBubbleView(
                  turn: turn,
                  thread: thread,
                  isStreaming: isLiveBubble(turn, in: turns),
                  versions: versions[VersionKey(turn)] ?? [],
                  canRegenerate: canRegenerate(turn, turnsByID: turnsByID),
                  showsStats: showStats,
                  reader: reader,
                  composerBridge: composerBridge)
                  .id(turn.id)
              }
              if let confirmation = appState.pendingToolConfirmation,
                let ownerID = appState.generatingThreadID ?? appState.pendingToolConfirmationThreadID,
                thread?.id == ownerID
              {
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
              }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.top, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.sm)
          }
          .id(thread?.id)
          .scrollDismissesKeyboard(.interactively)
          // A chat opens on its latest message, and a short one sits at the top. At the bottom,
          // growth (streaming text, a new message, action cards, the keyboard) keeps the latest
          // line in view within the same layout pass. One-shot ScrollViewReader scrolling avoids
          // sticky ScrollPosition(id:) bindings that shift X or overscroll Y when a row grows.
          .defaultScrollAnchor(.bottom, for: .initialOffset)
          .defaultScrollAnchor(.top, for: .alignment)
          .defaultScrollAnchor(followsLatest ? .bottom : .top, for: .sizeChanges)
          .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.visibleRect.maxY >= geometry.contentSize.height - Theme.Spacing.xxxl
          } action: { _, atBottom in
            followsLatest = atBottom
          }
          .onChange(of: appState.scrollToLatestToken) { _, _ in
            guard appState.scrollToLatestThreadID == thread?.id, let latest = turns.last?.id else { return }
            followsLatest = true
            withAppAnimation(Theme.Motion.easeOut) {
              proxy.scrollTo(latest, anchor: .bottom)
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
    VStack(spacing: Theme.Spacing.xxl) {
      Spacer()
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
          .accessibilityIdentifier("chat.empty")
      }
      suggestions
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, Theme.Spacing.xl)
    .contentShape(.rect)
    .onTapGesture { composerBridge.send(.dismissKeyboard) }
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
    LazyVGrid(
      columns: [GridItem(.flexible(), spacing: Theme.Spacing.sm), GridItem(.flexible())],
      spacing: Theme.Spacing.sm
    ) {
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
              .lineLimit(2)
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
