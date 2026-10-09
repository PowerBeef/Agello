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
  /// Files being read right now.
  @State private var readingFiles = 0
  @State private var reader = SpeechReader()
  /// The user message being edited in the composer, if any.
  @State private var editingTurn: ChatTurn?
  @FocusState private var inputFocused: Bool
  @Namespace private var inputNamespace

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
    .background(ambientBackground)
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
    }
    .alert(
      "Microphone access denied",
      isPresented: $recorder.permissionDenied
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text("Enable microphone access in Settings to send voice messages.")
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
      // Switching chats (not saving a new one) starts with a clean composer.
      guard old != nil else { return }
      reader.stop()
      editingTurn = nil
      draft = ""
      pendingImage = nil
    }
    .onDisappear { reader.stop() }
    .onAppear {
      // UI tests: the system file picker can't be driven, so attach a sample.
      if thread == nil, pendingFiles.isEmpty,
        ProcessInfo.processInfo.arguments.contains("--uitest-sample-file")
      {
        pendingFiles = [
          ExtractedDocument(
            name: "trip-notes.md", kind: .text, byteCount: 120,
            pages: [
              "Hiking trip notes.\n\nThe trailhead parking opens at 6 am. Bring a tent, a stove, "
                + "and three litres of water per person."
            ])
        ]
      }
    }
  }

  private var ambientBackground: some View {
    LinearGradient(
      colors: [.accentColor.opacity(0.07), .clear],
      startPoint: .top, endPoint: .center
    )
    .ignoresSafeArea()
  }

  // MARK: - Banners

  @ViewBuilder
  private var engineBanner: some View {
    switch appState.engineState {
    case .idle:
      if !appState.isMock, !appState.store.isDownloaded(appState.store.activeSpec) {
        HStack {
          Text("Download \(appState.store.activeSpec.displayName) to start chatting.")
            .font(.caption)
            .accessibilityIdentifier("chat.banner.download")
          Spacer()
          Button("Models") { showLibrary = true }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(DS.padMD)
        .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusBanner))
        .padding(.horizontal)
        .padding(.top, 6)
      }
    case .loading(let progress):
      HStack {
        ProgressView().controlSize(.small)
        Text(progress).font(.caption).accessibilityIdentifier("chat.banner.loading")
        Spacer()
      }
      .padding(DS.padMD)
      .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusBanner))
      .padding(.horizontal)
      .padding(.top, 6)
    case .failed(let message):
      HStack {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.red)
        Text(message).font(.caption).accessibilityIdentifier("chat.banner.failed")
        Spacer()
        Button("Retry") { Task { await appState.ensureEngineLoaded() } }
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
      .padding(DS.padMD)
      .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusBanner))
      .padding(.horizontal)
      .padding(.top, 6)
    case .ready, .generating:
      EmptyView()
    }
  }

  @ViewBuilder
  private var noticeBanner: some View {
    if let error = appState.generationError {
      HStack {
        Image(systemName: "info.circle")
        Text(error).font(.caption).accessibilityIdentifier("chat.banner.notice")
        Spacer()
        Button("Dismiss") { appState.generationError = nil }
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
      .padding(DS.padMD)
      .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusBanner))
      .padding(.horizontal)
      .padding(.top, 6)
    }
  }

  // MARK: - Messages

  private func messagesList(_ turns: [ChatTurn], versions: [VersionKey: [ChatTurn]]) -> some View {
    Group {
      if turns.isEmpty {
        emptyState
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(spacing: DS.spaceLG) {
              ForEach(turns) { turn in
                MessageBubbleView(
                  turn: turn, isStreaming: isLiveBubble(turn, in: turns),
                  toolStatus: appState.toolStatus,
                  versions: versions[VersionKey(turn)] ?? [],
                  actions: actions(for: turn))
                  .id(turn.id)
              }
              Color.clear.frame(height: 1).id("bottom")
            }
            .padding()
          }
          .onChange(of: scrollSignature(turns)) {
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
          }
        }
      }
    }
  }

  /// A new chat: a short greeting, nothing else to read or tap.
  private var emptyState: some View {
    VStack {
      Spacer()
      Text(greeting)
        .font(.title2.weight(.semibold))
        .multilineTextAlignment(.center)
        .accessibilityIdentifier("chat.empty")
      Spacer()
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 24)
    .contentShape(.rect)
    .onTapGesture { inputFocused = false }
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
      isBusy: appState.isGenerating,
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
        withAnimation(.snappy) { appState.selectVersion(version, in: thread) }
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
      HStack(spacing: 8) {
        Image(systemName: "pencil")
        Text("Editing message")
          .font(.caption)
          .accessibilityIdentifier("chat.editing")
        Spacer()
        Button("Cancel", action: cancelEditing)
          .font(.caption)
          .buttonStyle(.glass)
          .controlSize(.small)
          .accessibilityIdentifier("chat.editing.cancel")
      }
      .padding(.horizontal)
      .padding(.vertical, 4)
    }
  }

  private func scrollSignature(_ turns: [ChatTurn]) -> String {
    let last = turns.last
    return "\(turns.count)-\(last?.text.count ?? 0)-\(last?.thought.count ?? 0)"
  }

  private func isLiveBubble(_ turn: ChatTurn, in turns: [ChatTurn]) -> Bool {
    appState.generatingThreadID == thread?.id && turn.id == turns.last?.id && !turn.isUser
  }

  // MARK: - Pending attachments

  /// "Reading report.pdf · part 3 of 11" while files are prepared.
  @ViewBuilder
  private var preparingBar: some View {
    if let status = appState.preparingStatus, appState.generatingThreadID == thread?.id {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text(status)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .accessibilityIdentifier("chat.preparing")
        Spacer()
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 4)
    }
  }

  @ViewBuilder
  private var pendingBar: some View {
    if !pendingFiles.isEmpty || readingFiles > 0 {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(Array(pendingFiles.enumerated()), id: \.offset) { index, file in
            FileChip(name: file.name, kind: file.kind, pageCount: file.isPaged ? file.pages.count : 0) {
              pendingFiles.remove(at: index)
            }
          }
          if readingFiles > 0 {
            HStack(spacing: 6) {
              ProgressView().controlSize(.mini)
              Text("Reading…").font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .accessibilityIdentifier("composer.readingFile")
          }
        }
        .padding(.horizontal)
      }
      .padding(.vertical, 4)
    }
    if pendingImage != nil || recorder.finishedURL != nil || recorder.isRecording {
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
          if let data = pendingImage, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
              .resizable()
              .scaledToFill()
              .frame(width: DS.controlTarget, height: DS.controlTarget)
              .clipShape(.rect(cornerRadius: DS.radiusThumb))
              .onTapGesture { pendingImage = nil }
          }
          if recorder.isRecording {
            Label(
              String(format: "%.0fs / %.0fs", recorder.elapsed, AudioRecorder.maxDuration),
              systemImage: "record.circle"
            )
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(.red), in: .capsule)
          } else if recorder.finishedURL != nil {
            Label("Voice ready (\(Int(recorder.elapsed))s)", systemImage: "waveform")
              .font(.caption)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .glassEffect(.regular, in: .capsule)
              .onTapGesture { recorder.discard() }
          }
          Spacer()
          if pendingImage != nil || recorder.finishedURL != nil {
            Button("Clear") {
              pendingImage = nil
              recorder.discard()
            }
            .font(.caption)
            .buttonStyle(.glass)
            .controlSize(.small)
          }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
      }
    }
  }

  // MARK: - Composer

  /// ChatGPT-style composer: the message on top; attachments, Think, the
  /// microphone and Send/Stop below, in one glass card. You can type the
  /// next message while a reply is streaming.
  private var inputBar: some View {
    VStack(alignment: .leading, spacing: 6) {
      TextField("Ask anything", text: $draft, axis: .vertical)
        .lineLimit(1...8)
        .textFieldStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.top, 6)
        .focused($inputFocused)
        .accessibilityIdentifier("chat.input")
      HStack(spacing: DS.spaceMD) {
        attachMenu
        thinkToggle
        Spacer(minLength: 0)
        micButton
        actionButton
      }
    }
    .padding(10)
    .glassEffect(.regular, in: .rect(cornerRadius: 26))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("chat.composer")
    .padding(.horizontal, 12)
    .padding(.bottom, 6)
    .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
    .onChange(of: photoItem) { _, item in
      Task {
        if let item, let data = try? await item.loadTransferable(type: Data.self) {
          pendingImage = ImagePreparer.prepare(data) ?? data
        }
        photoItem = nil
      }
    }
    .fullScreenCover(isPresented: $showCamera) {
      CameraPicker { data in
        pendingImage = ImagePreparer.prepare(data) ?? data
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

  /// Read a file in the background into the pending attachments.
  private func read(_ extract: @escaping @Sendable () async throws -> ExtractedDocument) {
    readingFiles += 1
    Task {
      defer { readingFiles -= 1 }
      do {
        pendingFiles.append(try await Task.detached(priority: .userInitiated) { try await extract() }.value)
      } catch {
        appState.generationError = error.localizedDescription
      }
    }
  }

  private func scanName() -> String {
    "Scan \(Date.now.formatted(date: .abbreviated, time: .shortened))"
  }

  private var attachDisabled: Bool { appState.isGenerating || editingTurn != nil }

  private var attachMenu: some View {
    Menu {
      Button("Camera", systemImage: "camera") { showCamera = true }
        .disabled(!CameraPicker.isAvailable)
      Button("Photos", systemImage: "photo.on.rectangle") { showPhotos = true }
      Button("Files", systemImage: "folder") { showFiles = true }
      Button("Scan document", systemImage: "doc.viewfinder") { showScanner = true }
        .disabled(!DocumentScanner.isAvailable)
    } label: {
      Image(systemName: "plus")
        .font(.body.weight(.medium))
        .frame(width: DS.controlTarget, height: DS.controlTarget)
        .glassEffect(.regular.interactive(), in: .circle)
    }
    .disabled(attachDisabled)
    .accessibilityLabel("Add photos and files")
    .accessibilityIdentifier("composer.attach")
  }

  /// Reasoning for the next messages (applies before the next send).
  private var thinkToggle: some View {
    let isOn = appState.options.enableThinking
    return Button {
      appState.options.enableThinking.toggle()
      appState.scheduleApplyOptions()
      Haptics.complete()
    } label: {
      Label("Think", systemImage: "lightbulb")
        .font(.subheadline.weight(.medium))
        .foregroundStyle(isOn ? Color.accentColor : .secondary)
        .padding(.horizontal, 12)
        .frame(height: 36)
        .glassEffect(
          isOn ? .regular.tint(.accentColor.opacity(0.25)).interactive() : .regular.interactive(),
          in: .capsule)
    }
    .buttonStyle(.plain)
    .disabled(appState.isGenerating)
    .accessibilityValue(isOn ? "On" : "Off")
    .accessibilityIdentifier("composer.think")
  }

  private var micButton: some View {
    Button(action: { Task { await recorder.toggle() } }) {
      Image(systemName: recorder.isRecording ? "stop.fill" : "mic")
        .frame(width: DS.controlTarget, height: DS.controlTarget)
        .glassEffect(
          recorder.isRecording ? .regular.tint(.red).interactive() : .regular.interactive(),
          in: .circle)
    }
    .disabled(attachDisabled)
    .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Record voice message")
    .accessibilityIdentifier("composer.mic")
  }

  @ViewBuilder
  private var actionButton: some View {
    if appState.isGenerating {
      Button(action: { appState.stop() }) {
        Image(systemName: "stop.fill")
          .frame(width: DS.controlTarget, height: DS.controlTarget)
          .glassEffect(.regular.tint(.red).interactive(), in: .circle)
          .glassEffectID("action", in: inputNamespace)
      }
      .accessibilityLabel("Stop generating")
      .accessibilityIdentifier("chat.stop")
    } else {
      Button(action: send) {
        Image(systemName: "arrow.up")
          .font(.headline)
          .frame(width: DS.controlTarget, height: DS.controlTarget)
          .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
          .glassEffectID("action", in: inputNamespace)
      }
      .disabled(!canSend)
      .opacity(canSend ? 1 : 0.45)
      .accessibilityLabel("Send")
      .accessibilityIdentifier("chat.send")
    }
  }

  private var canSend: Bool {
    guard readingFiles == 0 else { return false }
    return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || pendingImage != nil || recorder.finishedURL != nil || !pendingFiles.isEmpty
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
    let audioURL = recorder.finishedURL
    let files = pendingFiles
    draft = ""
    pendingImage = nil
    pendingFiles = []
    inputFocused = false
    Haptics.send()
    let target = thread ?? appState.newThread(in: context)
    // Files belong to the chat from now on (indexed in the background).
    let documents = files.compactMap { appState.knowledge.add($0, threadID: target.id) }
    let records = documents.map {
      FileRecord(id: $0.id, name: $0.name, kind: $0.kindRaw, pageCount: $0.pageCount)
    }
    Task {
      let accepted = await appState.send(
        text: text, imageData: image, audioFileURL: audioURL, files: records, in: target)
      if accepted {
        recorder.discard()
      } else {
        // Nothing was sent: give the user their input back (the recording
        // was never discarded).
        for document in documents { appState.knowledge.delete(document) }
        if draft.isEmpty { draft = text }
        if pendingImage == nil { pendingImage = image }
        if pendingFiles.isEmpty { pendingFiles = files }
      }
    }
  }
}
