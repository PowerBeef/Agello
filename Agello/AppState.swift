import Foundation
import LiteRTLM
import SwiftData
import UIKit

/// Result of an on-demand benchmark run (1024 prefill / 256 decode tokens,
/// matching Google's published methodology).
struct BenchmarkReport: Codable, Sendable, Equatable {
  var modelID: ModelID
  var backend: String
  var prefillTokensPerSecond: Double
  var decodeTokensPerSecond: Double
  var timeToFirstToken: Double
  var date: Date

  var summaryLine: String {
    String(
      format: "%.0f prefill · %.0f decode tok/s · TTFT %.1fs",
      prefillTokensPerSecond, decodeTokensPerSecond, timeToFirstToken)
  }
}

/// Main-actor UI state: engine lifecycle, generation pipeline, options.
@Observable
@MainActor
final class AppState {
  let store: ModelStore
  let engine: any ChatEngineProtocol

  var engineState: ChatEngineState = .idle
  var resolved: ResolvedInference?
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
  /// user's personalization.
  var effectiveOptions: InferenceOptions {
    var effective = options
    effective.systemPrompt = SystemPrompt.compose(
      base: options.systemPrompt, personalization: personalization, project: activeProject,
      memories: memoryEnabled ? memoryTexts() : [], voice: voiceModeActive)
    effective.webSearchTool = webSettings.allowed && webSettings.automatic
    return effective
  }

  /// Web search settings (provider, automatic mode, master switch).
  var webSettings = WebSearchSettings() {
    didSet {
      UserDefaults.standard.set(try? JSONEncoder().encode(webSettings), forKey: "webSearch")
      // Automatic mode changes the tools the conversation offers.
      if (oldValue.allowed && oldValue.automatic) != (webSettings.allowed && webSettings.automatic) {
        scheduleApplyOptions()
      }
    }
  }
  @ObservationIgnored private(set) lazy var webResearch = WebResearch(knowledge: knowledge)

  /// The system prompt the engine's conversation was built with; a
  /// different one (project, memories, personalization) means a rebuild.
  @ObservationIgnored private var appliedSystemPrompt: String?

  /// Memory: learn lasting facts from the user's messages and add them to
  /// the system prompt. Off by default.
  var memoryEnabled = false {
    didSet {
      UserDefaults.standard.set(memoryEnabled, forKey: "memoryEnabled")
      memoriesChanged()
    }
  }

  /// The project of the chat the engine's conversation belongs to.
  @ObservationIgnored private(set) var activeProject: ProjectContext?
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
  @ObservationIgnored private var preparationTask: Task<FileContextResult?, Never>?

  /// Thread whose text history the native conversation currently holds.
  @ObservationIgnored private var conversationThreadID: UUID?
  /// True while the native conversation holds no turns (fresh load / empty reseed).
  @ObservationIgnored private var conversationIsEmpty = true
  /// Tail of the engine-lifecycle queue (see ``serialized(_:)``).
  @ObservationIgnored private var lifecycleTail: Task<Void, Never>?
  @ObservationIgnored private var applyOptionsTask: Task<Void, Never>?
  /// Settings changed mid-reply; applied once the reply finishes.
  @ObservationIgnored private var pendingOptionsApply = false
  /// A settings change is waiting for its debounced apply.
  @ObservationIgnored private var optionsDirty = false

  private var memoryWarningObserver: NSObjectProtocol?

  init(useMockEngine: Bool = false, store: ModelStore? = nil) {
    self.store = store ?? ModelStore()
    self.engine =
      useMockEngine ? MockChatEngine() : LiteRTChatEngine()
    self.knowledge = KnowledgeBase(store: self.store, useHashingEmbedder: useMockEngine)
    if let data = UserDefaults.standard.data(forKey: "inferenceOptions"),
      let decoded = try? JSONDecoder().decode(InferenceOptions.self, from: data)
    {
      self.options = decoded
    }
    self.enableTools = UserDefaults.standard.object(forKey: "enableTools") as? Bool ?? true
    self.memoryEnabled = UserDefaults.standard.bool(forKey: "memoryEnabled")
    if let data = UserDefaults.standard.data(forKey: "webSearch"),
      let decoded = try? JSONDecoder().decode(WebSearchSettings.self, from: data)
    {
      self.webSettings = decoded
    }
    if let data = UserDefaults.standard.data(forKey: "personalization"),
      let decoded = try? JSONDecoder().decode(Personalization.self, from: data)
    {
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
    // Files attached before the embedding model arrived get indexed once it does.
    self.store.onModelReady = { [weak self] model in
      if model == ModelCatalog.embeddingGemma.id { self?.knowledge.indexPending() }
    }
    memoryWarningObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      Log.lifecycle.warning("memory warning (\(MemoryProbe.summary, privacy: .public))")
      Task { @MainActor in self.stopIfMemoryIsExhausted() }
    }
  }

  var isMock: Bool { engine is MockChatEngine }

  /// Stop a running reply (keeping its text) if the app is about to run out
  /// of memory.
  private func stopIfMemoryIsExhausted() {
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
  private func serialized<T: Sendable>(
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
      appliedSystemPrompt = effectiveOptions.systemPrompt
      engineState = .ready
      return true
    } catch {
      let message = (error as? ChatError)?.displayMessage ?? error.localizedDescription
      engineState = .failed(message: message)
      return false
    }
  }

  private func unloadEngine() async {
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
  func applyCurrentOptions() async {
    await serialized { await self.applyOptionsLocked() }
  }

  private func applyOptionsLocked() async {
    optionsDirty = false
    // Not loaded: options are picked up by the next load. Never load a
    // multi-GB model just because a setting changed.
    guard await engine.isLoaded else { return }
    if isGenerating || isBenchmarking {
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
    let history = thread.textHistory
    return await serialized {
      await self.prepareConversation(threadID: threadID, history: history)
    }
  }

  private func prepareConversation(
    threadID: UUID, history: [(role: ChatRole, text: String)]
  ) async -> Bool {
    guard await loadIfNeeded() else { return false }
    if conversationThreadID == threadID { return true }
    // Never swap the conversation out from under a live reply.
    if isGenerating { return false }
    // Another project, changed memories or personalization: rebuild the
    // conversation with the right system prompt.
    activeProject = projectContext(for: threadID)
    let systemPrompt = effectiveOptions.systemPrompt
    if systemPrompt != appliedSystemPrompt {
      Log.engine.info("system prompt changed: rebuild with \(history.count) turns")
      do {
        if let live = engine as? LiteRTChatEngine {
          resolved = try await live.updateConversationOptions(
            effectiveOptions, enableTools: enableTools, history: history)
        } else {
          if let mock = engine as? MockChatEngine {
            await mock.applyConversationOptions(effectiveOptions)
          }
          try await engine.reseed(history: history)
        }
      } catch {
        generationError = (error as? ChatError)?.displayMessage ?? error.localizedDescription
        return false
      }
      appliedSystemPrompt = systemPrompt
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
  func send(
    text: String, imageData: Data?, audioFileURL: URL?, files: [FileRecord] = [],
    webSearch: Bool = false, in thread: ChatThread
  ) async -> Bool {
    let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty || imageData != nil || audioFileURL != nil || !files.isEmpty else {
      return false
    }
    return await generate(
      prompt: prompt, imageData: imageData, audioFileURL: audioFileURL, in: thread,
      history: nil, webSearch: webSearch
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
  /// one stays reachable through the version switcher).
  @discardableResult
  func regenerate(_ reply: ChatTurn, in thread: ChatThread) async -> Bool {
    guard canRegenerate(reply, in: thread), let prompt = promptTurn(of: reply, in: thread) else {
      return false
    }
    return await generate(
      prompt: prompt.text, imageData: prompt.imageData, audioFileURL: nil, in: thread,
      history: thread.textHistory(before: prompt), replacing: reply,
      webSearch: prompt.parts.webSearch
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
    webSearch: Bool = false, persist: () -> Void
  ) async -> Bool {
    guard !isGenerating, !isPreparing, !isBenchmarking else { return false }
    guard let context = modelContext else { return false }
    generationError = nil
    isPreparing = true
    preparingThreadID = thread.id
    defer {
      isPreparing = false
      preparingThreadID = nil
      preparingStatus = nil
      BackgroundWork.shared.end(success: generationError == nil)
    }
    // A just-changed setting (e.g. the composer's Think toggle) applies to
    // this message, not after it.
    if optionsDirty {
      applyOptionsTask?.cancel()
      await applyCurrentOptions()
    }

    let threadID = thread.id
    selectedThreadID = threadID

    // Files in this chat (and its project): build what the model reads.
    var enginePrompt = prompt
    var sources: [SourceRecord] = []
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
    }

    let history = rewound ?? thread.textHistory

    // Web search the user asked for: plan queries, search, read, rank.
    if webSearch, webSettings.allowed {
      guard await ensureEngineLoaded() else { return false }
      let filePrompt = documents.isEmpty ? nil : enginePrompt
      let firstIndex = sources.count + 1
      let task = Task { () -> WebOutcome in
        await self.searchWeb(question: prompt, history: history, firstIndex: firstIndex)
      }
      webTask = task
      let outcome = await task.value
      webTask = nil
      preparingStatus = nil
      switch outcome {
      case .cancelled:
        return false
      case .failed(let message):
        generationError = message
      case .found(let findings):
        enginePrompt = WebContext.prompt(
          question: prompt, sources: findings.sources, filePrompt: filePrompt)
        sources += findings.sources.map(\.record)
      }
    }

    let ready = await serialized {
      // Rewinding: the engine holds later turns that must not stay in context.
      if rewound != nil, self.conversationThreadID == threadID { self.conversationThreadID = nil }
      return await self.prepareConversation(threadID: threadID, history: history)
    }
    guard ready else { return false }

    // The engine may have degraded to text-only (model without executors).
    if imageData != nil, resolved?.enableVision != true {
      generationError = "This session is text-only, so images are disabled."
      return false
    }
    if audioFileURL != nil, resolved?.enableAudio != true {
      generationError = "This session is text-only, so voice messages are disabled."
      return false
    }

    // Keep the KV cache from overflowing (native heap corruption → crash):
    // trim the replayed history if this message + a reply wouldn't fit.
    let fit: Result<Bool, ChatError> = await serialized {
      do {
        return .success(
          try await self.engine.fitContext(
            text: enginePrompt, imageData: imageData, audioFileURL: audioFileURL,
            history: history))
      } catch {
        return .failure(
          error as? ChatError ?? .underlying(message: error.localizedDescription))
      }
    }
    switch fit {
    case .success(let trimmed):
      if trimmed {
        conversationThreadID = threadID
        generationError =
          "Older messages were dropped from the model's memory to fit its context window."
      }
    case .failure(let error):
      generationError = error.displayMessage
      return false
    }

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
    await learnMemories(from: voiceTurn?.text ?? prompt, reply: reply, in: thread)
    await generateTitleIfNeeded(for: thread)
    SpotlightIndex.index([thread])
    return true
  }

  /// After the first exchange, replace the provisional title (the first
  /// words of the first message) with a short model-written one.
  func generateTitleIfNeeded(for thread: ChatThread) async {
    let path = thread.orderedTurns
    guard path.count == 2, let first = path.first, first.isUser,
      let reply = path.last, !reply.isUser, !reply.text.isEmpty,
      !reply.text.hasPrefix(ChatTurn.errorPrefix)
    else { return }
    let provisional = Self.title(
      prompt: first.text, hasImage: first.imageData != nil, fileName: first.parts.files.first?.name)
    guard thread.title == provisional else { return }  // renamed by the user
    let prompt = HelperTasks.titlePrompt(
      user: first.text.isEmpty ? provisional : first.text, reply: reply.text)
    let output: Data? = await serialized {
      guard !self.isGenerating, await self.engine.isLoaded else { return nil }
      let data: Data?
      do {
        data = try await self.engine.helperJSON(
          prompt: prompt, schemaJSON: HelperTasks.titleSchema,
          maxOutputTokens: HelperTasks.titleMaxOutputTokens)
      } catch {
        Log.engine.error("title helper failed: \(String(describing: error), privacy: .public)")
        data = nil
      }
      // The helper replaced the engine's conversation with an empty one:
      // rebuild this chat from history on its next message.
      self.conversationThreadID = nil
      self.conversationIsEmpty = true
      return data
    }
    guard let output, let title = HelperTasks.parseTitle(output), thread.title == provisional
    else {
      Log.engine.error(
        "title helper unusable: \(output.map { String(decoding: $0, as: UTF8.self) } ?? "nil", privacy: .public)")
      return
    }
    thread.title = title
    try? modelContext?.save()
  }

  /// Chat title from the first message; attachment-only messages get a label.
  static func title(prompt: String, hasImage: Bool, fileName: String? = nil) -> String {
    if !prompt.isEmpty { return String(prompt.prefix(42)) }
    if let fileName { return String(fileName.prefix(42)) }
    return hasImage ? "Photo" : "Voice message"
  }

  // MARK: - Voice mode

  /// Voice mode is open: replies start with the user's transcript and are
  /// short and speakable (the system prompt changes, so the conversation is
  /// rebuilt before the next message).
  var voiceModeActive = false {
    didSet {
      if voiceModeActive != oldValue { conversationThreadID = nil }
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

  // MARK: - Shared from other apps

  /// Answer the oldest item shared to Agello (share sheet) in a new chat.
  /// Returns false when there is nothing to do (or a reply is running).
  @discardableResult
  func answerNextSharedItem(inbox base: URL? = nil) async -> Bool {
    guard !isBusy, let context = modelContext, let (item, file) = ShareInbox.pending(base: base).first
    else { return false }
    let thread = newThread(in: context)
    newChatProjectID = nil
    selectedThreadID = thread.id
    var question = ShareInbox.question(for: item)
    var files: [FileRecord] = []
    var image: Data?

    func attach(_ extracted: ExtractedDocument) {
      if let document = knowledge.add(extracted, threadID: thread.id) {
        files.append(
          FileRecord(
            id: document.id, name: document.name, kind: document.kindRaw,
            pageCount: document.pageCount))
      }
    }

    switch item.kind {
    case .file:
      if let file, let extracted = try? await DocumentIngestor.extract(from: file) {
        attach(extracted)
      } else {
        generationError = String(localized: "Agello couldn't read the shared file.")
      }
    case .image:
      if let file, let data = try? Data(contentsOf: file) { image = ImagePreparer.prepare(data) ?? data }
    case .url:
      let link = item.url.flatMap(URL.init(string:))
      if webSettings.allowed, let link, let page = await WebClient().readPage(link) {
        attach(
          ExtractedDocument(
            name: page.title ?? link.host() ?? link.absoluteString, kind: .text,
            byteCount: Int64(page.text.utf8.count), pages: [page.text]))
        question += "\n\n(\(link.absoluteString))"
      } else if let link {
        question += "\n\n\(link.absoluteString)"
      }
    case .text:
      let text = item.text ?? ""
      if text.count > ShareInbox.inlineTextLimit {
        attach(
          ExtractedDocument(
            name: String(localized: "Shared text"), kind: .text, byteCount: Int64(text.utf8.count),
            pages: [text]))
      } else if question != text {
        question += "\n\n\(text)"
      }
    }
    ShareInbox.remove(item.id, base: base)
    await send(text: question, imageData: image, audioFileURL: nil, files: files, in: thread)
    return true
  }

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
      guard await self.loadIfNeeded() else {
        return .failure(ChatError.engineNotReady)
      }
      defer {
        // The transcription replaced the engine's conversation.
        self.conversationThreadID = nil
        self.conversationIsEmpty = true
      }
      do {
        return .success(try await self.engine.transcribe(audioFileURL: audioFileURL))
      } catch {
        return .failure(error)
      }
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
    case cancelled
  }

  /// Web search before a reply (cancelled by Stop).
  @ObservationIgnored private var webTask: Task<WebOutcome, Never>?
  /// Sources already attached to the reply before the automatic tool runs.
  @ObservationIgnored private var toolSourceOffset = 0

  /// Plan queries (the model resolves follow-ups; a first question is
  /// searched as asked), then research them.
  private func searchWeb(
    question: String, history: [(role: ChatRole, text: String)], firstIndex: Int
  ) async -> WebOutcome {
    var queries = [WebContext.directQuery(question)]
    if !history.isEmpty {
      preparingStatus = String(localized: "Planning the search…")
      let prompt = WebContext.queryPrompt(question: question, history: history)
      let output: Data? = await serialized {
        defer {
          self.conversationThreadID = nil
          self.conversationIsEmpty = true
        }
        return try? await self.engine.helperJSON(
          prompt: prompt, schemaJSON: WebContext.querySchema,
          maxOutputTokens: WebContext.queryMaxOutputTokens)
      }
      let planned = output.map(WebContext.parseQueries) ?? []
      if !planned.isEmpty { queries = planned }
    }
    if Task.isCancelled { return .cancelled }
    let window = resolved?.maxNumTokens ?? 8_192
    do {
      let findings = try await webResearch.research(
        queries: queries, question: question, settings: webSettings,
        budgetTokens: FileContext.budget(window: window, question: question),
        firstIndex: firstIndex
      ) { status in self.preparingStatus = status }
      return findings.sources.isEmpty
        ? .failed(String(localized: "The web search found nothing useful. Answered without it."))
        : .found(findings)
    } catch is CancellationError {
      return .cancelled
    } catch {
      if Task.isCancelled { return .cancelled }
      return .failed(
        String(localized: "Web search failed: \(error.localizedDescription) Answered without it."))
    }
  }

  /// The automatic `web_search` tool's work (runs during a reply).
  private func installWebSearchTool() {
    WebSearchTool.handler = { [weak self] query, maxBytes in
      await self?.toolSearch(query, maxBytes: maxBytes) ?? "Web search is unavailable."
    }
  }

  private func toolSearch(_ query: String, maxBytes: Int) async -> String {
    guard webSettings.allowed else { return "Web search is turned off." }
    do {
      let findings = try await webResearch.research(
        queries: [query], question: query, settings: webSettings,
        // ~3 bytes per token (ContextBudget.bytesPerToken).
        budgetTokens: max(200, Int(Double(maxBytes) / ContextBudget.bytesPerToken) - 40),
        firstIndex: toolSourceOffset + WebSourcesRecorder.nextIndex
      ) { _ in }
      WebSourcesRecorder.record(findings.sources.map(\.record))
      return findings.sources.isEmpty ? "No results." : WebContext.sourcesBlock(findings.sources)
    } catch {
      return "Web search failed: \(error.localizedDescription)"
    }
  }

  // MARK: - Files

  struct FileContextResult {
    var prompt: String
    var sources: [SourceRecord]
  }

  /// The chat's own files, then its project's.
  func documents(for thread: ChatThread) -> [ChatDocument] {
    var documents = knowledge.documents(threadID: thread.id)
    if let projectID = thread.projectID { documents += knowledge.documents(projectID: projectID) }
    return documents
  }

  /// What the model reads for `question`: whole files when they fit half
  /// the context window; otherwise a section summary of long files (for
  /// "summarize"-style questions, cached on the document) or the most
  /// relevant excerpts with page labels. nil when stopped.
  private func assembleFileContext(question: String, documents: [ChatDocument]) async
    -> FileContextResult?
  {
    let window = resolved?.maxNumTokens ?? 8_192
    let budget = FileContext.budget(window: window, question: question)
    var materials: [FileContext.Material] = []
    var sources: [SourceRecord] = []
    func cite(_ title: String, _ snippet: String? = nil) {
      sources.append(
        SourceRecord(index: sources.count + 1, title: title, url: nil, snippet: snippet))
    }

    let total = documents.reduce(0) { $0 + ContextBudget.estimateTokens($1.text) }
    if total <= budget {
      for document in documents {
        materials.append(.full(name: document.name, pageCount: document.pageCount, text: document.text))
        cite(document.name)
      }
    } else if FileContext.wantsSummary(question) {
      let share = budget / documents.count
      for document in documents {
        if ContextBudget.estimateTokens(document.text) <= share {
          materials.append(.full(name: document.name, pageCount: document.pageCount, text: document.text))
        } else {
          guard let summary = await summary(of: document) else { return nil }
          materials.append(
            .summary(
              name: document.name, pageCount: document.pageCount,
              text: FileContext.truncate(summary, tokens: share)))
        }
        cite(document.name)
      }
    } else {
      preparingStatus = "Searching your files…"
      let passages = FileContext.fit(
        await knowledge.search(question, in: documents, limit: 24), budget: budget)
      if Task.isCancelled { return nil }
      materials.append(.excerpts(passages.map { (label: $0.citation, text: $0.text) }))
      for passage in passages { cite(passage.citation, String(passage.text.prefix(240))) }
    }
    return FileContextResult(
      prompt: FileContext.prompt(question: question, materials: materials), sources: sources)
  }

  /// A long document's section-by-section summary, written once and cached.
  private func summary(of document: ChatDocument) async -> String? {
    if let summary = document.summary { return summary }
    let chunks = document.chunks.sorted { $0.index < $1.index }.map {
      ChunkDraft(index: $0.index, text: $0.text, pageStart: $0.pageStart, pageEnd: $0.pageEnd)
    }
    let sections = FileContext.sections(chunks)
    let prompts = sections.map { FileContext.sectionPrompt($0, of: document.name) }
    let name = document.name
    let count = sections.count
    // Only long, user-requested file summaries request background GPU time.
    BackgroundWork.shared.onExpire = { [weak self] in self?.stop() }
    BackgroundWork.shared.begin(
      title: String(localized: "Summarizing \(name)"),
      subtitle: String(localized: "Reading \(count) sections"))
    preparingStatus = "Reading \(name)…"
    let outputs: [String]? = await serialized {
      defer {
        // The helper left the engine's conversation empty.
        self.conversationThreadID = nil
        self.conversationIsEmpty = true
      }
      return try? await self.engine.helperTexts(
        prompts, maxOutputTokens: FileContext.sectionSummaryTokens
      ) { done in
        await MainActor.run {
          self.preparingStatus = "Reading \(name) · part \(min(done + 1, count)) of \(count)"
          BackgroundWork.shared.sectionProgress(completed: done, total: count)
        }
      }
    }
    guard let outputs, !Task.isCancelled, outputs.count == sections.count else { return nil }
    let summary = FileContext.joinSummaries(outputs, sections: sections)
    document.summary = summary
    try? modelContext?.save()
    return summary
  }

  private func consume(
    _ stream: AsyncThrowingStream<ChatEvent, Error>, into reply: ChatTurn, context: ModelContext,
    voiceTurn: ChatTurn? = nil
  ) async {
    // Stream into a plain accumulator and publish to the SwiftData model at
    // ~10 Hz: per-token model writes re-render (and re-parse markdown for)
    // the whole bubble 40-100 times a second.
    var accumulator = StreamAccumulator()
    var lastFlush = ContinuousClock.now
    func flush(final: Bool = false) {
      if let voiceTurn {
        // "⟦what the user said⟧ answer": the transcript becomes the user's
        // message; the answer is shown and spoken.
        let split = VoiceText.split(accumulator.text)
        if let heard = split.heard, voiceTurn.text != heard {
          voiceTurn.text = heard
          if let thread = voiceTurn.thread, thread.title == Self.title(prompt: "", hasImage: voiceTurn.imageData != nil),
            thread.orderedTurns.first?.id == voiceTurn.id
          {
            thread.title = Self.title(prompt: heard, hasImage: false)
          }
        }
        reply.text = split.answer
        onVoiceReply?(split.answer, final)
      } else {
        reply.text = accumulator.text
      }
      reply.thought = accumulator.thought
      if reply.toolNames != accumulator.toolNames { reply.toolNames = accumulator.toolNames }
      if reply.parts.toolActivity != accumulator.toolActivity {
        var parts = reply.parts
        parts.toolActivity = accumulator.toolActivity
        reply.parts = parts
      }
      lastFlush = .now
      BackgroundWork.shared.replyProgress(characters: reply.text.count)
    }
    toolStatus = nil
    defer { toolStatus = nil }
    do {
      for try await event in stream {
        switch event {
        case .chunk(let chunk):
          accumulator.append(chunk)
          if let latest = chunk.toolActivity.last { toolStatus = latest.summary }
          if ContinuousClock.now - lastFlush >= .milliseconds(100) {
            flush()
            stopIfMemoryIsExhausted()
          }
        case .finished(let stats):
          reply.stats = stats
        }
      }
      flush(final: true)
      try? context.save()
      Haptics.complete()
    } catch let error as ChatError {
      flush(final: true)
      switch error {
      case .generationCancelled, .replyTruncated:
        if case .replyTruncated = error { generationError = error.displayMessage }
        if reply.text.isEmpty {
          reply.thread?.removeLeaf(reply)
          context.delete(reply)
        }
        try? context.save()
        // LiteRT-LM leaves a cancelled conversation unusable: rebuild it from
        // the thread's history (incl. the partial reply) before the next send.
        conversationThreadID = nil
      default:
        reply.text = reply.text.isEmpty ? ChatTurn.errorPrefix + error.displayMessage : reply.text
        try? context.save()
        Haptics.error()
      }
    } catch {
      flush(final: true)
      reply.text = reply.text.isEmpty ? ChatTurn.errorPrefix + error.localizedDescription : reply.text
      try? context.save()
      Haptics.error()
    }
  }

  func stop() {
    BackgroundWork.shared.end(success: false)
    preparationTask?.cancel()
    webTask?.cancel()
    Task { await engine.cancel() }
  }

  /// iOS doesn't allow GPU work in the background: stop a running reply
  /// deliberately (keeping the partial text) instead of letting Metal
  /// command buffers fail or the app be terminated.
  func enterBackground() {
    guard isBusy else { return }
    // A continued task with background GPU access lets the reply finish.
    if BackgroundWork.shared.isActive {
      Log.lifecycle.info("background: reply continues as a continued processing task")
      return
    }
    Log.lifecycle.info("background: stopping generation")
    stop()
    generationError = "Reply stopped because Agello moved to the background."
  }

  // MARK: - Benchmark

  /// Run a text benchmark (1024 prefill / 256 decode) on the active model.
  /// Unloads the chat engine first so the benchmark has full memory; the
  /// engine reloads lazily on the next chat.
  func runBenchmark() async {
    await serialized { await self.runBenchmarkLocked() }
  }

  private func runBenchmarkLocked() async {
    guard !isBenchmarking, !isGenerating else { return }
    let spec = store.activeSpec
    guard store.isDownloaded(spec), let url = store.localURL(for: spec) else {
      generationError = "\(spec.displayName) is not downloaded."
      return
    }
    isBenchmarking = true
    await unloadEngine()
    engineState = .loading(progress: "Benchmarking \(spec.displayName)…")
    defer {
      isBenchmarking = false
      engineState = .idle
    }
    do {
      let useGPU = options.backendPreference == .gpu
      let cacheDir = try LiteRTChatEngine.cacheDirectory()
      // Extract Sendable scalars inside the task: BenchmarkInfo itself is not Sendable.
      let result = try await Task.detached(priority: .userInitiated) {
        () -> (prefill: Double, decode: Double, ttft: Double) in
        let info = try await LiteRTLM.benchmark(
          modelPath: url.path,
          backend: useGPU ? .gpu : .cpu(),
          prefillTokens: 1024,
          decodeTokens: 256,
          cacheDir: cacheDir
        )
        return (
          info.lastPrefillTokensPerSecond, info.lastDecodeTokensPerSecond,
          info.timeToFirstTokenInSecond)
      }.value
      benchmarkReport = BenchmarkReport(
        modelID: spec.id,
        backend: useGPU ? "GPU" : "CPU",
        prefillTokensPerSecond: result.prefill,
        decodeTokensPerSecond: result.decode,
        timeToFirstToken: result.ttft,
        date: Date()
      )
    } catch {
      generationError =
        "Benchmark failed: \((error as? ChatError)?.displayMessage ?? error.localizedDescription)"
    }
  }

  // MARK: - Threads

  func newThread(in context: ModelContext) -> ChatThread {
    let thread = ChatThread(modelID: store.activeModelID)
    context.insert(thread)
    try? context.save()
    // The native conversation is re-pointed when the chat is opened
    // (``activate(_:)``), not here.
    return thread
  }

  /// Delete saved chats without messages (left behind when a first message
  /// was rejected), except the open one.
  func pruneEmptyThreads() {
    guard let context = modelContext,
      let threads = try? context.fetch(FetchDescriptor<ChatThread>())
    else { return }
    let empty = threads.filter { $0.turns.isEmpty && $0.id != selectedThreadID }
    guard !empty.isEmpty else { return }
    for thread in empty {
      if conversationThreadID == thread.id { conversationThreadID = nil }
      knowledge.deleteDocuments(threadID: thread.id)
      context.delete(thread)
    }
    try? context.save()
  }

  // MARK: - Memory

  /// Saved memories, most recent first, as added to the system prompt.
  func memoryTexts() -> [String] {
    var descriptor = FetchDescriptor<MemoryItem>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
    descriptor.fetchLimit = SystemPrompt.memoryLimit
    return ((try? modelContext?.fetch(descriptor)) ?? []).map(\.text)
  }

  /// Memories were added, edited or deleted (or memory was switched): the
  /// open conversation picks them up before the next message.
  func memoriesChanged() {
    conversationThreadID = nil
  }

  /// After a reply: save lasting facts from the user's message (memory on,
  /// and only when the message is about the user).
  private func learnMemories(from message: String, reply: ChatTurn, in thread: ChatThread) async {
    guard memoryEnabled, HelperTasks.shouldLookForMemories(message), !reply.text.isEmpty,
      !reply.text.hasPrefix(ChatTurn.errorPrefix), let context = modelContext
    else { return }
    let all = ((try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []).map(\.text)
    let prompt = HelperTasks.memoryPrompt(user: message, existing: all)
    let output: Data? = await serialized {
      guard !self.isGenerating, await self.engine.isLoaded else { return nil }
      defer {
        // The helper left the engine's conversation empty.
        self.conversationThreadID = nil
        self.conversationIsEmpty = true
      }
      return try? await self.engine.helperJSON(
        prompt: prompt, schemaJSON: HelperTasks.memorySchema,
        maxOutputTokens: HelperTasks.memoryMaxOutputTokens)
    }
    guard let output else { return }
    let learned = HelperTasks.newMemories(HelperTasks.parseMemories(output), existing: all)
    guard !learned.isEmpty else { return }
    for text in learned { context.insert(MemoryItem(text: text, sourceThreadID: thread.id)) }
    var parts = reply.parts
    parts.toolActivity.append(
      ToolActivityRecord(name: "memory", summary: learned.joined(separator: " · ")))
    reply.parts = parts
    try? context.save()
    Log.engine.info("memory: saved \(learned.count)")
    memoriesChanged()
  }

  // MARK: - Projects

  private func projectContext(for threadID: UUID) -> ProjectContext? {
    guard let context = modelContext else { return nil }
    let thread = try? context.fetch(
      FetchDescriptor<ChatThread>(predicate: #Predicate { $0.id == threadID })
    ).first
    // A new chat started from a project page isn't saved yet.
    guard let projectID = thread?.projectID ?? (thread == nil ? newChatProjectID : nil) else {
      return nil
    }
    guard
      let project = try? context.fetch(
        FetchDescriptor<Project>(predicate: #Predicate { $0.id == projectID })
      ).first
    else { return nil }
    return ProjectContext(id: project.id, name: project.name, instructions: project.instructions)
  }

  /// A project's instructions or name changed: its open chat picks them up
  /// before the next message.
  func projectInstructionsChanged(_ projectID: UUID) {
    if activeProject?.id == projectID { conversationThreadID = nil }
  }

  @discardableResult
  func newProject(named name: String, in context: ModelContext) -> Project {
    let project = Project(name: name)
    context.insert(project)
    try? context.save()
    return project
  }

  /// Move a chat into a project (or out, with nil).
  func move(_ thread: ChatThread, toProject projectID: UUID?) {
    thread.projectID = projectID
    try? modelContext?.save()
    if conversationThreadID == thread.id { conversationThreadID = nil }
  }

  /// Delete a project with its chats and files.
  func deleteProject(_ project: Project, in context: ModelContext) {
    let projectID = project.id
    let chats = (try? context.fetch(
      FetchDescriptor<ChatThread>(predicate: #Predicate { $0.projectID == projectID }))) ?? []
    for thread in chats where generatingThreadID != thread.id {
      deleteThread(thread, in: context)
    }
    for document in knowledge.documents(projectID: projectID) { knowledge.delete(document) }
    if newChatProjectID == projectID { newChatProjectID = nil }
    if activeProject?.id == projectID {
      activeProject = nil
      conversationThreadID = nil
    }
    context.delete(project)
    try? context.save()
  }

  func deleteThread(_ thread: ChatThread, in context: ModelContext) {
    if selectedThreadID == thread.id { selectedThreadID = nil }
    if conversationThreadID == thread.id { conversationThreadID = nil }
    knowledge.deleteDocuments(threadID: thread.id)
    SpotlightIndex.remove([thread.id])
    context.delete(thread)
    try? context.save()
  }
}
