import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// One-way command & mode channel between ``ChatView`` and ``ChatComposerView``.
///
/// ``ChatView`` writes ``command`` only inside user-action closures and reads only ``searchWeb``
/// (for ``AmbientBackdrop``). Keystrokes, attachments, dictation, and recording stay completely
/// isolated inside ``ChatComposerView`` so typing never triggers layout or diffing in the message
/// list.
@MainActor
@Observable
final class ComposerBridge {
  enum Command {
    case insertStarter(String)
    case openFiles
    case edit(ChatTurn)
    case dismissKeyboard
    case cancelDictation
  }

  struct Request: Equatable {
    let id = UUID()
    let command: Command

    static func == (lhs: Request, rhs: Request) -> Bool { lhs.id == rhs.id }
  }

  /// Web search toggle for the next message (shared with `ChatView` solely to tint the backdrop).
  var searchWeb = false
  /// Next command from `ChatView` to `ChatComposerView` (never read in `ChatView.body`).
  var pendingRequest: Request?

  func send(_ command: Command) {
    pendingRequest = Request(command: command)
  }

  func takeRequest() -> Command? {
    defer { pendingRequest = nil }
    return pendingRequest?.command
  }
}

/// The chat composer and its preparing, editing, and pending-attachment bars. Owns all draft,
/// attachment, picker, dictation, recording, and focus state so typing never invalidates
/// ``ChatView``'s message list.
struct ChatComposerView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let thread: ChatThread?
  let bridge: ComposerBridge
  var onStopReading: () -> Void
  var onOpenVoice: () -> Void
  var makeThread: () -> ChatThread

  @State private var draft = ""
  @State private var pendingImage: Data?
  @State private var pendingImageID = UUID()
  @State private var pendingThumbnail: CGImage?
  @State private var photoItem: PhotosPickerItem?
  @State private var recorder = AudioRecorder()
  @State private var liveDictation = LiveDictation()
  @State private var showPhotos = false
  @State private var showCamera = false
  @State private var showFiles = false
  @State private var showScanner = false
  private struct PendingFile: Identifiable, Equatable {
    let id = UUID()
    let document: ExtractedDocument
  }

  /// Files read and waiting to be sent with the next message.
  @State private var pendingFiles: [PendingFile] = []
  /// Bumped when the chat changes: async work still running belongs to the chat it started in.
  @State private var composerGeneration = 0
  /// Active file-extraction tasks keyed by ID so finished reads prune and chat switches reset immediately.
  @State private var fileReads: [UUID: Task<Void, Never>] = [:]
  @State private var photoLoadTask: Task<Void, Never>?
  /// The recording in progress is dictation (text for the composer), not a voice message.
  @State private var dictating = false
  /// The user message being edited in the composer, if any.
  @State private var editingTurn: ChatTurn?
  @FocusState private var inputFocused: Bool

  private var isReadingFiles: Bool { !fileReads.isEmpty }

  private struct AuxiliaryBarState: Equatable {
    var isPreparing: Bool
    var isEditing: Bool
    var pendingFileCount: Int
    var isReadingFiles: Bool
    var hasImage: Bool
    var isRecording: Bool
    var isListening: Bool
    var hasVoiceClip: Bool
  }

  private var auxiliaryBarState: AuxiliaryBarState {
    AuxiliaryBarState(
      isPreparing: appState.preparingStatus != nil && appState.preparingThreadID == thread?.id,
      isEditing: editingTurn != nil,
      pendingFileCount: pendingFiles.count,
      isReadingFiles: isReadingFiles,
      hasImage: pendingImage != nil,
      isRecording: recorder.isRecording,
      isListening: liveDictation.isListening,
      hasVoiceClip: voiceMessageURL != nil)
  }

  private var barTransition: AnyTransition {
    reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
  }

  /// What the next message does; tints the composer chrome, pills and send button.
  private var mode: Theme.Mode {
    bridge.searchWeb ? .search : appState.options.enableThinking ? .think : .chat
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 0) {
        preparingBar
        editingBar
        pendingBar
      }
      .appAnimation(Theme.Motion.panel, value: auxiliaryBarState)
      inputBar
    }
    .alert(
      "Microphone access denied",
      isPresented: Binding(
        get: { recorder.permissionDenied || liveDictation.permissionDenied },
        set: { shown in
          if !shown {
            recorder.permissionDenied = false
            liveDictation.permissionDenied = false
          }
        })
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Enable microphone access in Settings to send voice messages.")
    }
    .onChange(of: recorder.isRecording) { wasRecording, isRecording in
      if wasRecording, !isRecording, dictating { finishDictation() }
    }
    .onChange(of: recorder.errorMessage) { _, message in
      if let message { appState.generationError = "Recording failed: \(message)" }
    }
    .onChange(of: bridge.pendingRequest) {
      if let command = bridge.takeRequest() { handle(command) }
    }
    .onChange(of: thread?.id) { old, _ in
      // Switching chats (not saving a new one) starts with a clean composer.
      guard old != nil else { return }
      editingTurn = nil
      draft = ""
      setPendingImage(nil)
      // Files, the Search toggle and a voice message belong to the chat they were added in.
      composerGeneration += 1
      for task in fileReads.values { task.cancel() }
      fileReads.removeAll()
      photoLoadTask?.cancel()
      photoLoadTask = nil
      pendingFiles = []
      bridge.searchWeb = false
      dictating = false
      liveDictation.cancel()
      recorder.discard()
      takeRequestedDraft()
      takeRequestedCamera()
    }
    .onChange(of: AppRouter.shared.draftRequested, initial: true) {
      // A new chat opened for it applies it on the chat change above.
      if thread == nil { takeRequestedDraft() }
    }
    .onChange(of: AppRouter.shared.cameraRequested, initial: true) {
      if thread == nil { takeRequestedCamera() }
    }
    .onDisappear {
      composerGeneration += 1
      for task in fileReads.values { task.cancel() }
      fileReads.removeAll()
      photoLoadTask?.cancel()
      photoLoadTask = nil
      dictating = false
      liveDictation.cancel()
      recorder.stop()
    }
    .task(id: pendingImageID) {
      guard let data = pendingImage else {
        pendingThumbnail = nil
        return
      }
      // 256 pixels cover the 44-point square at 3x, whatever the photo's shape.
      let decoded = await Task.detached(priority: .userInitiated) {
        ImageDownsampler.cgImage(from: data, maxPixels: 256)
      }.value
      guard !Task.isCancelled else { return }
      pendingThumbnail = decoded
    }
    .onAppear {
      // Debug and Bench builds only (2026-11-17).
      #if DEBUG || BENCH
        // The bench driver (docs/HARNESS.md): a long prompt arrives as the composer's draft, and
        // the driver taps the real send button. Typing 3K characters through XCUITest is slow.
        let environment = ProcessInfo.processInfo.environment
        if thread == nil, draft.isEmpty, let prompt = environment["AGELLO_BENCH_DRAFT"] {
          draft = prompt
          // Without a driver (`scripts/bench-direct.sh`, `scripts/phone-bench.sh`): the app sends
          // the draft itself once the model is ready, so a reply can be traced with no UI
          // automation attached. Nobody touches the phone meanwhile, so the screen stays on.
          if environment["AGELLO_BENCH_AUTOSEND"] == "1" {
            Platform.keepScreenOn()
            Task { @MainActor in
              for _ in 0..<600 where appState.engineState != .ready {
                try? await Task.sleep(for: .milliseconds(500))
              }
              // What the driver's Think pill does: "1" on, "0" off. Like the pill, it marks the
              // options changed, so the send applies them first; the setting alone doesn't reach
              // the conversation the launch loaded.
              if let think = environment["AGELLO_BENCH_THINK"],
                appState.options.enableThinking != (think == "1")
              {
                appState.options.enableThinking = think == "1"
                appState.scheduleApplyOptions()
              }
              // Heat slows decoding by up to a fifth (docs/HARNESS.md, H2): wait up to ten
              // minutes for the phone to cool, as the driver's BENCH_COOL does.
              if environment["AGELLO_BENCH_COOL"] == "1" {
                for _ in 0..<120 where ProcessInfo.processInfo.thermalState != .nominal {
                  try? await Task.sleep(for: .seconds(5))
                }
              }
              send()
            }
          }
        }
      #endif
      // UI tests: the system file picker can't be driven, so attach a sample.
      if thread == nil, pendingFiles.isEmpty,
        let sample = SampleDocuments.named(in: ProcessInfo.processInfo.arguments)
      {
        pendingFiles = [PendingFile(document: sample)]
      }
    }
  }

  private func handle(_ command: ComposerBridge.Command) {
    switch command {
    case .insertStarter(let starter):
      draft = starter
      inputFocused = true
    case .openFiles:
      showFiles = true
    case .edit(let turn):
      startEditing(turn)
    case .dismissKeyboard:
      inputFocused = false
    case .cancelDictation:
      liveDictation.cancel()
    }
  }

  // MARK: - Editing & preparing bars

  private func setPendingImage(_ data: Data?) {
    pendingImage = data
    pendingThumbnail = nil
    pendingImageID = UUID()
  }

  private func startEditing(_ turn: ChatTurn) {
    editingTurn = turn
    draft = turn.text
    setPendingImage(nil)
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
      .transition(barTransition)
    }
  }

  /// "Reading report.pdf · part 3 of 11" while files are prepared.
  @ViewBuilder
  private var preparingBar: some View {
    if let status = appState.preparingStatus, appState.preparingThreadID == thread?.id {
      HStack(spacing: Theme.Spacing.sm) {
        ProgressView().controlSize(.small).tint(mode.tint)
        Text(status)
          .font(.footnote)
          .foregroundStyle(Theme.Text.secondary)
          .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("chat.preparing")
        Spacer()
      }
      .padding(.horizontal, Theme.Spacing.xl)
      .padding(.vertical, Theme.Spacing.xs)
      .transition(barTransition)
    }
  }

  // MARK: - Pending attachments

  @ViewBuilder
  private var pendingBar: some View {
    if !pendingFiles.isEmpty || isReadingFiles {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: Theme.Spacing.sm) {
          ForEach(pendingFiles) { pending in
            let file = pending.document
            FileChip(
              name: file.name, kind: file.kind, pageCount: file.isPaged ? file.pages.count : 0,
              cut: file.truncated
            ) {
              Haptics.selection()
              pendingFiles.removeAll { $0.id == pending.id }
            }
          }
          if isReadingFiles {
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
      .transition(barTransition)
    }
    if pendingImage != nil || recorder.finishedURL != nil || recorder.isRecording || liveDictation.isListening {
      HStack(spacing: Theme.Spacing.sm) {
        if pendingImage != nil {
          Button {
            Haptics.selection()
            setPendingImage(nil)
          } label: {
            Group {
              if let thumbnail = pendingThumbnail {
                Image(decorative: thumbnail, scale: 1)
                  .resizable()
                  .scaledToFill()
              } else {
                Rectangle().fill(Theme.Surface.stage)
              }
            }
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
        if liveDictation.isListening {
          ComposerElapsedBadge(mode: .dictation)
            .id("live-dictation")
        } else if recorder.isRecording {
          ComposerElapsedBadge(
            mode: dictating ? .dictation : .voiceMessage(maxDuration: AudioRecorder.maxDuration)
          )
          .id(dictating ? "fallback-dictation" : "voice-recording")
          if !dictating {
            Button("Stop") {
              Haptics.selection()
              recorder.stop()
            }
            .font(.system(.footnote, weight: .semibold))
            .foregroundStyle(Theme.Status.critical)
            .buttonStyle(.plain)
            .frame(minHeight: Theme.Size.target)
            .contentShape(.rect)
            .accessibilityIdentifier("composer.stopVoice")
          }
        } else if recorder.finishedURL != nil, !dictating, !appState.isTranscribing {
          Button {
            Haptics.selection()
            recorder.discard()
          } label: {
            Label("Voice ready (\(Int(recorder.elapsed))s)", systemImage: "waveform")
              .font(.system(.caption, weight: .medium))
              .foregroundStyle(Theme.Text.primary)
              .padding(.horizontal, Theme.Spacing.md)
              .frame(minHeight: Theme.Size.pill)
              .background { LitTintBackground(shape: Capsule(), tint: Theme.Mode.voice.tint, strength: .pill) }
              .frame(minHeight: Theme.Size.target)
              .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .accessibilityHint("Removes the voice message")
        }
        Spacer()
        if pendingImage != nil || recorder.finishedURL != nil {
          Button("Clear") {
            Haptics.selection()
            setPendingImage(nil)
            recorder.discard()
          }
          .font(.system(.footnote, weight: .semibold))
          .foregroundStyle(Theme.Text.secondary)
          .buttonStyle(.plain)
          .frame(minHeight: Theme.Size.target)
          .contentShape(.rect)
        }
      }
      .padding(.horizontal, Theme.Spacing.lg)
      .padding(.vertical, Theme.Spacing.xs)
      .transition(barTransition)
    }
  }

  // MARK: - Composer chrome

  /// The composer: the message on top with attach, Think, Search, mic, and Send / Voice / Stop
  /// integrated symmetrically inside one centered Liquid Glass card (using `LitCircleButtonStyle`
  /// on the primary action so there is zero glass-on-glass nesting).
  private var inputBar: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      ComposerField(text: $draft, focus: $inputFocused)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.top, Theme.Spacing.sm)
        .accessibilityIdentifier("chat.input")
      HStack(spacing: Theme.Spacing.sm) {
        attachMenu
        // Titled pills when they fit, icons otherwise; priority over the spacer so a title
        // never truncates to "T…".
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
    .appAnimation(Theme.Motion.modeCrossfade, value: mode, kind: .dissolve)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("chat.composer")
    .padding(.horizontal, Theme.Spacing.snug)
    .padding(.bottom, Theme.Spacing.tight)
    .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
    .onChange(of: photoItem) { _, item in
      guard let item else { return }
      photoItem = nil
      photoLoadTask?.cancel()
      let generation = composerGeneration
      photoLoadTask = Task {
        do {
          guard let data = try await item.loadTransferable(type: Data.self) else {
            if generation == composerGeneration, !Task.isCancelled {
              appState.generationError = String(localized: "Couldn't load the selected photo.")
            }
            return
          }
          let prepared = await Task.detached(priority: .userInitiated) {
            ImagePreparer.prepare(data) ?? data
          }.value
          guard generation == composerGeneration, !Task.isCancelled else { return }
          setPendingImage(prepared)
        } catch {
          guard generation == composerGeneration, !Task.isCancelled, !(error is CancellationError) else {
            return
          }
          appState.generationError = error.localizedDescription
        }
      }
    }
    .captureSources(camera: $showCamera, scanner: $showScanner) { data in
      setPendingImage(data)
      inputFocused = true
    } onScan: { pages in
      read { try await DocumentIngestor.extract(scannedPages: pages, name: scanName()) }
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

  /// A link's message (`agello://ask`) in the composer, for the user to send.
  private func takeRequestedDraft() {
    guard let text = AppRouter.shared.draftRequested else { return }
    AppRouter.shared.draftRequested = nil
    draft = text
    inputFocused = true
  }

  /// Action Button / Control Center / Siri "Snap & Ask" camera launch.
  private func takeRequestedCamera() {
    guard AppRouter.shared.cameraRequested else { return }
    AppRouter.shared.cameraRequested = false
    if CaptureSources.cameraAvailable {
      showCamera = true
    } else {
      appState.notice = String(localized: "Camera isn't available on this device.")
    }
  }

  /// Read a file in the background into the pending attachments of the chat it was picked in.
  private func read(_ extract: @escaping @Sendable () async throws -> ExtractedDocument) {
    let generation = composerGeneration
    let readID = UUID()
    let task = Task {
      defer {
        if generation == composerGeneration {
          fileReads.removeValue(forKey: readID)
        }
      }
      let extraction = Task.detached(priority: .userInitiated) { try await extract() }
      do {
        let document = try await withTaskCancellationHandler {
          try await extraction.value
        } onCancel: {
          extraction.cancel()
        }
        guard generation == composerGeneration else { return }
        pendingFiles.append(PendingFile(document: document))
      } catch {
        guard generation == composerGeneration, !(error is CancellationError) else { return }
        appState.generationError = error.localizedDescription
      }
    }
    fileReads[readID] = task
  }

  private func scanName() -> String {
    "Scan \(Date.now.formatted(date: .abbreviated, time: .shortened))"
  }

  private var attachDisabled: Bool {
    appState.isBusy || editingTurn != nil
      || liveDictation.isListening || liveDictation.isStarting
      || recorder.isRecording || recorder.isStarting
      || appState.isTranscribing
  }

  private var attachMenu: some View {
    Menu {
      Button("Camera", systemImage: "camera") { showCamera = true }
        .disabled(!CaptureSources.cameraAvailable)
      Button("Photos", systemImage: "photo.on.rectangle") { showPhotos = true }
      Button("Files", systemImage: "folder") { showFiles = true }
      Button("Scan document", systemImage: "doc.viewfinder") { showScanner = true }
        .disabled(!CaptureSources.scannerAvailable)
      PasteButton(payloadType: PastedContent.self) { items in
        handlePaste(items)
      }
      Button("Voice message", systemImage: "waveform") {
        onStopReading()
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
      bridge.searchWeb.toggle()
      Haptics.selection()
    } label: {
      Label("Search", systemImage: "globe")
    }
    .buttonStyle(ModePillStyle(isOn: bridge.searchWeb, tint: Theme.Mode.search.tint, iconOnly: iconOnly))
    .disabled(appState.isBusy || editingTurn != nil)
    .accessibilityLabel("Search")
    .accessibilityValue(bridge.searchWeb ? "On" : "Off")
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

  /// Dictation: live ANE streaming words into the composer (zero E4B lock), falling back to
  /// Gemma audio recording when no matching Apple Speech asset is installed.
  private var micButton: some View {
    let listening = liveDictation.isListening || (recorder.isRecording && dictating)
    return Button(action: toggleDictation) {
      Group {
        if appState.isTranscribing {
          ProgressView()
        } else {
          Image(systemName: listening ? "checkmark" : "mic")
            .contentTransition(.symbolEffect(.replace))
            .appAnimation(Theme.Motion.stateChange, value: listening, kind: .dissolve)
        }
      }
    }
    .buttonStyle(MicToggleButtonStyle(isListening: listening))
    .disabled(
      appState.isTranscribing || liveDictation.isStarting || recorder.isStarting
        || (recorder.isRecording && !dictating)
    )
    .accessibilityLabel(listening ? "Finish dictation" : "Dictate")
    .accessibilityValue(appState.isTranscribing ? "Transcribing" : listening ? "Listening" : "")
    .accessibilityIdentifier("composer.mic")
  }

  private func handlePaste(_ items: [PastedContent]) {
    var firstImageData: Data?
    var texts: [String] = []
    for item in items {
      switch item {
      case .image(let data):
        if firstImageData == nil { firstImageData = data }
      case .text(let string):
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { texts.append(trimmed) }
      }
    }
    if let data = firstImageData {
      photoLoadTask?.cancel()
      let generation = composerGeneration
      photoLoadTask = Task {
        let prepared = await Task.detached(priority: .userInitiated) {
          ImagePreparer.prepare(data) ?? data
        }.value
        guard generation == composerGeneration, !Task.isCancelled else { return }
        setPendingImage(prepared)
        Haptics.selection()
      }
    }
    let pasted = texts.joined(separator: "\n")
    if !pasted.isEmpty {
      draft = draft.isEmpty ? pasted : "\(draft)\n\(pasted)"
      inputFocused = true
      if firstImageData == nil { Haptics.selection() }
    }
  }

  private func toggleDictation() {
    if liveDictation.isListening {
      Haptics.selection()
      let generation = composerGeneration
      Task {
        await liveDictation.stop()
        if generation == composerGeneration { inputFocused = true }
      }
      return
    }
    if recorder.isRecording && dictating {
      Haptics.selection()
      recorder.stop()  // transcribed in onChange(of: isRecording)
      return
    }
    guard !liveDictation.isStarting, !recorder.isStarting else { return }
    Haptics.selection()
    onStopReading()
    let generation = composerGeneration
    let baseDraft = draft
    Task {
      let startedLive = await liveDictation.start(
        baseDraft: baseDraft,
        currentDraft: { draft }
      ) { updated in
        guard generation == composerGeneration else { return }
        draft = updated
      }
      guard generation == composerGeneration else { return }
      if startedLive || liveDictation.permissionDenied { return }
      // Fallback: Gemma 4 audio transcription when ANE Speech asset isn't installed (or fake mic).
      guard !appState.isBusy else {
        appState.notice = String(localized: "Finish or stop the current reply before offline dictation.")
        return
      }
      dictating = true
      await recorder.toggle()
      guard generation == composerGeneration else {
        dictating = false
        recorder.discard()
        return
      }
      if !recorder.isRecording { dictating = false }
    }
  }

  /// The dictation recording became text: append it to the draft.
  private func finishDictation() {
    dictating = false
    guard let url = recorder.takeFinishedURL() else { return }
    let generation = composerGeneration
    Task {
      defer { try? FileManager.default.removeItem(at: url) }
      let text = await appState.transcribe(url)
      guard generation == composerGeneration else { return }
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
    if !canSend, !recorder.isRecording, !recorder.isStarting,
      !liveDictation.isListening, !liveDictation.isStarting, !appState.isTranscribing,
      editingTurn == nil
    {
      return .voice
    }
    return .send
  }

  /// Send, voice mode, or stop: integrated inside the composer bar, morphing glyph and lit tint cleanly.
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
      case .stop:
        Haptics.selection()
        appState.stop()
      case .voice:
        Haptics.selection()
        onOpenVoice()
      case .send:
        send()
      }
    } label: {
      Image(systemName: action.symbol)
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(LitCircleButtonStyle(tint: tint))
    .disabled(action == .send && !canSend)
    .appAnimation(Theme.Motion.stateChange, value: action, kind: .dissolve)
    .appAnimation(Theme.Motion.modeCrossfade, value: mode, kind: .dissolve)
    .accessibilityLabel(action.label)
    .accessibilityIdentifier(action.identifier)
  }

  /// A finished voice message (not a dictation being transcribed).
  private var voiceMessageURL: URL? {
    dictating || appState.isTranscribing ? nil : recorder.finishedURL
  }

  private var canSend: Bool {
    guard !isReadingFiles, !recorder.isRecording, !recorder.isStarting,
      !liveDictation.isListening, !liveDictation.isStarting, !appState.isTranscribing
    else { return false }
    return draft.contains { !$0.isWhitespace && !$0.isNewline }
      || pendingImage != nil || voiceMessageURL != nil || !pendingFiles.isEmpty
  }

  private func send() {
    onStopReading()
    let generation = composerGeneration
    if let editingTurn, let thread {
      let text = draft
      draft = ""
      self.editingTurn = nil
      inputFocused = false
      Haptics.send()
      Task {
        let accepted = await appState.edit(editingTurn, text: text, in: thread)
        if !accepted, generation == composerGeneration, draft.isEmpty {
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
    let webSearch = bridge.searchWeb
    draft = ""
    setPendingImage(nil)
    pendingFiles = []
    bridge.searchWeb = false
    inputFocused = false
    Haptics.send()
    let target = thread ?? makeThread()
    // Files belong to the chat from now on (indexed in the background).
    let added = files.compactMap { pending in
      appState.knowledge.add(pending.document, threadID: target.id).map { (pending.document, $0) }
    }
    let documents = added.map(\.1)
    let records = added.map { file, document in
      FileRecord(
        id: document.id, name: document.name, kind: document.kindRaw, pageCount: document.pageCount,
        cut: file.truncated ? true : nil)
    }
    Task {
      let accepted = await appState.send(
        text: text, imageData: image, audioFileURL: audioURL, files: records,
        webSearch: webSearch, in: target)
      if accepted {
        if generation == composerGeneration { recorder.discard() }
      } else {
        // Nothing was sent: remove orphaned documents and restore input only if still on the same chat.
        for document in documents { appState.knowledge.delete(document) }
        guard generation == composerGeneration else { return }
        if draft.isEmpty { draft = text }
        if pendingImage == nil { setPendingImage(image) }
        if pendingFiles.isEmpty { pendingFiles = files }
        bridge.searchWeb = webSearch
      }
    }
  }
}

/// Clipboard payload accepted by the composer's `PasteButton` (images or plain text).
private enum PastedContent: Transferable, Sendable {
  case image(Data)
  case text(String)

  static var transferRepresentation: some TransferRepresentation {
    DataRepresentation(importedContentType: .image) { data in
      .image(data)
    }
    ProxyRepresentation(importing: Self.text)
  }
}

/// Single parameterized mic button style so `mic ↔ checkmark` keeps identity for symbol replace.
private struct MicToggleButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let isListening: Bool

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(.body, weight: isListening ? .semibold : .medium))
      .dynamicTypeSize(...DynamicTypeSize.accessibility1)
      .foregroundStyle(isEnabled ? Theme.Text.primary : Theme.Text.tertiary)
      .frame(width: Theme.Size.target, height: Theme.Size.target)
      .background {
        if isListening {
          LitTintBackground(shape: Circle(), tint: Theme.Status.critical, isEnabled: isEnabled)
        } else {
          QuietBackground(shape: Circle(), isPressed: configuration.isPressed)
        }
      }
      .contentShape(Circle())
      .scaleEffect(!reduceMotion && isListening && configuration.isPressed ? 0.94 : 1)
      .appAnimation(Theme.Motion.press, value: configuration.isPressed)
      .appAnimation(Theme.Motion.stateChange, value: isListening, kind: .dissolve)
  }
}

/// Isolated 1 Hz elapsed indicator for live dictation and voice message recording so
/// `ChatComposerView.body` never re-diffs on every 4 Hz recorder timer tick.
private struct ComposerElapsedBadge: View {
  enum Mode: Equatable {
    case dictation
    case voiceMessage(maxDuration: TimeInterval)
  }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let mode: Mode
  @State private var startedAt = Date.now

  var body: some View {
    TimelineView(.periodic(from: startedAt, by: 1.0)) { context in
      let elapsed = max(0, context.date.timeIntervalSince(startedAt))
      let wholeSeconds = Int(elapsed)
      HStack(spacing: Theme.Spacing.tight) {
        if mode == .dictation {
          Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
            .accessibilityHidden(true)
        } else {
          Image(systemName: "record.circle")
            .symbolEffect(.pulse, isActive: !reduceMotion)
            .accessibilityHidden(true)
        }
        Text(labelText(elapsed: elapsed))
          .contentTransition(.numericText())
          .appAnimation(Theme.Motion.stateChange, value: wholeSeconds, kind: .dissolve)
      }
      .font(.system(.caption, weight: .medium))
      .monospacedDigit()
      .foregroundStyle(Theme.Text.primary)
      .padding(.horizontal, Theme.Spacing.md)
      .frame(minHeight: Theme.Size.pill)
      .background { LitTintBackground(shape: Capsule(), tint: Theme.Status.critical, strength: .pill) }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("composer.recording")
    }
  }

  private func labelText(elapsed: TimeInterval) -> String {
    switch mode {
    case .dictation:
      String(format: String(localized: "Listening… %.0fs"), elapsed)
    case .voiceMessage(let maxDuration):
      String(format: "%.0fs / %.0fs", min(elapsed, maxDuration), maxDuration)
    }
  }
}
