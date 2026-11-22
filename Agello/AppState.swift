import Foundation
import SwiftData

/// Main-actor UI state: engine lifecycle, generation pipeline, options. Split by area across
/// `AppState+Reply.swift` (files, a reply's stream, Stop, background), `AppState+Web.swift`,
/// `AppState+Chats.swift` (chats, memory, projects) and `AppState+Benchmark.swift`; the members
/// those files share are internal, for AppState's own use (2026-11-16, at SwiftLint's 1,500 lines).
@Observable
@MainActor
final class AppState {
  let store: ModelStore
  let engine: any ChatEngineProtocol

  var engineState: ChatEngineState = .idle
  var resolved: ResolvedInference?
  /// The most vision tokens per image the loaded model accepts (Settings offers no more).
  private(set) var visionTokenLimit = VisualDetail.defaultLimit
  var options = InferenceOptions() {
    didSet { persistOptions() }
  }
  var enableTools = true {
    didSet { UserDefaults.standard.set(enableTools, forKey: "enableTools") }
  }
  /// About you / how to respond; merged into the system prompt.
  var personalization = Personalization() {
    didSet {
      UserDefaults.standard.set(try? JSONEncoder().encode(personalization), forKey: "personalization")
    }
  }

  /// Options as the engine receives them: the system prompt includes the
  /// user's personalization, plus runtime tool availability for the active chat.
  var effectiveOptions: InferenceOptions {
    var effective = options
    effective.systemPrompt = SystemPrompt.compose(
      base: options.systemPrompt, personalization: personalization, project: activeProject,
      memories: memoryEnabled ? memoryTexts() : [], current: SystemPrompt.CurrentInfo(webSettings: webSettings))
    effective.webSearchTool = webSettings.allowed && webSettings.automatic
    effective.workspaceFileTools = activeThreadHasDocuments
    return effective
  }

  /// Web search settings (provider, automatic mode, master switch).
  var webSettings = WebSearchSettings() {
    didSet {
      UserDefaults.standard.set(try? JSONEncoder().encode(webSettings), forKey: "webSearch")
      // Automatic mode changes the tools the conversation offers, and both switches what the
      // system prompt says about current information.
      if SystemPrompt.CurrentInfo(webSettings: oldValue) != SystemPrompt.CurrentInfo(webSettings: webSettings) {
        scheduleApplyOptions()
      }
    }
  }
  @ObservationIgnored private(set) lazy var webResearch = WebResearch(knowledge: knowledge)

  /// The system prompt and tool set the engine's conversation was built with; a
  /// different one (project, memories, personalization, or tool set) means a rebuild.
  @ObservationIgnored private var appliedSystemPrompt: String?
  @ObservationIgnored private var appliedToolSetKey: String?
  /// Whether the active chat or its project currently has attached files.
  @ObservationIgnored var activeThreadHasDocuments = false

  /// Memory: learn lasting facts from the user's messages and add them to
  /// the system prompt. Off by default.
  var memoryEnabled = false {
    didSet {
      UserDefaults.standard.set(memoryEnabled, forKey: "memoryEnabled")
      memoriesChanged()
    }
  }

  /// The project of the chat the engine's conversation belongs to.
  @ObservationIgnored var activeProject: ProjectContext?
  /// A new chat started from a project page joins that project on its
  /// first message.
  var newChatProjectID: UUID?
  var selectedThreadID: UUID? {
    didSet {
      UserDefaults.standard.set(selectedThreadID?.uuidString, forKey: "selectedThreadID")
    }
  }

  var isGenerating = false
  /// Preparing a reply (web search, reading files): the composer shows Stop
  /// from the first step until the reply ends.
  var isPreparing = false
  /// The chat a reply is being prepared for (its status line).
  var preparingThreadID: UUID?
  /// A reply is being prepared or written.
  var isBusy: Bool { isGenerating || isPreparing }
  /// The chat whose reply is streaming (only it shows the live cursor and
  /// can't be deleted mid-reply).
  var generatingThreadID: UUID?
  /// What a running tool is doing ("Searched the web for …"), shown in the
  /// live reply; nil when no tool has run in the current reply.
  var toolStatus: String?
  var generationError: String?
  /// Something worth knowing that isn't a failure: older messages dropped to fit, a reply cut at
  /// its limit or stopped in the background, a web search that found nothing.
  var notice: String?
  var isBenchmarking = false
  var benchmarkReport: BenchmarkReport? {
    didSet {
      if let report = benchmarkReport,
        let data = try? JSONEncoder().encode(report)
      {
        UserDefaults.standard.set(data, forKey: "benchmarkReport")
      }
    }
  }

  var modelContext: ModelContext? {
    didSet { knowledge.modelContext = modelContext }
  }
  /// Attached files: storage, indexing, and retrieval.
  let knowledge: KnowledgeBase
  /// What's happening before a reply starts (e.g. "Reading report.pdf ·
  /// part 3 of 11"); nil otherwise.
  var preparingStatus: String? {
    didSet {
      if let preparingStatus { BackgroundWork.shared.update(subtitle: preparingStatus) }
    }
  }
  /// Reading files before a reply (cancelled by Stop).
  @ObservationIgnored var preparationTask: Task<FileContextResult?, Never>?

  /// Thread whose text history the native conversation currently holds. Any assignment means the
  /// conversation was rebuilt or let go, so the files it had read are forgotten.
  @ObservationIgnored var conversationThreadID: UUID? {
    didSet { heldFiles = nil }
  }
  /// The files (whole or summarized) the native conversation read with an earlier message of
  /// this chat: follow-ups send only the question while it holds them (``FileContext/heldKey(_:)``).
  /// A reseed replays the turns' text without them, so it ends with any change of conversation.
  @ObservationIgnored var heldFiles: (threadID: UUID, key: String)?
  /// The memories chosen for a chat by meaning (``selectMemories(for:firstMessage:)``).
  @ObservationIgnored var memorySelection: (threadID: UUID, texts: [String])?
  /// True while the native conversation holds no turns (fresh load / empty reseed).
  @ObservationIgnored private var conversationIsEmpty = true
  /// Tail of the engine-lifecycle queue (see ``serialized(_:)``).
  @ObservationIgnored private var lifecycleTail: Task<Void, Never>?
  @ObservationIgnored private var applyOptionsTask: Task<Void, Never>?
  /// Settings changed mid-reply; applied once the reply finishes.
  @ObservationIgnored private var pendingOptionsApply = false
  /// A settings change is waiting for its debounced apply.
  @ObservationIgnored private var optionsDirty = false
  /// Bumped by Stop: a reply still being prepared checks it before each step.
  @ObservationIgnored var stopCount = 0
  /// True while `stopAndDrain()` is waiting for native GPU work to finish before ending `BackgroundWork`.
  @ObservationIgnored var drainingBackgroundWork = false

  @ObservationIgnored private var memoryPressure: MemoryPressureMonitor?

  init(useMockEngine: Bool = false, store: ModelStore? = nil) {
    self.store = store ?? ModelStore()
    self.engine =
      useMockEngine ? MockChatEngine() : LiteRTChatEngine()
    self.knowledge = KnowledgeBase(store: self.store, useHashingEmbedder: useMockEngine)
    let saved = UserDefaults.standard.decoded(InferenceOptions.self, forKey: "inferenceOptions")
    let launched = InferenceOptions.launch(saved: saved, arguments: ProcessInfo.processInfo.arguments)
    self.options = launched
    if launched != saved { UserDefaults.standard.set(try? JSONEncoder().encode(launched), forKey: "inferenceOptions") }
    self.enableTools = UserDefaults.standard.object(forKey: "enableTools") as? Bool ?? true
    self.memoryEnabled = UserDefaults.standard.bool(forKey: "memoryEnabled")
    if let decoded = UserDefaults.standard.decoded(WebSearchSettings.self, forKey: "webSearch") {
      self.webSettings = decoded
    }
    if let decoded = UserDefaults.standard.decoded(Personalization.self, forKey: "personalization") {
      self.personalization = decoded
    }
    if let raw = UserDefaults.standard.string(forKey: "selectedThreadID") {
      self.selectedThreadID = UUID(uuidString: raw)
    }
    if let data = UserDefaults.standard.data(forKey: "benchmarkReport"),
      let report = try? JSONDecoder().decode(BenchmarkReport.self, from: data)
    {
      self.benchmarkReport = report
    }
    // iOS sends memory warnings long before it terminates apps (E4B kept
    // working with ~0.8 GB left in the 8 GB simulation), so only stop a reply
    // when memory is actually nearly exhausted (also checked while streaming).
    installWebSearchTool()
    installWorkspaceTools()
    // Files attached before the embedding model arrived get indexed once it does.
    self.store.onModelReady = { [weak self] model in
      if model == ModelCatalog.embeddingGemma.id { self?.knowledge.indexPending() }
    }
    memoryPressure = MemoryPressureMonitor { [weak self] level in
      guard let self else { return }
      Log.lifecycle.warning(
        "memory \(level.rawValue, privacy: .public) (\(MemoryProbe.summary, privacy: .public))")
      Task { @MainActor in await self.relieveMemoryPressure(level: level) }
    }
  }

  /// The system says memory is low: give back what ``MemoryPolicy`` says for that level.
  func relieveMemoryPressure(level: MemoryPressureLevel) async {
    let relief = MemoryPolicy.action(level: level)
    // Freed memory that malloc kept counts toward the limit: hand it back first.
    MemoryProbe.returnFreedMemory()
    if relief.contains(.stopReplyIfExhausted) { stopIfMemoryIsExhausted() }
    if relief.contains(.releaseEmbedder) { await knowledge.releaseMemory() }
  }

  var isMock: Bool { engine is MockChatEngine }

  /// Stop a running reply (keeping its text) if the app is about to run out
  /// of memory.
  func stopIfMemoryIsExhausted() {
    guard isGenerating, DeviceProfile.shouldStopForMemory(availableBytes: MemoryProbe.availableBytes())
    else { return }
    Log.lifecycle.error("low memory: stopping reply (\(MemoryProbe.summary, privacy: .public))")
    stop()
    generationError = "Reply stopped to free memory. Closing other apps can help."
  }

  private func persistOptions() {
    if let data = try? JSONEncoder().encode(options) {
      UserDefaults.standard.set(data, forKey: "inferenceOptions")
    }
  }

  // MARK: - Engine lifecycle

  /// Run engine-lifecycle work (load, switch, options, benchmark, delete) one
  /// at a time. The engine actor is reentrant across its long awaits, so
  /// without this two loads could interleave and briefly hold two engines.
  /// Never call from inside an operation that is already serialized.
  func serialized<T: Sendable>(
    _ operation: @escaping @MainActor @Sendable () async -> T
  ) async -> T {
    let previous = lifecycleTail
    let task = Task { @MainActor in
      await previous?.value
      return await operation()
    }
    lifecycleTail = Task { @MainActor in _ = await task.value }
    return await task.value
  }

  /// After a helper: unless it kept the engine's conversation (our runtime,
  /// memory allowing), it left an empty one, so the chat is rebuilt from
  /// history on its next message.
  func afterHelper() async {
    guard await !engine.lastHelperKeptConversation else { return }
    conversationThreadID = nil
    conversationIsEmpty = true
  }

  /// Load the active model if needed. Returns true when ready to generate.
  @discardableResult
  func ensureEngineLoaded() async -> Bool {
    await serialized { await self.loadIfNeeded() }
  }

  private func isActiveModelLoaded() async -> Bool {
    guard await engine.isLoaded, await engine.currentModelID == store.activeModelID else {
      return false
    }
    switch engineState {
    case .ready, .generating: return true
    case .idle, .loading, .failed: return false
    }
  }

  private func loadIfNeeded() async -> Bool {
    if await isActiveModelLoaded() { return true }
    // Never tear down an engine that is mid-reply or benchmarking.
    if isGenerating || isBenchmarking { return false }
    let spec = store.activeSpec
    let url: URL
    if isMock {
      // The scripted engine never reads the file.
      url = store.localURL(for: spec) ?? FileManager.default.temporaryDirectory
    } else {
      guard store.isDownloaded(spec), let local = store.localURL(for: spec) else {
        engineState = .failed(message: "\(spec.displayName) is not downloaded.")
        return false
      }
      url = local
    }
    engineState = .loading(progress: "Loading \(spec.displayName)…")
    // `load` replaces the native conversation with an empty one.
    conversationThreadID = nil
    conversationIsEmpty = true
    do {
      let plan = try await engine.load(
        spec: spec, modelURL: url, options: effectiveOptions,
        memoryBytes: DeviceProfile.current.physicalMemoryBytes,
        enableTools: enableTools
      )
      resolved = plan
      visionTokenLimit = await engine.maxVisionTokenBudget ?? VisualDetail.defaultLimit
      let applied = effectiveOptions
      appliedSystemPrompt = applied.systemPrompt
      appliedToolSetKey = applied.toolSetKey
      engineState = .ready
      return true
    } catch {
      let message = (error as? ChatError)?.displayMessage ?? error.localizedDescription
      engineState = .failed(message: message)
      return false
    }
  }

  func unloadEngine() async {
    await engine.unload()
    resolved = nil
    conversationThreadID = nil
    conversationIsEmpty = true
    engineState = .idle
  }

  /// Delete a downloaded model, unloading it first if the engine holds it.
  func deleteModel(_ spec: ModelSpec) async {
    await serialized {
      if await self.engine.currentModelID == spec.id {
        guard !self.isGenerating, !self.isBenchmarking else {
          self.generationError = "Wait for the current reply to finish before deleting the model."
          return
        }
        await self.unloadEngine()
      }
      if spec.id == ModelCatalog.embeddingGemma.id { await self.knowledge.resetEmbedder() }
      self.store.deleteModel(spec)
    }
  }

  // MARK: - Options

  /// Settings entry point: coalesces rapid edits (steppers, toggles, text)
  /// into a single apply instead of one engine reload per tap.
  func scheduleApplyOptions() {
    optionsDirty = true
    applyOptionsTask?.cancel()
    applyOptionsTask = Task {
      try? await Task.sleep(for: .milliseconds(600))
      guard !Task.isCancelled else { return }
      await self.applyCurrentOptions()
    }
  }

  /// Apply the current options: cheap reseed when only conversation-level
  /// settings changed, full reload for backend / KV-cache changes.
  /// `forSend`: the message being prepared applies them first (a reply being prepared otherwise
  /// defers them, so its conversation can't change between preparing it and sending).
  func applyCurrentOptions(forSend: Bool = false) async {
    await serialized { await self.applyOptionsLocked(forSend: forSend) }
  }

  private func applyOptionsLocked(forSend: Bool = false) async {
    optionsDirty = false
    // Not loaded: options are picked up by the next load. Never load a
    // multi-GB model just because a setting changed.
    guard await engine.isLoaded else { return }
    if isGenerating || isBenchmarking || (isPreparing && !forSend) {
      pendingOptionsApply = true
      return
    }
    let newOptions = effectiveOptions
    if let live = engine as? LiteRTChatEngine {
      if await live.engineSettingsChanged(for: newOptions) {
        Log.engine.info("options: engine-level change, full reload")
        await unloadEngine()
        _ = await loadIfNeeded()
      } else {
        let history = selectedThreadHistory()
        Log.engine.info("options: conversation-level change, reseed \(history.count) turns")
        do {
          resolved = try await live.updateConversationOptions(
            newOptions, enableTools: enableTools, history: history)
          appliedSystemPrompt = newOptions.systemPrompt
          appliedToolSetKey = newOptions.toolSetKey
          conversationThreadID = selectedThreadID
          conversationIsEmpty = history.isEmpty
        } catch {
          generationError = (error as? ChatError)?.displayMessage ?? error.localizedDescription
        }
      }
    } else if let mock = engine as? MockChatEngine {
      resolved = InferencePlanner.resolve(
        options: newOptions, model: store.activeModelID,
        memoryBytes: DeviceProfile.current.physicalMemoryBytes)
      await mock.applyConversationOptions(newOptions)
      appliedSystemPrompt = newOptions.systemPrompt
      appliedToolSetKey = newOptions.toolSetKey
    }
  }

  private func selectedThreadHistory() -> [(role: ChatRole, text: String)] {
    guard let context = modelContext, let id = selectedThreadID else { return [] }
    let descriptor = FetchDescriptor<ChatThread>(predicate: #Predicate { $0.id == id })
    return (try? context.fetch(descriptor))?.first?.textHistory ?? []
  }

  // MARK: - Threads ↔ native conversation

  /// Make `thread` the conversation the native engine holds. Loads the model
  /// if needed and replays the thread's text history, so context never bleeds
  /// between chats (or is lost on relaunch).
  @discardableResult
  func activate(_ thread: ChatThread) async -> Bool {
    selectedThreadID = thread.id
    let threadID = thread.id
    // Leaving a chat: its helpers run now, before the switch rebuilds the conversation anyway.
    if hasPendingHelpers, conversationThreadID != threadID { await runPendingHelpers() }
    let history = thread.textHistory
    if let first = thread.orderedTurns.first(where: \.isUser)?.text {
      await selectMemories(for: thread, firstMessage: first)
    }
    return await serialized {
      await self.prepareConversation(threadID: threadID, history: history)
    }
  }

  private func prepareConversation(
    threadID: UUID, history: [(role: ChatRole, text: String)]
  ) async -> Bool {
    guard await loadIfNeeded() else { return false }
    // Never swap the conversation out from under a live reply.
    if isGenerating { return false }
    // Refresh workspace file availability & project context before deciding whether to rebuild.
    activeProject = projectContext(for: threadID)
    if let context = modelContext {
      let desc = FetchDescriptor<ChatThread>(predicate: #Predicate { $0.id == threadID })
      if let thread = (try? context.fetch(desc))?.first {
        activeThreadHasDocuments = !documents(for: thread).isEmpty
      }
    }
    let desired = effectiveOptions
    let conversationConfigChanged =
      desired.systemPrompt != appliedSystemPrompt || desired.toolSetKey != appliedToolSetKey
    if conversationThreadID == threadID, !conversationConfigChanged { return true }
    if conversationConfigChanged {
      Log.engine.info("conversation config changed: rebuild with \(history.count) turns")
      do {
        if let live = engine as? LiteRTChatEngine {
          resolved = try await live.updateConversationOptions(
            desired, enableTools: enableTools, history: history)
        } else {
          if let mock = engine as? MockChatEngine {
            await mock.applyConversationOptions(desired)
          }
          try await engine.reseed(history: history)
        }
      } catch {
        generationError = (error as? ChatError)?.displayMessage ?? error.localizedDescription
        return false
      }
      appliedSystemPrompt = desired.systemPrompt
      appliedToolSetKey = desired.toolSetKey
      conversationThreadID = threadID
      conversationIsEmpty = history.isEmpty
      return true
    }
    if !(history.isEmpty && conversationIsEmpty) {
      Log.engine.info("reseed for thread switch: \(history.count) turns")
      do {
        try await engine.reseed(history: history)
      } catch {
        generationError = (error as? ChatError)?.displayMessage ?? error.localizedDescription
        return false
      }
    }
    conversationThreadID = threadID
    conversationIsEmpty = history.isEmpty
    return true
  }

  // MARK: - Generation

  /// Send a message in `thread`. Returns false when the message was not
  /// accepted (nothing was persisted), so the caller can restore the draft.
  @discardableResult
  /// `remembering` is what the memory helper may read, when it isn't the whole message: a shared
  /// item's own text was written by someone else, so only what the user typed counts.
  func send(
    text: String, imageData: Data?, audioFileURL: URL?, files: [FileRecord] = [],
    webSearch: Bool = false, remembering: String? = nil, in thread: ChatThread
  ) async -> Bool {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty || imageData != nil || audioFileURL != nil || !files.isEmpty else {
      return false
    }
    return await generate(
      prompt: prompt, imageData: imageData, audioFileURL: audioFileURL, in: thread,
      history: nil, webSearch: webSearch, remembering: remembering
    ) {
      let turn = ChatTurn(
        role: .user, text: prompt, imageData: imageData, hasAudio: audioFileURL != nil)
      if !files.isEmpty || webSearch { turn.parts = MessageParts(files: files, webSearch: webSearch) }
      thread.append(turn)
      if thread.title == "New chat" {
        thread.title = Self.title(
          prompt: prompt, hasImage: imageData != nil, fileName: files.first?.name)
      }
    }
  }

  /// Whether `reply`'s prompt can be answered again. Voice recordings aren't
  /// kept, so replies to voice-only messages can't be regenerated.
  func canRegenerate(_ reply: ChatTurn, in thread: ChatThread) -> Bool {
    guard !reply.isUser, let prompt = promptTurn(of: reply, in: thread) else { return false }
    return !prompt.hasAudio || !prompt.text.isEmpty
  }

  /// Answer `reply`'s prompt again as a new version of the reply (the old
  /// one stays reachable through the version switcher). It samples with a seed of its own;
  /// `seed` fixes it, for runs that must repeat (docs/CLI.md).
  @discardableResult
  func regenerate(_ reply: ChatTurn, in thread: ChatThread, seed: Int? = nil) async -> Bool {
    guard canRegenerate(reply, in: thread), let prompt = promptTurn(of: reply, in: thread) else {
      return false
    }
    return await generate(
      prompt: prompt.text, imageData: prompt.imageData, audioFileURL: nil, in: thread,
      history: thread.textHistory(before: prompt), replacing: reply,
      webSearch: prompt.parts.webSearch, samplingSeed: seed ?? Int.random(in: 1...Int(Int32.max))
    ) {}
  }

  /// Replace `userTurn` with `text` as a new version and answer it. The
  /// original message and its replies stay reachable as the older version.
  @discardableResult
  func edit(_ userTurn: ChatTurn, text: String, in thread: ChatThread) async -> Bool {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let files = userTurn.parts.files
    let webSearch = userTurn.parts.webSearch
    guard userTurn.isUser, !prompt.isEmpty || userTurn.imageData != nil || !files.isEmpty else {
      return false
    }
    return await generate(
      prompt: prompt, imageData: userTurn.imageData, audioFileURL: nil, in: thread,
      history: thread.textHistory(before: userTurn), webSearch: webSearch
    ) {
      let turn = ChatTurn(role: .user, text: prompt, imageData: userTurn.imageData)
      if !files.isEmpty || webSearch { turn.parts = MessageParts(files: files, webSearch: webSearch) }
      thread.addVersion(turn, of: userTurn)
    }
  }

  /// Show `turn`'s version (and the conversation after it).
  func selectVersion(_ turn: ChatTurn, in thread: ChatThread) {
    guard !isGenerating || generatingThreadID != thread.id else { return }
    thread.selectBranch(through: turn)
    try? modelContext?.save()
    // The engine holds the previous branch: rebuild it on the next message.
    if conversationThreadID == thread.id { conversationThreadID = nil }
  }

  private func promptTurn(of reply: ChatTurn, in thread: ChatThread) -> ChatTurn? {
    guard let parentID = reply.parentID else { return nil }
    return thread.turns.first { $0.id == parentID && $0.isUser }
  }

  /// Shared generation path. `history` is the text before the new prompt
  /// when the engine must be rebuilt from an earlier point (regenerate,
  /// edit); nil continues the visible branch. Once the message is accepted,
  /// `persist` attaches the user turn (if any), then the reply is added —
  /// as a new version of `replacing` when given.
  private func generate(
    prompt: String, imageData: Data?, audioFileURL: URL?, in thread: ChatThread,
    history rewound: [(role: ChatRole, text: String)]?, replacing: ChatTurn? = nil,
    webSearch: Bool = false, samplingSeed: Int? = nil, remembering: String? = nil, persist: () -> Void
  ) async -> Bool {
    guard !isGenerating, !isPreparing, !isBenchmarking else { return false }
    guard let context = modelContext else { return false }
    generationError = nil
    notice = nil
    ReplyTrace.begin(prompt: prompt, options: options, resolved: resolved, search: webSearch, tools: enableTools)
    let stopsAtStart = stopCount
    var stopped: Bool { stopCount != stopsAtStart }
    isPreparing = true
    preparingThreadID = thread.id
    defer {
      isPreparing = false
      preparingThreadID = nil
      preparingStatus = nil
      if !drainingBackgroundWork {
        BackgroundWork.shared.end(success: generationError == nil)
      }
    }
    // A just-changed setting (e.g. the composer's Think toggle) applies to
    // this message, not after it.
    if optionsDirty {
      applyOptionsTask?.cancel()
      await applyCurrentOptions(forSend: true)
    }
    guard !stopped else { return false }

    let threadID = thread.id
    selectedThreadID = threadID

    // Files in this chat (and its project): build what the model reads.
    var enginePrompt = prompt
    // A voice turn is the recording; the model reads how to answer it with it.
    if voiceModeActive, audioFileURL != nil, prompt.isEmpty { enginePrompt = VoiceText.instruction }
    var sources: [SourceRecord] = []
    var filesFollowUp: (key: String, prompt: String)?
    let documents = documents(for: thread)
    if !documents.isEmpty {
      guard await ensureEngineLoaded() else { return false }
      let task = Task { await self.assembleFileContext(question: prompt, documents: documents) }
      preparationTask = task
      let assembled = await task.value
      preparationTask = nil
      preparingStatus = nil
      guard let assembled else { return false }  // stopped while reading
      enginePrompt = assembled.prompt
      sources = assembled.sources
      filesFollowUp = assembled.followUp
    }

    let history = rewound ?? thread.textHistory
    // With many memories, the chat's are chosen by meaning before its conversation is built.
    await selectMemories(
      for: thread, firstMessage: thread.orderedTurns.first(where: \.isUser)?.text ?? prompt)

    // Web search the user asked for: plan queries, search, read, rank.
    if webSearch, webSettings.allowed {
      guard await ensureEngineLoaded() else { return false }
      let filePrompt = documents.isEmpty ? nil : enginePrompt
      let firstIndex = sources.count + 1
      // Files and web results share the room for material instead of each taking it all.
      let fileTokens = filePrompt.map(ContextBudget.estimateTokens) ?? 0
      let task = Task { () -> WebOutcome in
        await self.searchWeb(
          question: prompt, history: history, firstIndex: firstIndex, fileTokens: fileTokens)
      }
      webTask = task
      let outcome = await task.value
      webTask = nil
      preparingStatus = nil
      switch outcome {
      case .cancelled:
        return false
      case .failed(let message):
        notice = message
      case .notNeeded:
        break
      case .found(let findings):
        enginePrompt = WebContext.prompt(
          question: prompt, sources: findings.sources, filePrompt: filePrompt)
        filesFollowUp = filesFollowUp.map {
          ($0.key, WebContext.prompt(question: prompt, sources: findings.sources, filePrompt: $0.prompt))
        }
        sources += findings.sources.map(\.record)
      }
    }

    // One step, so no helper or settings change can empty the conversation between preparing
    // it and checking that this message fits (it would be answered without its history).
    let promptToFit = enginePrompt
    let followUp = filesFollowUp
    let prepared: PreparedSend = await serialized {
      // Rewinding: the engine holds later turns that must not stay in context.
      if rewound != nil, self.conversationThreadID == threadID { self.conversationThreadID = nil }
      guard await self.prepareConversation(threadID: threadID, history: history) else {
        return .notReady
      }
      // Regenerate: a reply that differs from the one it replaces. A rebuilt conversation repeats
      // its reply (seed 0) and MTP decodes greedily (probe 18), so this one samples with a seed
      // of its own; the next message rebuilds the usual conversation.
      if let samplingSeed {
        do {
          try await self.engine.reseedSampling(history: history, seed: samplingSeed)
        } catch {
          self.conversationThreadID = nil
          let chatError = error as? ChatError ?? .underlying(message: error.localizedDescription)
          return .rejected(chatError.displayMessage)
        }
      }
      // The engine may have degraded to text-only (model without executors).
      if imageData != nil, self.resolved?.enableVision != true {
        return .rejected("This session is text-only, so images are disabled.")
      }
      if audioFileURL != nil, self.resolved?.enableAudio != true {
        return .rejected("This session is text-only, so voice messages are disabled.")
      }
      // Keep the KV cache from overflowing (native heap corruption → crash):
      // trim the replayed history if this message + a reply wouldn't fit.
      do {
        // The conversation already read these files: only the question goes, unless fitting
        // trimmed it, which rebuilds it from the turns' text, without them.
        var trimmedForFollowUp = false
        if let followUp, self.heldFiles?.threadID == threadID, self.heldFiles?.key == followUp.key {
          trimmedForFollowUp = try await self.engine.fitContext(
            text: followUp.prompt, imageData: imageData, audioFileURL: audioFileURL, history: history)
          if !trimmedForFollowUp { return .ready(trimmed: false, prompt: followUp.prompt) }
        }
        let trimmed = try await self.engine.fitContext(
          text: promptToFit, imageData: imageData, audioFileURL: audioFileURL, history: history)
        let finalPrompt =
          trimmed
          ? await self.promptWithEvictedRecall(
            promptToFit: promptToFit, query: prompt, imageData: imageData,
            audioFileURL: audioFileURL, history: history)
          : promptToFit
        return .ready(trimmed: trimmed || trimmedForFollowUp, prompt: finalPrompt)
      } catch {
        // Fitting may have emptied the conversation on its way to this error: reseed first.
        self.conversationThreadID = nil
        let chatError = error as? ChatError ?? .underlying(message: error.localizedDescription)
        return .rejected(chatError.displayMessage)
      }
    }
    switch prepared {
    case .notReady:
      return false
    case .rejected(let message):
      generationError = message
      return false
    case .ready(let trimmed, let fitted):
      enginePrompt = fitted
      if trimmed {
        conversationThreadID = threadID
        notice = String(
          localized: "Older messages were dropped from the model's memory to fit its context window.")
      }
    }
    guard !stopped else { return false }

    // Placeholder model turn, mutated live as chunks stream in.
    persist()
    let reply = ChatTurn(role: .model)
    if !sources.isEmpty { reply.parts = MessageParts(sources: sources) }
    if let replacing {
      thread.addVersion(reply, of: replacing)
    } else {
      thread.append(reply)
    }
    try? context.save()
    ReplyTrace.reply(id: reply.id, sources: sources.count)

    isGenerating = true
    isPreparing = false
    generatingThreadID = threadID
    engineState = .generating
    conversationIsEmpty = false

    WebSourcesRecorder.reset()
    toolSourceOffset = sources.count
    let stream = engine.send(text: enginePrompt, imageData: imageData, audioFileURL: audioFileURL)
    // Voice mode: the reply starts with the user's transcript.
    let voiceTurn =
      voiceModeActive && audioFileURL != nil
      ? thread.turns.first { $0.id == reply.parentID && $0.isUser } : nil
    await consume(stream, into: reply, context: context, voiceTurn: voiceTurn)
    ReplyTrace.end(reply: reply.isDeleted ? nil : reply, error: generationError, notice: notice)
    // A sampling conversation (Regenerate) serves only this reply.
    if samplingSeed != nil { conversationThreadID = nil }
    // The conversation read the files with this message: the next ones send only the question.
    if let filesFollowUp, generationError == nil, conversationThreadID == threadID {
      heldFiles = (threadID, filesFollowUp.key)
    }
    // Sources found by the automatic web_search tool during the reply.
    let toolSources = WebSourcesRecorder.drain()
    if !toolSources.isEmpty {
      var parts = reply.parts
      parts.sources += toolSources
      reply.parts = parts
      try? context.save()
    }

    isGenerating = false
    generatingThreadID = nil
    engineState = .ready
    if pendingOptionsApply {
      pendingOptionsApply = false
      await applyCurrentOptions()
    }
    queueHelpers(after: reply, message: remembering ?? voiceTurn?.text ?? prompt, in: thread)
    SpotlightIndex.index([thread])
    return true
  }

  /// The conversation step of a send, run as one serialized operation.
  private enum PreparedSend: Sendable {
    /// The model couldn't load or the conversation couldn't be rebuilt (the error is set).
    case notReady
    case rejected(String)
    /// `prompt` is what was fitted: the full file prompt, or the follow-up's.
    case ready(trimmed: Bool, prompt: String)
  }

  /// What became of a helper the scheduler ran.
  enum HelperOutcome<Value: Sendable>: Sendable {
    /// Something else needed the engine (a send, a load): try again later.
    case skipped
    /// Stopped (Stop, the app moved to the background): try again later.
    case cancelled
    case finished(Value?)
  }

  /// Runs one helper on the engine unless a send owns it, then marks the chat for a rebuild if
  /// the helper didn't keep its conversation.
  func runHelper<Value: Sendable>(
    _ work: @escaping @Sendable (any ChatEngineProtocol) async throws -> Value
  ) async -> HelperOutcome<Value> {
    await serialized {
      // Never between a send's preparation and its reply.
      guard !self.isGenerating, !self.isPreparing, await self.engine.isLoaded else { return .skipped }
      let outcome: HelperOutcome<Value>
      do {
        outcome = .finished(try await work(self.engine))
      } catch ChatError.generationCancelled {
        outcome = .cancelled
      } catch {
        Log.engine.error("helper failed: \(LogText.errorKind(error), privacy: .public)")
        outcome = (error as? ChatError) == GPUGate.closedError ? .cancelled : .finished(nil)
      }
      await self.afterHelper()
      return outcome
    }
  }

  /// The provisional title (the first words of the first message) still waits for a
  /// model-written one, and the chat has a finished exchange to name it from.
  private func needsTitle(_ thread: ChatThread) -> (prompt: String, provisional: String)? {
    let path = thread.orderedTurns
    guard path.count >= 2, let first = path.first, first.isUser, !path[1].isUser else { return nil }
    let reply = path[1]
    guard !reply.text.isEmpty, !reply.text.hasPrefix(ChatTurn.errorPrefix) else { return nil }
    let provisional = Self.title(
      prompt: first.text, hasImage: first.imageData != nil, fileName: first.parts.files.first?.name)
    guard thread.title == provisional else { return nil }  // renamed by the user
    let prompt = HelperTasks.titlePrompt(
      user: first.text.isEmpty ? provisional : first.text, reply: reply.text)
    return (prompt, provisional)
  }

  /// Replace a chat's provisional title with a short model-written one. Returns false when it
  /// must be tried again later.
  @discardableResult
  func generateTitleIfNeeded(for thread: ChatThread) async -> Bool {
    guard let needed = needsTitle(thread) else { return true }
    let prompt = needed.prompt
    let provisional = needed.provisional
    let outcome: HelperOutcome<Data> = await runHelper { engine in
      try await engine.helperJSON(
        prompt: prompt, schemaJSON: HelperTasks.titleSchema,
        maxOutputTokens: HelperTasks.titleMaxOutputTokens)
    }
    guard case .finished(let output) = outcome else { return false }
    guard let output, let title = HelperTasks.parseTitle(output), thread.title == provisional
    else {
      Log.engine.error(
        "title helper unusable: \(output.map { String(decoding: $0, as: UTF8.self) } ?? "nil", privacy: .private)")
      return true
    }
    thread.title = title
    try? modelContext?.save()
    SpotlightIndex.index([thread])
    return true
  }

  /// Chat title from the first message; attachment-only messages get a label.
  static func title(prompt: String, hasImage: Bool, fileName: String? = nil) -> String {
    if !prompt.isEmpty { return String(prompt.prefix(42)) }
    if let fileName { return String(fileName.prefix(42)) }
    return hasImage ? "Photo" : "Voice message"
  }

  // MARK: - Helpers after a reply

  /// A memory lookup waiting to run.
  private struct PendingMemory {
    let message: String
    let replyID: UUID
    let threadID: UUID
  }

  /// Title and memory work waiting for a quiet moment. A helper uses the GPU the next message
  /// would want, and short of memory it empties the chat's conversation, so helpers don't run
  /// right after a reply: they run after a short pause or when the user leaves the chat, in the
  /// foreground, outside voice mode, and never while a send is pending.
  @ObservationIgnored private var pendingTitles: [UUID] = []
  @ObservationIgnored private var pendingMemories: [PendingMemory] = []
  @ObservationIgnored var helperTimer: Task<Void, Never>?
  /// The app is active; GPU work waits for it (see ``GPUGate``).
  @ObservationIgnored var isInForeground = true

  var hasPendingHelpers: Bool { !pendingTitles.isEmpty || !pendingMemories.isEmpty }

  private var helpersCanRun: Bool {
    isInForeground && !isBusy && !isTranscribing && !isBenchmarking && !voiceModeActive
  }

  private func queueHelpers(after reply: ChatTurn, message: String, in thread: ChatThread) {
    if needsTitle(thread) != nil, !pendingTitles.contains(thread.id) {
      pendingTitles.append(thread.id)
    }
    if memoryEnabled, HelperTasks.shouldLookForMemories(message), !reply.text.isEmpty,
      !reply.text.hasPrefix(ChatTurn.errorPrefix)
    {
      pendingMemories.append(PendingMemory(message: message, replyID: reply.id, threadID: thread.id))
    }
    scheduleHelpers()
  }

  /// Runs the waiting helpers once the chat has been quiet for a while.
  func scheduleHelpers() {
    helperTimer?.cancel()
    guard hasPendingHelpers else { return }
    let delay = HelperTasks.idleDelay
    helperTimer = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.runPendingHelpers()
    }
  }

  /// Runs the waiting title and memory helpers now, if nothing else needs the engine (leaving
  /// a chat, the idle timer, tests). Work that couldn't run stays queued.
  func runPendingHelpers() async {
    helperTimer?.cancel()
    while helpersCanRun, let item = pendingMemories.first {
      pendingMemories.removeFirst()
      guard let thread = thread(withID: item.threadID),
        let reply = thread.turns.first(where: { $0.id == item.replyID })
      else { continue }
      if await !learnMemories(from: item.message, reply: reply, in: thread) {
        pendingMemories.insert(item, at: 0)
        break
      }
    }
    while helpersCanRun, let threadID = pendingTitles.first {
      pendingTitles.removeFirst()
      guard let thread = thread(withID: threadID) else { continue }
      if await !generateTitleIfNeeded(for: thread) {
        pendingTitles.insert(threadID, at: 0)
        break
      }
    }
    if hasPendingHelpers, !helpersCanRun { scheduleHelpers() }
  }

  private func thread(withID id: UUID) -> ChatThread? {
    guard let context = modelContext else { return nil }
    let descriptor = FetchDescriptor<ChatThread>(predicate: #Predicate { $0.id == id })
    return (try? context.fetch(descriptor))?.first
  }

  // MARK: - Voice mode

  /// Voice mode is open: replies start with the user's transcript and are short and speakable.
  /// The instruction travels with each voice turn (`VoiceText.instruction`), not in the system
  /// prompt, so opening and closing voice mode keeps the chat's conversation (in the system
  /// prompt, both rebuilt it: a full re-prefill each way).
  var voiceModeActive = false {
    didSet {
      if !voiceModeActive { scheduleHelpers() }
    }
  }

  /// The live answer of a voice turn (transcript removed) and whether the
  /// reply has ended; voice mode speaks it sentence by sentence.
  @ObservationIgnored var onVoiceReply: ((String, Bool) -> Void)?

  /// Send a spoken turn (and optionally what the camera sees).
  @discardableResult
  func sendVoiceTurn(audioFileURL: URL, imageData: Data?, in thread: ChatThread) async -> Bool {
    await send(text: "", imageData: imageData, audioFileURL: audioFileURL, in: thread)
  }

  // MARK: - Shared from other apps (SharedItems.swift)

  /// One pass over the share inbox at a time (``answerSharedItems(inbox:)``).
  @ObservationIgnored var answeringSharedItems = false
  /// Shared items whose send failed this session: kept in the inbox for the next launch, not
  /// retried on every activation.
  @ObservationIgnored var sharedItemsTried: Set<UUID> = []

  // MARK: - Dictation

  /// A recording is being turned into text for the composer.
  var isTranscribing = false

  /// Dictation: the recording's text (Gemma's audio input), or nil with
  /// `generationError` set.
  func transcribe(_ audioFileURL: URL) async -> String? {
    guard !isBusy else { return nil }
    isTranscribing = true
    defer { isTranscribing = false }
    let result: Result<String, Error> = await serialized {
      // A send queued ahead of this recording owns the engine until its reply.
      guard !self.isGenerating, !self.isPreparing else {
        return .failure(ChatError.underlying(message: String(localized: "Finish or stop the current reply first.")))
      }
      guard await self.loadIfNeeded() else {
        return .failure(ChatError.engineNotReady)
      }
      let result: Result<String, Error>
      do {
        result = .success(try await self.engine.transcribe(audioFileURL: audioFileURL))
      } catch {
        result = .failure(error)
      }
      await self.afterHelper()
      return result
    }
    switch result {
    case .success(let text):
      if text.isEmpty { generationError = String(localized: "No speech was recognized.") }
      return text
    case .failure(let error):
      generationError = String(
        localized: "Dictation failed: \((error as? ChatError)?.displayMessage ?? error.localizedDescription)")
      return nil
    }
  }

  // MARK: - Web search

  enum WebOutcome: Sendable {
    case found(WebResearch.Findings)
    case failed(String)
    case notNeeded  // small talk: answered as without Search
    case cancelled
  }

  /// Web search before a reply (cancelled by Stop).
  @ObservationIgnored var webTask: Task<WebOutcome, Never>?
  /// The last Search message's plan: its topic and queries (device tests read it).
  @ObservationIgnored var lastWebPlan: WebContext.Plan?
  /// Sources already attached to the reply before the automatic tool runs.
  @ObservationIgnored var toolSourceOffset = 0
}
