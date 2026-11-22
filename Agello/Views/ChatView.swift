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
  @State private var scrollPosition = ScrollPosition(edge: .bottom)
  /// The list keeps the latest text in view (the user hasn't scrolled up).
  @State private var followsLatest = true
  /// The developer screen's "Show performance details": time to first token, speed, backend.
  @AppStorage("showPerformanceDetails") private var showStats = false

  /// What the next message does; tints the ambient backdrop.
  private var mode: Theme.Mode {
    composerBridge.searchWeb ? .search : appState.options.enableThinking ? .think : .chat
  }

  var body: some View {
    // Computed once per render (not per use: this re-renders while streaming, never on keystrokes).
    let turns = thread?.orderedTurns ?? []
    let versions = versionGroups()
    VStack(spacing: 0) {
      engineBanner
      noticeBanner
      messagesList(turns, versions: versions)
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
      AmbientBackdrop(tint: mode.tint)
        .animation(Theme.Motion.modeCrossfade, value: mode)
    }
    .appAnimation(Theme.Motion.easeOut, value: appState.generationError)
    .appAnimation(Theme.Motion.easeOut, value: appState.notice)
    // The banner appears without moving VoiceOver's focus: say it.
    .onChange(of: appState.generationError) { _, message in
      if let message { Haptics.announce(message) }
    }
    .onChange(of: appState.notice) { _, message in
      if let message { Haptics.announce(message) }
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
      } else if appState.isMock || appState.store.activeSpecDownloaded {
        // Warm the model up while the first message is typed.
        await appState.ensureEngineLoaded()
      }
    }
    .onChange(of: thread?.id) { old, _ in
      scrollPosition = ScrollPosition(edge: .bottom)
      followsLatest = true
      guard old != nil else { return }
      reader.stop()
    }
    .onDisappear {
      reader.stop()
    }
  }

  // MARK: - Banners

  @ViewBuilder
  private var engineBanner: some View {
    switch appState.engineState {
    case .idle:
      if !appState.isMock, !appState.store.isDownloaded(appState.store.activeSpec) {
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

  /// An error first, else a notice (same place and identifier; errors look like warnings).
  @ViewBuilder
  private var noticeBanner: some View {
    if let error = appState.generationError {
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

  // MARK: - Messages

  private func messagesList(_ turns: [ChatTurn], versions: [VersionKey: [ChatTurn]]) -> some View {
    Group {
      if turns.isEmpty {
        emptyState
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
            ForEach(turns) { turn in
              MessageBubbleView(
                turn: turn, isStreaming: isLiveBubble(turn, in: turns),
                toolStatus: appState.toolStatus,
                versions: versions[VersionKey(turn)] ?? [],
                showsStats: showStats,
                actions: actions(for: turn))
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
                onDeny: {
                  appState.resolvePendingToolConfirmation(id: confirmation.id, approved: false)
                })
                .id(confirmation.id)
            }
          }
          // The rows are scroll targets: a new message is scrolled to by its id (below).
          .scrollTargetLayout()
          .padding(.horizontal, Theme.Spacing.xl)
          .padding(.top, Theme.Spacing.lg)
          .padding(.bottom, Theme.Spacing.sm)
        }
        .id(thread?.id)
        .scrollPosition($scrollPosition)
        .scrollDismissesKeyboard(.interactively)
        // A chat opens on its latest message, and a short one sits at the top. At the bottom,
        // growth (streaming text, a new message, the keyboard) keeps the latest line in view
        // within the same layout pass: no scrollTo a frame late, so nothing jumps. Scrolled up,
        // the text being read stays put.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(followsLatest ? .bottom : .top, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geometry in
          geometry.visibleRect.maxY >= geometry.contentSize.height - Theme.Spacing.xxxl
        } action: { _, atBottom in
          followsLatest = atBottom
        }
        .onChange(of: turns.count) { old, new in
          // A new message brings the list back to the latest, by its id rather than the list's
          // edge: the lazy list only estimates the rows it hasn't laid out, and after a long
          // reply (hundreds of lines of code) the edge's estimate left the view past the real
          // end, an empty screen while the next reply streamed (iPhone 17 Pro, 2026-11-15).
          guard new > old, let latest = turns.last?.id else { return }
          followsLatest = true
          withAppAnimation(Theme.Motion.easeOut) { scrollPosition.scrollTo(id: latest, anchor: .bottom) }
        }
        .onChange(of: appState.pendingToolConfirmation?.id) { _, newID in
          guard let newID, let confirmation = appState.pendingToolConfirmation,
            let ownerID = appState.generatingThreadID ?? appState.pendingToolConfirmationThreadID,
            thread?.id == ownerID
          else { return }
          followsLatest = true
          withAppAnimation(Theme.Motion.easeOut) { scrollPosition.scrollTo(id: newID, anchor: .bottom) }
          Haptics.announce(confirmation.summary)
        }
      }
    }
  }

  /// A new chat: the greeting and a few ways to start.
  private var emptyState: some View {
    VStack(spacing: Theme.Spacing.xxl) {
      Spacer()
      VStack(spacing: Theme.Spacing.sm) {
        if let project = newChatProject {
          Label(project.name, systemImage: "folder")
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
  }

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

  /// The project a new chat will join, for the empty state.
  private var newChatProject: Project? {
    guard thread == nil, let id = appState.newChatProjectID else { return nil }
    return try? context.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })).first
  }

  private var greeting: String {
    let name = appState.personalization.enabled
      ? appState.personalization.name.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    return name.isEmpty
      ? String(localized: "What can I help with?")
      : String(localized: "What can I help with, \(name)?")
  }

  // MARK: - Message actions

  struct VersionKey: Hashable {
    var parentID: UUID?
    var role: String
    init(_ turn: ChatTurn) {
      parentID = turn.parentID
      role = turn.roleRaw
    }
  }

  /// Turns that are versions of each other (same parent and role), only where there is more than one.
  private func versionGroups() -> [VersionKey: [ChatTurn]] {
    // Unlinked (legacy, never migrated) threads have no parents to group by.
    guard let thread, thread.activeLeafID != nil else { return [:] }
    return Dictionary(grouping: thread.turns, by: VersionKey.init)
      .filter { $0.value.count > 1 }
      .mapValues { $0.sorted { $0.createdAt < $1.createdAt } }
  }

  private func actions(for turn: ChatTurn) -> MessageActions {
    guard let thread else { return MessageActions() }
    return MessageActions(
      isBusy: appState.isBusy,
      isSpeaking: reader.speakingID == turn.id,
      canRegenerate: !turn.isUser && appState.canRegenerate(turn, in: thread),
      regenerate: {
        reader.stop()
        Haptics.send()
        Task { await appState.regenerate(turn, in: thread) }
      },
      edit: { composerBridge.send(.edit(turn)) },
      speak: { reader.toggle(turn.text, id: turn.id) },
      selectVersion: { version in
        withAppAnimation(Theme.Motion.easeOut) { appState.selectVersion(version, in: thread) }
      })
  }

  private func isLiveBubble(_ turn: ChatTurn, in turns: [ChatTurn]) -> Bool {
    appState.generatingThreadID == thread?.id && turn.id == turns.last?.id && !turn.isUser
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

private extension View {
  /// Banners sit just under the toolbar, inset like the composer.
  func bannerInsets() -> some View {
    padding(.horizontal, Theme.Spacing.md).padding(.top, Theme.Spacing.tight)
  }
}
