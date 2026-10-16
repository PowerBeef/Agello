import PhotosUI
import SwiftData
import SwiftUI

/// A conversation, or a new chat (`thread == nil`) that is saved when its
/// first message is sent.
struct ChatView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var context
  let thread: ChatThread?

  @State private var draft = ""
  @State private var pendingImage: Data?
  @State private var photoItem: PhotosPickerItem?
  @State private var recorder = AudioRecorder()
  @State private var showLibrary = false
  @State private var showPhotos = false
  @State private var showCamera = false
  @State private var showFiles = false
  @State private var showScanner = false
  /// Files read and waiting to be sent with the next message.
  @State private var pendingFiles: [ExtractedDocument] = []
  /// Bumped when the chat changes: files still being read belong to the chat they were picked in.
  @State private var composerGeneration = 0
  @State private var fileReads: [Task<Void, Never>] = []
  /// Files being read right now.
  @State private var readingFiles = 0
  /// Search the web for the next message.
  @State private var searchWeb = false
  /// The recording in progress is dictation (text for the composer), not a
  /// voice message.
  @State private var dictating = false
  /// Voice mode while open, made once per opening: built in the cover's closure, a new session
  /// (audio engine, speech synthesizer, camera session) was made and thrown away at every update
  /// of this view. The cover follows it (`item:`), so it never opens without its session.
  @State private var voiceSession: VoiceSession?
  @State private var reader = SpeechReader()
  /// The user message being edited in the composer, if any.
  @State private var editingTurn: ChatTurn?
  @State private var scrollPosition = ScrollPosition(edge: .bottom)
  /// The list keeps the latest text in view (the user hasn't scrolled up).
  @State private var followsLatest = true
  @FocusState private var inputFocused: Bool
  /// Settings → Advanced → Performance: time to first token, speed, backend.
  @AppStorage("showPerformanceDetails") private var showStats = false

  /// What the next message does; tints the backdrop, pills and send button.
  private var mode: Theme.Mode {
    searchWeb ? .search : appState.options.enableThinking ? .think : .chat
  }

  var body: some View {
    // Computed once per render (not per use: this re-renders while streaming).
    let turns = thread?.orderedTurns ?? []
    let versions = versionGroups()
    VStack(spacing: 0) {
      engineBanner
      noticeBanner
      messagesList(turns, versions: versions)
        .frame(maxHeight: .infinity)
      // Composer rows keep their full height; the messages area above
      // shrinks instead (e.g. above the keyboard), so nothing is pushed under it.
      Group {
        preparingBar
        editingBar
        pendingBar
        inputBar
      }
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
    .navigationBarTitleDisplayMode(.inline)
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
    .alert(
      "Microphone access denied",
      isPresented: $recorder.permissionDenied
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Enable microphone access in Settings to send voice messages.")
    }
    .fullScreenCover(item: $voiceSession) { session in
      VoiceModeView(session: session)
    }
    .onChange(of: AppRouter.shared.voiceRequested, initial: true) { _, requested in
      guard requested else { return }
      AppRouter.shared.voiceRequested = false
      openVoiceMode()
    }
    .onChange(of: recorder.isRecording) { wasRecording, isRecording in
      if wasRecording, !isRecording, dictating { finishDictation() }
    }
    .onChange(of: recorder.errorMessage) { _, message in
      if let message { appState.generationError = "Recording failed: \(message)" }
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
      // Switching chats (not saving a new one) starts with a clean composer.
      guard old != nil else { return }
      reader.stop()
      editingTurn = nil
      draft = ""
      pendingImage = nil
      // Files, the Search toggle and a voice message belong to the chat they were added in.
      composerGeneration += 1
      for read in fileReads { read.cancel() }
      fileReads = []
      pendingFiles = []
      searchWeb = false
      dictating = false
      recorder.discard()
      takeRequestedDraft()
    }
    .onChange(of: AppRouter.shared.draftRequested, initial: true) {
      // A new chat opened for it applies it on the chat change above.
      if thread == nil { takeRequestedDraft() }
    }
    .onDisappear { reader.stop() }
    .onAppear {
      // UI tests: the system file picker can't be driven, so attach a sample.
      let arguments = ProcessInfo.processInfo.arguments
      if thread == nil, pendingFiles.isEmpty {
        if arguments.contains("--uitest-sample-file") {
          pendingFiles = [
            ExtractedDocument(
              name: "trip-notes.md", kind: .text, byteCount: 120,
              pages: [
                "Hiking trip notes.\n\nThe trailhead parking opens at 6 am. Bring a tent, a stove, "
                  + "and three litres of water per person."
              ])
          ]
        } else if arguments.contains("--uitest-sample-report") {
          // A long report, so "Summarize this" reads it section by section:
          // 60 pages (~8K tokens) never fit half of the 8K chat window.
          let topics = [
            "harbour maintenance", "coastal erosion", "lighthouse operations", "fisheries",
            "visitor services", "storm preparedness", "habitat restoration", "water quality",
          ]
          let pages = (1...60).map { page -> String in
            let topic = topics[page % topics.count]
            return [
              "Section \(page): \(topic.capitalized).",
              "This section reviews \(topic) during the reporting period. Teams in district "
                + "\(page % 5 + 1) completed scheduled inspections, logged their findings, and "
                + "filed follow-up requests where repairs were needed.",
              "Most indicators for \(topic) stayed within normal ranges. Seasonal variation was "
                + "observed, and staff recommend continuing the current monitoring programme.",
            ].joined(separator: "\n\n")
          }
          pendingFiles = [
            ExtractedDocument(
              name: "coastal-report.pdf", kind: .pdf, byteCount: 200_000, pages: pages)
          ]
        }
      }
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
          }
          .padding(.horizontal, Theme.Spacing.xl)
          .padding(.top, Theme.Spacing.lg)
          .padding(.bottom, Theme.Spacing.sm)
        }
        .id(thread?.id)
        .scrollPosition($scrollPosition)
        .scrollDismissesKeyboard(.interactively)
        // A chat opens on its latest message, and a short one sits at the
        // top. At the bottom, growth (streaming text, a new message, the
        // keyboard) keeps the latest line in view within the same layout
        // pass: no scrollTo a frame late, so nothing jumps. Scrolled up, the
        // text being read stays put.
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .alignment)
        .defaultScrollAnchor(followsLatest ? .bottom : .top, for: .sizeChanges)
        .onScrollGeometryChange(for: Bool.self) { geometry in
          geometry.visibleRect.maxY >= geometry.contentSize.height - Theme.Spacing.xxxl
        } action: { _, atBottom in
          followsLatest = atBottom
        }
        .onChange(of: turns.count) { old, new in
          // A new message brings the list back to the latest.
          guard new > old else { return }
          followsLatest = true
          withAppAnimation(Theme.Motion.easeOut) { scrollPosition.scrollTo(edge: .bottom) }
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
    .onTapGesture { inputFocused = false }
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
            draft = starter
            inputFocused = true
          } else {
            showFiles = true
          }
        } label: {
          HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: suggestion.symbol)
              .foregroundStyle(Theme.Brand.glacier)
              .accessibilityHidden(true)
            // Fills the chip and wraps rather than truncating at larger text
            // sizes (beside a Spacer it would get half the width and wrap early).
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

  /// Turns that are versions of each other (same parent and role), only
  /// where there is more than one.
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
      edit: { startEditing(turn) },
      speak: { reader.toggle(turn.text, id: turn.id) },
      selectVersion: { version in
        withAppAnimation(Theme.Motion.easeOut) { appState.selectVersion(version, in: thread) }
      })
  }

  private func startEditing(_ turn: ChatTurn) {
    editingTurn = turn
    draft = turn.text
    pendingImage = nil
    recorder.discard()
    inputFocused = true
  }

  private func cancelEditing() {
    editingTurn = nil
    draft = ""
  }

  @ViewBuilder
  private var editingBar: some View {
    if editingTurn != nil {
      HStack(spacing: Theme.Spacing.sm) {
        Image(systemName: "pencil")
          .foregroundStyle(Theme.Brand.glacier)
          .accessibilityHidden(true)
        Text("Editing message")
          .font(.footnote)
          .foregroundStyle(Theme.Text.secondary)
          .accessibilityIdentifier("chat.editing")
        Spacer()
        Button("Cancel", action: cancelEditing)
          .font(.system(.footnote, weight: .semibold))
          .foregroundStyle(Theme.Brand.glacier)
          .buttonStyle(.plain)
          .frame(minHeight: Theme.Size.target)
          .contentShape(.rect)
          .accessibilityIdentifier("chat.editing.cancel")
      }
      .padding(.horizontal, Theme.Spacing.xl)
    }
  }

  private func isLiveBubble(_ turn: ChatTurn, in turns: [ChatTurn]) -> Bool {
    appState.generatingThreadID == thread?.id && turn.id == turns.last?.id && !turn.isUser
  }

  // MARK: - Pending attachments

  /// "Reading report.pdf · part 3 of 11" while files are prepared.
  @ViewBuilder
  private var preparingBar: some View {
    if let status = appState.preparingStatus, appState.preparingThreadID == thread?.id {
      HStack(spacing: Theme.Spacing.sm) {
        ProgressView().controlSize(.small).tint(mode.tint)
        Text(status)
          .font(.footnote)
          .foregroundStyle(Theme.Text.secondary)
          .lineLimit(1)
          .accessibilityIdentifier("chat.preparing")
        Spacer()
      }
      .padding(.horizontal, Theme.Spacing.xl)
      .padding(.vertical, Theme.Spacing.xs)
    }
  }

  @ViewBuilder
  private var pendingBar: some View {
    if !pendingFiles.isEmpty || readingFiles > 0 {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Theme.Spacing.sm) {
          ForEach(Array(pendingFiles.enumerated()), id: \.offset) { index, file in
            FileChip(name: file.name, kind: file.kind, pageCount: file.isPaged ? file.pages.count : 0) {
              pendingFiles.remove(at: index)
            }
          }
          if readingFiles > 0 {
            HStack(spacing: Theme.Spacing.tight) {
              ProgressView().controlSize(.mini)
              Text("Reading…").font(.caption).foregroundStyle(Theme.Text.secondary)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(minHeight: Theme.Size.pill)
            .background { QuietBackground(shape: Capsule()) }
            .accessibilityIdentifier("composer.readingFile")
          }
        }
        .padding(.horizontal, Theme.Spacing.md)
      }
      .padding(.vertical, Theme.Spacing.xs)
    }
    if pendingImage != nil || recorder.finishedURL != nil || recorder.isRecording {
      HStack(spacing: Theme.Spacing.sm) {
        if let data = pendingImage, let uiImage = UIImage(data: data) {
          Button {
            pendingImage = nil
          } label: {
            Image(uiImage: uiImage)
              .resizable()
              .scaledToFill()
              .frame(width: Theme.Size.target, height: Theme.Size.target)
              .clipShape(.rect(cornerRadius: Theme.Radius.row, style: .continuous))
              .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                  .stroke(Theme.Surface.stroke, lineWidth: Theme.Stroke.hairline)
              }
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Photo")
          .accessibilityHint("Removes the photo")
        }
        if recorder.isRecording {
          Label(
            dictating
              ? String(format: String(localized: "Listening… %.0fs"), recorder.elapsed)
              : String(format: "%.0fs / %.0fs", recorder.elapsed, AudioRecorder.maxDuration),
            systemImage: dictating ? "waveform" : "record.circle"
          )
          .font(.system(.caption, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(Theme.Text.primary)
          .padding(.horizontal, Theme.Spacing.md)
          .frame(minHeight: Theme.Size.pill)
          .background { LitTintBackground(shape: Capsule(), tint: Theme.Status.critical, strength: .pill) }
          .accessibilityIdentifier("composer.recording")
          if !dictating {
            Button("Stop") { recorder.stop() }
              .font(.system(.footnote, weight: .semibold))
              .foregroundStyle(Theme.Status.critical)
              .buttonStyle(.plain)
              .frame(minHeight: Theme.Size.target)
              .accessibilityIdentifier("composer.stopVoice")
          }
        } else if recorder.finishedURL != nil, !dictating, !appState.isTranscribing {
          Button {
            recorder.discard()
          } label: {
            Label("Voice ready (\(Int(recorder.elapsed))s)", systemImage: "waveform")
              .font(.system(.caption, weight: .medium))
              .foregroundStyle(Theme.Text.primary)
              .padding(.horizontal, Theme.Spacing.md)
              .frame(minHeight: Theme.Size.pill)
              .background { LitTintBackground(shape: Capsule(), tint: Theme.Mode.voice.tint, strength: .pill) }
          }
          .buttonStyle(.plain)
          .accessibilityHint("Removes the voice message")
        }
        Spacer()
        if pendingImage != nil || recorder.finishedURL != nil {
          Button("Clear") {
            pendingImage = nil
            recorder.discard()
          }
          .font(.system(.footnote, weight: .semibold))
          .foregroundStyle(Theme.Text.secondary)
          .buttonStyle(.plain)
          .frame(minHeight: Theme.Size.target)
        }
      }
      .padding(.horizontal, Theme.Spacing.lg)
      .padding(.vertical, Theme.Spacing.xs)
    }
  }

  // MARK: - Composer

  /// The composer: the message on top; attach, Think, Search, the
  /// microphone and the send / voice / stop button below, on one chrome
  /// panel lit by the active mode. The next message can be typed while a
  /// reply streams.
  private var inputBar: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      TextField(
        "Ask anything", text: $draft,
        prompt: Text("Ask anything").foregroundStyle(Theme.Text.placeholder), axis: .vertical
      )
      .font(.body)
      .foregroundStyle(Theme.Text.primary)
      .lineLimit(1...8)
      .textFieldStyle(.plain)
      .padding(.horizontal, Theme.Spacing.sm)
      .padding(.top, Theme.Spacing.sm)
      .focused($inputFocused)
      .accessibilityIdentifier("chat.input")
      HStack(spacing: Theme.Spacing.sm) {
        attachMenu
        // Titled pills when they fit, icons otherwise; priority over the
        // spacer so a title never truncates to "T…".
        ViewThatFits(in: .horizontal) {
          modeToggles(iconOnly: false)
          modeToggles(iconOnly: true)
        }
        .layoutPriority(1)
        Spacer(minLength: 0)
        micButton
        actionButton
      }
    }
    .padding(Theme.Spacing.snug)
    .chromeSurface(
      in: RoundedRectangle(cornerRadius: Theme.Radius.composer, style: .continuous), tint: mode.tint)
    .animation(Theme.Motion.modeCrossfade, value: mode)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("chat.composer")
    .padding(.horizontal, Theme.Spacing.snug)
    .padding(.bottom, Theme.Spacing.tight)
    .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
    .onChange(of: photoItem) { _, item in
      Task {
        if let item, let data = try? await item.loadTransferable(type: Data.self) {
          pendingImage = await Task.detached(priority: .userInitiated) {
            ImagePreparer.prepare(data) ?? data
          }.value
        }
        photoItem = nil
      }
    }
    .fullScreenCover(isPresented: $showCamera) {
      CameraPicker { data in
        pendingImage = data
      }
      .ignoresSafeArea()
    }
    .fullScreenCover(isPresented: $showScanner) {
      DocumentScanner { pages in
        read { try await DocumentIngestor.extract(scannedPages: pages, name: scanName()) }
      }
      .ignoresSafeArea()
    }
    .fileImporter(
      isPresented: $showFiles, allowedContentTypes: DocumentIngestor.supportedTypes,
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls):
        for url in urls { read { try await DocumentIngestor.extract(from: url) } }
      case .failure(let error):
        appState.generationError = error.localizedDescription
      }
    }
  }

  private func openVoiceMode() {
    voiceSession = VoiceSession(appState: appState, thread: thread, makeThread: newThread)
  }

  /// A link's message (`agello://ask`) in the composer, for the user to send.
  private func takeRequestedDraft() {
    guard let text = AppRouter.shared.draftRequested else { return }
    AppRouter.shared.draftRequested = nil
    draft = text
    inputFocused = true
  }

  /// Read a file in the background into the pending attachments of the chat it was picked in.
  private func read(_ extract: @escaping @Sendable () async throws -> ExtractedDocument) {
    readingFiles += 1
    let generation = composerGeneration
    let task = Task {
      defer { readingFiles -= 1 }
      let extraction = Task.detached(priority: .userInitiated) { try await extract() }
      do {
        let document = try await withTaskCancellationHandler {
          try await extraction.value
        } onCancel: {
          extraction.cancel()
        }
        guard generation == composerGeneration else { return }
        pendingFiles.append(document)
      } catch {
        guard generation == composerGeneration, !(error is CancellationError) else { return }
        appState.generationError = error.localizedDescription
      }
    }
    fileReads.append(task)
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

  private func scanName() -> String {
    "Scan \(Date.now.formatted(date: .abbreviated, time: .shortened))"
  }

  private var attachDisabled: Bool { appState.isBusy || editingTurn != nil }

  private var attachMenu: some View {
    Menu {
      Button("Camera", systemImage: "camera") { showCamera = true }
        .disabled(!CameraPicker.isAvailable)
      Button("Photos", systemImage: "photo.on.rectangle") { showPhotos = true }
      Button("Files", systemImage: "folder") { showFiles = true }
      Button("Scan document", systemImage: "doc.viewfinder") { showScanner = true }
        .disabled(!DocumentScanner.isAvailable)
      Button("Voice message", systemImage: "waveform") {
        dictating = false
        Task { await recorder.toggle() }
      }
    } label: {
      Image(systemName: "plus")
        .font(.system(.body, weight: .semibold))
        .foregroundStyle(attachDisabled ? Theme.Text.tertiary : Theme.Text.primary)
        .frame(width: Theme.Size.target, height: Theme.Size.target)
        .background { QuietBackground(shape: Circle()) }
        .contentShape(Circle())
    }
    .disabled(attachDisabled)
    .accessibilityLabel("Add photos and files")
    .accessibilityIdentifier("composer.attach")
  }

  private func modeToggles(iconOnly: Bool) -> some View {
    HStack(spacing: Theme.Spacing.sm) {
      thinkToggle(iconOnly: iconOnly)
      if appState.webSettings.allowed {
        searchToggle(iconOnly: iconOnly)
      }
    }
  }

  /// Web search for the next message only.
  private func searchToggle(iconOnly: Bool) -> some View {
    Button {
      searchWeb.toggle()
      Haptics.selection()
    } label: {
      Label("Search", systemImage: "globe")
    }
    .buttonStyle(ModePillStyle(isOn: searchWeb, tint: Theme.Mode.search.tint, iconOnly: iconOnly))
    .disabled(appState.isBusy || editingTurn != nil)
    .accessibilityLabel("Search")
    .accessibilityValue(searchWeb ? "On" : "Off")
    .accessibilityAddTraits(.isToggle)
    .accessibilityIdentifier("composer.search")
  }

  /// Reasoning for the next messages (applies before the next send).
  private func thinkToggle(iconOnly: Bool) -> some View {
    let isOn = appState.options.enableThinking
    return Button {
      appState.options.enableThinking.toggle()
      appState.scheduleApplyOptions()
      Haptics.selection()
    } label: {
      Label("Think", systemImage: "lightbulb")
    }
    .buttonStyle(ModePillStyle(isOn: isOn, tint: Theme.Mode.think.tint, iconOnly: iconOnly))
    .disabled(appState.isBusy)
    .accessibilityLabel("Think")
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityAddTraits(.isToggle)
    .accessibilityIdentifier("composer.think")
  }

  /// Dictation: speak, then the text lands in the composer for review.
  @ViewBuilder
  private var micButton: some View {
    let listening = recorder.isRecording && dictating
    let button = Button(action: toggleDictation) {
      Group {
        if appState.isTranscribing {
          ProgressView()
        } else {
          Image(systemName: listening ? "checkmark" : "mic")
            .contentTransition(.symbolEffect(.replace))
        }
      }
    }
    Group {
      if listening {
        button.buttonStyle(LitCircleButtonStyle(tint: Theme.Status.critical))
      } else {
        button.buttonStyle(QuietCircleButtonStyle())
      }
    }
    .disabled(
      appState.isBusy || appState.isTranscribing || (recorder.isRecording && !dictating))
    .accessibilityLabel(listening ? "Finish dictation" : "Dictate")
    .accessibilityValue(appState.isTranscribing ? "Transcribing" : listening ? "Listening" : "")
    .accessibilityIdentifier("composer.mic")
  }

  private func toggleDictation() {
    if recorder.isRecording && dictating {
      recorder.stop()  // transcribed in onChange(of: isRecording)
    } else {
      dictating = true
      Task {
        await recorder.toggle()
        if !recorder.isRecording { dictating = false }
      }
    }
  }

  /// The dictation recording became text: append it to the draft.
  private func finishDictation() {
    dictating = false
    guard let url = recorder.finishedURL else { return }
    Task {
      let text = await appState.transcribe(url)
      recorder.discard()
      if let text, !text.isEmpty {
        draft = Dictation.insert(text, into: draft)
        inputFocused = true
      }
    }
  }

  /// What the composer's main button does right now.
  private enum PrimaryAction: Equatable {
    case stop, voice, send

    var symbol: String {
      switch self {
      case .stop: "stop.fill"
      case .voice: "waveform"
      case .send: "arrow.up"
      }
    }

    var label: LocalizedStringKey {
      switch self {
      case .stop: "Stop generating"
      case .voice: "Voice mode"
      case .send: "Send"
      }
    }

    var identifier: String {
      switch self {
      case .stop: "chat.stop"
      case .voice: "composer.voice"
      case .send: "chat.send"
      }
    }
  }

  private var primaryAction: PrimaryAction {
    if appState.isBusy { return .stop }
    // Nothing to send: talk instead (voice mode).
    if !canSend, !recorder.isRecording, !appState.isTranscribing, editingTurn == nil { return .voice }
    return .send
  }

  /// Send, voice mode, or stop: one lit button whose glyph morphs.
  private var actionButton: some View {
    let action = primaryAction
    let tint =
      switch action {
      case .stop: Theme.Status.critical
      case .voice: Theme.Mode.voice.tint
      case .send: mode.tint
      }
    return Button {
      switch action {
      case .stop: appState.stop()
      case .voice: openVoiceMode()
      case .send: send()
      }
    } label: {
      Image(systemName: action.symbol)
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(LitCircleButtonStyle(tint: tint))
    .disabled(action == .send && !canSend)
    .animation(Theme.Motion.easeOut, value: action)
    .accessibilityLabel(action.label)
    .accessibilityIdentifier(action.identifier)
  }

  /// A finished voice message (not a dictation being transcribed).
  private var voiceMessageURL: URL? {
    dictating || appState.isTranscribing ? nil : recorder.finishedURL
  }

  private var canSend: Bool {
    guard readingFiles == 0, !recorder.isRecording, !appState.isTranscribing else { return false }
    return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || pendingImage != nil || voiceMessageURL != nil || !pendingFiles.isEmpty
  }

  private func send() {
    reader.stop()
    if let editingTurn, let thread {
      let text = draft
      draft = ""
      self.editingTurn = nil
      inputFocused = false
      Haptics.send()
      Task {
        let accepted = await appState.edit(editingTurn, text: text, in: thread)
        if !accepted, draft.isEmpty {
          draft = text
          self.editingTurn = editingTurn
        }
      }
      return
    }
    let text = draft
    let image = pendingImage
    let audioURL = voiceMessageURL
    let files = pendingFiles
    let webSearch = searchWeb
    draft = ""
    pendingImage = nil
    pendingFiles = []
    searchWeb = false
    inputFocused = false
    Haptics.send()
    let target = thread ?? newThread()
    // Files belong to the chat from now on (indexed in the background).
    let documents = files.compactMap { appState.knowledge.add($0, threadID: target.id) }
    let records = documents.map {
      FileRecord(id: $0.id, name: $0.name, kind: $0.kindRaw, pageCount: $0.pageCount)
    }
    Task {
      let accepted = await appState.send(
        text: text, imageData: image, audioFileURL: audioURL, files: records,
        webSearch: webSearch, in: target)
      if accepted {
        recorder.discard()
      } else {
        // Nothing was sent: give the user their input back (the recording
        // was never discarded).
        for document in documents { appState.knowledge.delete(document) }
        if draft.isEmpty { draft = text }
        if pendingImage == nil { pendingImage = image }
        if pendingFiles.isEmpty { pendingFiles = files }
        searchWeb = webSearch
      }
    }
  }
}

private extension View {
  /// Banners sit just under the toolbar, inset like the composer.
  func bannerInsets() -> some View {
    padding(.horizontal, Theme.Spacing.md).padding(.top, Theme.Spacing.tight)
  }
}
