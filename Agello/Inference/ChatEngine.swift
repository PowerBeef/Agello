import AVFoundation
import Foundation
import LiteRTLM

// MARK: - Engine boundary types

enum ChatRole: Sendable {
  case user
  case model
}

enum ChatEvent: Sendable {
  case chunk(ChatChunk)
  case finished(GenerationStats)
}

protocol ChatEngineProtocol: Sendable {
  /// Load (or reload) a model with the given options. Returns resolved settings.
  func load(
    spec: ModelSpec, modelURL: URL, options: InferenceOptions, memoryBytes: UInt64,
    enableTools: Bool
  ) async throws -> ResolvedInference
  func unload() async
  var isLoaded: Bool { get async }
  var currentModelID: ModelID? { get async }
  /// Recreate the conversation, re-seeding text history (used after option changes).
  func reseed(history: [(role: ChatRole, text: String)]) async throws
  /// Make room in the context window for the next message plus a reply,
  /// replaying a trimmed `history` (the thread's turns before this message)
  /// when needed. Returns true when older turns were dropped.
  /// - Throws: ``ChatError/messageTooLong`` when the message alone can't fit.
  func fitContext(
    text: String, imageData: Data?, audioFileURL: URL?,
    history: [(role: ChatRole, text: String)]
  ) async throws -> Bool
  nonisolated func send(
    text: String, imageData: Data?, audioFileURL: URL?
  ) -> AsyncThrowingStream<ChatEvent, Error>
  func cancel() async
  /// Run a structured helper prompt (JSON-schema constrained) in a throwaway
  /// conversation. Google's LiteRT-LM keeps one live conversation per engine,
  /// so the helper wipes the main one, which is replaced by an empty one: the
  /// caller must re-seed history before the next send. Our runtime keeps it
  /// when memory allows (``lastHelperKeptConversation``).
  func helperJSON(prompt: String, schemaJSON: String, maxOutputTokens: Int) async throws -> Data
  /// Run plain-text helper prompts one after another (e.g. summarizing a
  /// long document section by section), each in a throwaway conversation.
  /// Like ``helperJSON``, this leaves the main conversation empty unless kept.
  /// `progress` receives the number of prompts completed. Stops early (with
  /// the outputs so far) when the calling task is cancelled.
  func helperTexts(
    _ prompts: [String], maxOutputTokens: Int, progress: @Sendable (Int) async -> Void
  ) async throws -> [String]
  /// Transcribe a recording (dictation) in a throwaway conversation with
  /// greedy decoding. Leaves the main conversation empty unless kept, like
  /// the helpers.
  func transcribe(audioFileURL: URL) async throws -> String
  /// Whether the last helper (``helperJSON``, ``helperTexts``, ``transcribe``)
  /// finished with the main conversation as it was. False when it was replaced
  /// by an empty one, or the helper failed: reseed before the next send.
  var lastHelperKeptConversation: Bool { get async }
}

// MARK: - Live engine

/// The one and only wrapper between the app and LiteRT-LM. Owns a single
/// `Engine` + `Conversation` pair; everything else talks to this actor.
actor LiteRTChatEngine: ChatEngineProtocol {
  private var engine: Engine?
  private var conversation: Conversation?
  private var resolved: ResolvedInference?
  private var spec: ModelSpec?
  private var options: InferenceOptions?
  private var capabilities: ModelCapabilities?
  /// The plan the current engine was built for, before backend/modality
  /// fallbacks (engine-level settings are compared against this).
  private var builtPlan: ResolvedInference?
  private var toolsEnabled = true
  private var generating = false
  /// Set by ``cancel()`` during a generation. LiteRT-LM leaves the
  /// conversation cancelled afterwards (the next message fails with
  /// "CANCELLED"), so a cancelled generation always ends as
  /// ``ChatError/generationCancelled`` and the caller must reseed.
  private var cancelRequested = false
  private(set) var lastHelperKeptConversation = false
  /// The helper conversation running now, so ``cancel()`` stops it rather
  /// than the kept main conversation.
  private var helperConversation: Conversation?
  /// A helper runs (from ``beginHelper()`` to ``endHelper``): Stop cancels it, never the main
  /// conversation, even before its own conversation exists.
  private var helperActive = false
  /// Human-readable trace of the most recent `load`: capabilities and every
  /// attempt on the backend ladder with its outcome (read by the device harness).
  private(set) var loadLog: [String] = []
  /// How the last engine's memory came back after unloading; each `load`
  /// starts its `loadLog` with it.
  private(set) var lastUnload: String?
  /// Tokens the conversation prefills before its first message (preamble and replayed history):
  /// counted when it's created, estimated if the runtime can't. `getTokenCount()` reads 0 until then.
  private var seedTokens = ContextBudget.preambleTokens

  var isLoaded: Bool { engine != nil && conversation != nil }

  /// Tokens the live conversation holds in the KV cache, as the runtime
  /// counts them (0 until the first send; device tests).
  func cachedTokenCount() -> Int { (try? conversation?.getTokenCount()) ?? 0 }

  /// Tokens currently held by the KV cache (measured once anything was sent).
  private func usedTokens() -> Int {
    let measured = (try? conversation?.getTokenCount()) ?? 0
    return measured > 0 ? measured : seedTokens
  }

  /// Tokens `text` encodes to with the model's tokenizer; estimated (erring high) if the
  /// runtime can't count.
  private func textTokens(_ text: String) async -> Int {
    if let engine, let exact = try? await engine.countTokens(text) { return exact }
    return ContextBudget.estimateTextTokens(text)
  }

  private func mediaTokens(imageData: Data?, audioFileURL: URL?) -> Int {
    ContextBudget.mediaTokens(
      imageTokens: imageData == nil ? nil : Int(resolved?.visualTokenBudget ?? 280),
      audioSeconds: audioFileURL.map(Self.audioDuration))
  }

  /// What the KV cache holds once `text` (with its image or voice message) is prefilled.
  /// Exact for text (probe 17): the runtime renders the message as it will prefill it (on a new
  /// conversation that includes the preamble and the replayed history, plus a BOS token the
  /// text doesn't show) and the model's tokenizer counts it. Images and audio are estimated.
  private func tokensAfterPrefill(text: String, imageData: Data?, audioFileURL: URL?) async -> Int {
    let media = mediaTokens(imageData: imageData, audioFileURL: audioFileURL)
    let cached = (try? conversation?.getTokenCount()) ?? 0
    let message = LiteRTLM.Message(contents: [.text(Self.promptText(text, imageData, audioFileURL))])
    if let engine, let rendered = try? conversation?.renderMessageIntoString(message),
      let exact = try? await engine.countTokens(rendered)
    {
      return cached + (cached == 0 ? 1 : 0) + exact + media
    }
    return usedTokens() + ContextBudget.estimateTokens(text) + media
  }

  /// The text a message is sent with (a prompt of its own when it's only an image or audio).
  private static func promptText(_ text: String, _ imageData: Data?, _ audioFileURL: URL?) -> String {
    if imageData != nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Describe this image in detail."
    }
    if !text.isEmpty { return text }
    return audioFileURL != nil ? "Listen to this voice message and respond to it." : "Hello!"
  }

  private nonisolated static func audioDuration(_ url: URL) -> Double {
    guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
      return 30  // recorder maximum
    }
    return Double(file.length) / file.fileFormat.sampleRate
  }
  var currentModelID: ModelID? { spec?.id }

  // MARK: Load

  func load(
    spec: ModelSpec, modelURL: URL, options: InferenceOptions, memoryBytes: UInt64,
    enableTools: Bool
  ) async throws -> ResolvedInference {
    // Stats collection for the per-reply footer (TTFT, tok/s).
    ExperimentalFlags.optIntoExperimentalAPIs()
    ExperimentalFlags.enableBenchmark = true
    // Reasoning never stays in the KV cache: at the next message the runtime
    // rewinds and refills the answer without it. That keeps the room for
    // the conversation, and matches a reseed from saved history (which has
    // no reasoning). LiteRT-LM defaults to this too; set it explicitly.
    ExperimentalFlags.filterChannelContentFromKvCache = true

    guard FileManager.default.fileExists(atPath: modelURL.path) else {
      throw ChatError.modelFileMissing
    }

    unloadAndRecord()
    var plan = InferencePlanner.resolve(options: options, model: spec.id, memoryBytes: memoryBytes)

    // Introspect the model file (cheap, no engine needed) and intersect the
    // plan with real capabilities: MTP support, thinking, modalities, and
    // the model's context / visual-token limits.
    loadLog = lastUnload.map { [$0] } ?? []
    if let caps = Self.inspect(modelURL: modelURL) {
      capabilities = caps
      plan = InferencePlanner.applyCapabilities(caps, to: plan)
      loadLog.append(
        "caps: mtp=\(caps.speculativeDecoding) thinking=\(caps.thinking) "
          + "tools=\(caps.functionCalling) vision=\(caps.vision) audio=\(caps.audio) "
          + "maxContext=\(caps.maxContextTokens) maxVisionBudget=\(caps.maxVisionTokenBudget)")
    } else {
      capabilities = nil
      loadLog.append("caps: unavailable (ModelInfo failed)")
    }

    // Engine-level flags must be set before the engine is created. The
    // conversation-level MTP flag (set in makeConversation) inherits these.
    ExperimentalFlags.enableSpeculativeDecoding = plan.enableSpeculativeDecoding

    // Attempt ladder: preferred backend first, then the other; multimodal
    // before text-only on each. Degrades gracefully when the model file
    // lacks vision/audio executors or a backend fails to initialize.
    let attempts = InferencePlanner.attempts(for: plan)
    var lastError: Error = ChatError.engineNotReady
    for attempt in attempts {
      let label = Self.describe(attempt)
      for trial in 1...2 {
        // In the background a GPU load fails: stop rather than fall back to the CPU for good.
        guard GPUGate.isOpen else {
          loadLog.append("stopped: the app is in the background")
          throw GPUGate.closedError
        }
        let started = Date()
        do {
          let engine = try await Self.makeEngine(modelURL: modelURL, resolved: attempt)
          try await Self.validate(engine)
          let conversation = try await Self.makeConversation(
            engine: engine, resolved: attempt, options: options, toolsEnabled: enableTools,
            history: []
          )
          self.engine = engine
          self.conversation = conversation
          self.seedTokens = await Self.seedTokens(
            conversation, engine: engine, history: [], systemPrompt: options.systemPrompt)
          self.resolved = attempt
          self.builtPlan = plan
          self.spec = spec
          self.options = options
          self.toolsEnabled = enableTools
          let entry = String(
            format: "ok %@ in %.1fs (%@)", label, Date().timeIntervalSince(started),
            MemoryProbe.summary)
          loadLog.append(entry)
          Log.engine.info("load \(spec.id.rawValue, privacy: .public): \(entry, privacy: .public)")
          return attempt
        } catch {
          lastError = error
          let entry = "failed \(label) (try \(trial)): \(error)"
          loadLog.append(entry)
          Log.engine.error("load \(spec.id.rawValue, privacy: .public): \(entry, privacy: .public)")
          // A broken-but-"successful" engine usually means a section failed
          // to map while a previous engine's mappings were still alive: give
          // them a moment to be released and retry the same configuration.
          guard trial == 1, error is EngineValidationError else { break }
          try? await Task.sleep(for: .milliseconds(750))
        }
      }
    }
    throw lastError
  }

  private static func describe(_ attempt: ResolvedInference) -> String {
    "\(attempt.backendLabel) vision=\(attempt.enableVision) audio=\(attempt.enableAudio) "
      + "mtp=\(attempt.enableSpeculativeDecoding) kv=\(attempt.maxNumTokens) "
      + "thinking=\(attempt.thinkingBudget.map(String.init) ?? "off")"
  }

  func unload() async {
    unloadAndRecord()
  }

  /// Frees the engine and notes, for the next `load`'s log, how much memory
  /// came back and whether the `Engine` object itself was released. The
  /// iPhone returns the memory at once; probe 16 checks that none stays.
  private func unloadAndRecord() {
    guard engine != nil else { return }
    weak var released = engine
    let before = MemoryProbe.footprintBytes()
    unloadLocked()
    let after = MemoryProbe.footprintBytes()
    lastUnload = String(
      format: "unload: footprint %.2f -> %.2f GB, engine object %@", Double(before) / 1e9,
      Double(after) / 1e9, released == nil ? "freed" : "still referenced")
    Log.engine.info("\(self.lastUnload ?? "", privacy: .public)")
  }

  private func unloadLocked() {
    conversation = nil
    engine = nil // native handle is released in Engine.deinit
    resolved = nil
    builtPlan = nil
    spec = nil
    options = nil
    generating = false
  }

  /// Read model-file capabilities without initializing an engine.
  nonisolated static func inspect(modelURL: URL) -> ModelCapabilities? {
    guard let info = ModelInfo(modelPath: modelURL.path) else { return nil }
    let modalities = info.inputModalities
    return ModelCapabilities(
      speculativeDecoding: info.llm?.hasSpeculativeDecodingSupport() ?? false,
      thinking: info.llm?.supportsThinking() ?? false,
      functionCalling: info.llm?.supportsFunctionCalling() ?? false,
      vision: modalities.vision,
      audio: modalities.audio,
      maxVisionTokenBudget: info.maxVisionTokenBudget(),
      maxContextTokens: info.maxContextTokens(),
      dynamicContext: info.isDynamicContext()
    )
  }

  private static func makeEngine(modelURL: URL, resolved: ResolvedInference) async throws -> Engine {
    let config = try EngineConfig(
      modelPath: modelURL.path,
      backend: resolved.useGPU ? .gpu : .cpu(),
      visionBackend: resolved.enableVision ? .cpu() : nil,
      audioBackend: resolved.enableAudio ? .cpu() : nil,
      maxNumTokens: resolved.maxNumTokens,
      cacheDir: try EngineCache.directory(maxNumTokens: resolved.maxNumTokens)
    )
    let engine = Engine(engineConfig: config)
    // initialize() blocks for a long time; keep it off the caller's context.
    try await Task.detached(priority: .userInitiated) {
      try await engine.initialize()
    }.value
    return engine
  }

  struct EngineValidationError: Error, CustomStringConvertible {
    let underlying: String
    var description: String { "engine failed validation: \(underlying)" }
  }

  /// LiteRT-LM can report a successful load even when part of the model
  /// failed to map (e.g. "Cannot allocate memory" while another engine's
  /// mappings are alive); every generation then fails ("No per-layer
  /// embeddings found"). A one-token generation on a throwaway conversation
  /// proves the engine actually works before the app commits to it.
  private static func validate(_ engine: Engine) async throws {
    let probe = try await engine.createConversation(with: ConversationConfig())
    do {
      _ = try await probe.sendMessage(LiteRTLM.Message("Hi"), maxOutputTokens: 1)
    } catch {
      throw EngineValidationError(underlying: String(describing: error))
    }
  }

  private static func makeConversation(
    engine: Engine, resolved: ResolvedInference, options: InferenceOptions,
    toolsEnabled: Bool, history: [(role: ChatRole, text: String)]
  ) async throws -> Conversation {
    let sampler = try SamplerConfig(
      topK: resolved.topK, topP: resolved.topP, temperature: resolved.temperature)
    var tools: [any Tool] = toolsEnabled ? [CurrentDateTimeTool(), CalculatorTool()] : []
    if options.webSearchTool { tools.append(WebSearchTool()) }
    let initial = history.suffix(maxReplayedTurns).map { turn -> LiteRTLM.Message in
      switch turn.role {
      case .user: return LiteRTLM.Message(turn.text, role: .user)
      case .model: return LiteRTLM.Message(turn.text, role: .model)
      }
    }
    let config = ConversationConfig(
      systemMessage: options.systemPrompt.isEmpty ? nil : LiteRTLM.Message(options.systemPrompt),
      initialMessages: initial,
      tools: tools,
      samplerConfig: sampler,
      thinkingConfig: resolved.thinkingBudget.map {
        ThinkingConfig(enableThinking: true, thinkingTokenBudget: $0)
      },
      visualTokenBudget: resolved.visualTokenBudget,
      enableSpeculativeDecoding: resolved.enableSpeculativeDecoding
    )
    return try await engine.createConversation(with: config)
  }

  // MARK: Reseed

  func reseed(history: [(role: ChatRole, text: String)]) async throws {
    guard let engine, let resolved, let options else { throw ChatError.engineNotReady }
    let conversation = try await Self.makeConversation(
      engine: engine, resolved: resolved, options: options, toolsEnabled: toolsEnabled,
      history: history
    )
    self.conversation = conversation
    seedTokens = await Self.seedTokens(
      conversation, engine: engine, history: history, systemPrompt: options.systemPrompt)
  }

  /// What a new conversation prefills before its first message: its preamble and replayed
  /// history as the runtime renders them, plus BOS; estimated if the runtime can't count.
  private static func seedTokens(
    _ conversation: Conversation, engine: Engine, history: [(role: ChatRole, text: String)],
    systemPrompt: String
  ) async -> Int {
    if let preface = try? conversation.renderPrefaceIntoString(),
      let exact = try? await engine.countTokens(preface)
    {
      return exact + 1
    }
    return ContextBudget.preambleTokens(systemPrompt: systemPrompt)
      + ContextBudget.estimateHistory(Array(history.suffix(maxReplayedTurns)))
  }

  /// Upper bound on replayed turns (see ``makeConversation``).
  static let maxReplayedTurns = 20

  // MARK: Context window

  /// Make room for `text` and a reply: nothing to do when it fits after what the conversation
  /// holds; otherwise the conversation is rebuilt with the newest history that fits beside it
  /// (true). Throws ``ChatError/messageTooLong`` when the message doesn't fit even alone, which
  /// leaves the conversation empty: the caller reseeds before the next send.
  func fitContext(
    text: String, imageData: Data?, audioFileURL: URL?,
    history: [(role: ChatRole, text: String)]
  ) async throws -> Bool {
    guard conversation != nil, let resolved else { throw ChatError.engineNotReady }
    let window = resolved.maxNumTokens
    let thinking = resolved.thinkingBudget
    func fits(_ total: Int) -> Bool {
      ContextBudget.fits(used: total, input: 0, maxNumTokens: window, thinkingBudget: thinking)
    }
    let used = await tokensAfterPrefill(text: text, imageData: imageData, audioFileURL: audioFileURL)
    if fits(used) { return false }

    // The message alone, on an empty conversation: preamble, tools and the message, counted.
    try await reseed(history: [])
    let alone = await tokensAfterPrefill(text: text, imageData: imageData, audioFileURL: audioFileURL)
    guard fits(alone) else { throw ChatError.messageTooLong }
    var budget = ContextBudget.historyBudget(
      maxNumTokens: window, input: alone, thinkingBudget: thinking, preamble: 0)
    var turnTokens: [Int] = []
    for turn in history { turnTokens.append(await textTokens(turn.text)) }
    var trimmed: [(role: ChatRole, text: String)] = []
    var total = alone
    // The turns' own template tokens aren't counted per turn: check the rebuilt conversation and
    // trim by what it's over until it fits.
    for _ in 0..<4 {
      trimmed = ContextBudget.trimmedHistory(history, budget: budget, tokens: turnTokens)
      if trimmed.isEmpty { break }
      try await reseed(history: trimmed)
      total = await tokensAfterPrefill(text: text, imageData: imageData, audioFileURL: audioFileURL)
      if fits(total) { break }
      let over =
        total + ContextBudget.replyReserve(maxNumTokens: window, thinkingBudget: thinking)
        + ContextBudget.safetyMargin - window
      budget -= max(over, ContextBudget.perTurnOverhead)
      trimmed = []
    }
    if trimmed.isEmpty {
      try await reseed(history: [])
      total = alone
    }
    Log.engine.info(
      "context: was \(used), now \(total) of \(window) (alone \(alone)); replaying \(trimmed.count)/\(history.count) turns"
    )
    return true
  }

  /// Plan for `options` on this model, intersected with the file's capabilities.
  private func plan(for options: InferenceOptions, model: ModelID) -> ResolvedInference {
    let plan = InferencePlanner.resolve(
      options: options, model: model, memoryBytes: DeviceProfile.current.physicalMemoryBytes)
    return capabilities.map { InferencePlanner.applyCapabilities($0, to: plan) } ?? plan
  }

  /// Whether engine-level settings changed (needs full `load`, not just reseed).
  /// Compared with the plan the engine was built for (before fallbacks), so a
  /// CPU or text-only fallback doesn't force a reload on every change.
  func engineSettingsChanged(for newOptions: InferenceOptions) async -> Bool {
    guard let spec, let builtPlan else { return true }
    return InferencePlanner.requiresEngineReload(
      built: builtPlan, requested: plan(for: newOptions, model: spec.id))
  }

  /// Apply conversation-level options (sampler, thinking, tools, visual
  /// budget) by recreating the conversation. The caller
  /// must use `load` instead when ``engineSettingsChanged(for:)`` is true.
  func updateConversationOptions(
    _ newOptions: InferenceOptions, enableTools: Bool, history: [(role: ChatRole, text: String)]
  ) async throws -> ResolvedInference {
    guard let spec, let current = resolved else { throw ChatError.engineNotReady }
    let updated = InferencePlanner.conversationUpdate(
      engine: current, plan: plan(for: newOptions, model: spec.id))
    options = newOptions
    resolved = updated
    toolsEnabled = enableTools
    try await reseed(history: history)
    return updated
  }

  // MARK: Helpers

  /// Before a helper: whether the main conversation stays
  /// (``DeviceProfile/keepsConversationAcrossHelpers``). If not, it's released
  /// first, so our runtime doesn't copy its KV cache aside.
  private func beginHelper() -> Bool {
    lastHelperKeptConversation = false
    helperActive = true
    cancelRequested = false
    let keep =
      conversation != nil
      && DeviceProfile.keepsConversationAcrossHelpers(
        runtimeKeepsSessions: EngineCache.runtimeBuildID != nil,
        maxNumTokens: resolved?.maxNumTokens ?? 0, availableBytes: MemoryProbe.availableBytes())
    if !keep { conversation = nil }
    return keep
  }

  /// After a helper: the main conversation as it was, or an empty one. Callers
  /// release their own reference to the helper's conversation first.
  private func endHelper(
    keep: Bool, engine: Engine, resolved: ResolvedInference, options: InferenceOptions
  ) async throws {
    helperConversation = nil
    helperActive = false
    lastHelperKeptConversation = keep
    if keep {
      // Switching the engine back to the kept conversation restores its KV
      // cache and frees the copy taken for the helper (one cache: 0.23 GB at
      // 8K), which otherwise waits for the next message. Reading the token
      // count is what switches it; the helper's session is gone by now, so
      // nothing is copied on the way.
      _ = try? conversation?.getTokenCount()
      return
    }
    let conversation = try await Self.makeConversation(
      engine: engine, resolved: resolved, options: options, toolsEnabled: toolsEnabled,
      history: [])
    self.conversation = conversation
    seedTokens = await Self.seedTokens(
      conversation, engine: engine, history: [], systemPrompt: options.systemPrompt)
  }

  /// A helper stopped before it sent anything.
  private func checkHelperNotCancelled() throws {
    if cancelRequested { throw ChatError.generationCancelled }
  }

  /// After a helper failed or was stopped: leave a usable conversation (the kept one, or an
  /// empty one the caller reseeds) rather than none, which would force a full engine reload.
  private func endHelperAfterFailure(
    keep: Bool, engine: Engine, resolved: ResolvedInference, options: InferenceOptions
  ) async {
    do {
      try await endHelper(keep: keep, engine: engine, resolved: resolved, options: options)
    } catch {
      Log.engine.error("helper: couldn't restore a conversation: \(String(describing: error), privacy: .public)")
    }
    // A failed helper reports the conversation as not kept, so the caller reseeds.
    lastHelperKeptConversation = false
  }

  func helperJSON(prompt: String, schemaJSON: String, maxOutputTokens: Int) async throws -> Data {
    guard let engine, let resolved, let options else { throw ChatError.engineNotReady }
    guard !generating else { throw ChatError.underlying(message: "Busy generating.") }
    generating = true
    defer {
      generating = false
      helperConversation = nil
    }
    let started = Date()
    let keep = beginHelper()
    let output: String
    do {
      // Speculative decoding (MTP) breaks grammar-constrained decoding on
      // device (drafted tokens bypass the JSON mask: garbled output or
      // "compute_mask() called after stop"), so helpers decode plainly.
      let helper = try await engine.createConversation(
        with: ConversationConfig(enableResponseFormat: true, enableSpeculativeDecoding: false))
      helperConversation = helper
      try checkHelperNotCancelled()
      let reply = try await helper.sendMessage(
        LiteRTLM.Message(prompt), maxOutputTokens: maxOutputTokens,
        responseFormat: try .json(schema: schemaJSON))
      output = reply.toString
    } catch {
      await endHelperAfterFailure(keep: keep, engine: engine, resolved: resolved, options: options)
      throw error
    }
    try await endHelper(keep: keep, engine: engine, resolved: resolved, options: options)
    Log.engine.info(
      "helper: \(output.utf8.count) bytes in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s, kept \(keep)")
    return Data(output.utf8)
  }

  func helperTexts(
    _ prompts: [String], maxOutputTokens: Int, progress: @Sendable (Int) async -> Void
  ) async throws -> [String] {
    guard let engine, let resolved, let options else { throw ChatError.engineNotReady }
    guard !generating else { throw ChatError.underlying(message: "Busy generating.") }
    generating = true
    defer {
      generating = false
      helperConversation = nil
    }
    let started = Date()
    let keep = beginHelper()
    var outputs: [String] = []
    do {
      for prompt in prompts {
        // Stop ends the run with the outputs so far.
        if Task.isCancelled || cancelRequested { break }
        // No grammar here, so speculative decoding stays on for speed.
        helperConversation = nil
        let helper = try await engine.createConversation(
          with: ConversationConfig(enableSpeculativeDecoding: resolved.enableSpeculativeDecoding))
        helperConversation = helper
        if cancelRequested { break }
        let reply = try await helper.sendMessage(
          LiteRTLM.Message(prompt), maxOutputTokens: maxOutputTokens)
        outputs.append(reply.toString.trimmingCharacters(in: .whitespacesAndNewlines))
        await progress(outputs.count)
      }
    } catch {
      await endHelperAfterFailure(keep: keep, engine: engine, resolved: resolved, options: options)
      throw error
    }
    try await endHelper(keep: keep, engine: engine, resolved: resolved, options: options)
    Log.engine.info(
      "helper texts: \(outputs.count)/\(prompts.count) in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s, kept \(keep)")
    return outputs
  }

  func transcribe(audioFileURL: URL) async throws -> String {
    guard let engine, let resolved, let options else { throw ChatError.engineNotReady }
    guard resolved.enableAudio else {
      throw ChatError.underlying(message: "Audio input is off in this session.")
    }
    guard !generating else { throw ChatError.underlying(message: "Busy generating.") }
    generating = true
    defer {
      generating = false
      helperConversation = nil
    }
    let started = Date()
    let keep = beginHelper()
    let text: String
    do {
      let helper = try await engine.createConversation(
        with: ConversationConfig(
          samplerConfig: try SamplerConfig(topK: 1, topP: 1, temperature: 0),
          enableSpeculativeDecoding: resolved.enableSpeculativeDecoding))
      helperConversation = helper
      try checkHelperNotCancelled()
      let reply = try await helper.sendMessage(
        LiteRTLM.Message(contents: [
          .text(Dictation.instruction), .audioFile(audioFileURL.path),
        ]), maxOutputTokens: Dictation.maxOutputTokens)
      text = reply.toString
    } catch {
      await endHelperAfterFailure(keep: keep, engine: engine, resolved: resolved, options: options)
      throw error
    }
    try await endHelper(keep: keep, engine: engine, resolved: resolved, options: options)
    Log.engine.info(
      "transcribe: \(text.count) chars in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s, kept \(keep)")
    return Dictation.clean(text)
  }

  // MARK: Send

  nonisolated func send(
    text: String, imageData: Data?, audioFileURL: URL?
  ) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        await self.runSend(
          text: text, imageData: imageData, audioFileURL: audioFileURL,
          continuation: continuation)
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func runSend(
    text: String, imageData: Data?, audioFileURL: URL?,
    continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
  ) async {
    guard let conversation, let resolved, let spec else {
      continuation.finish(throwing: ChatError.engineNotReady)
      return
    }
    guard !generating else {
      continuation.finish(throwing: ChatError.underlying(message: "Already generating."))
      return
    }
    // Stopped before it started (the reply's task was cancelled): no native work at all.
    guard !Task.isCancelled else {
      continuation.finish(throwing: ChatError.generationCancelled)
      return
    }
    generating = true
    cancelRequested = false
    defer { generating = false }

    var contents: [Content] = [.text(Self.promptText(text, imageData, audioFileURL))]
    if let imageData { contents.append(.imageData(imageData)) }
    if let audioFileURL { contents.append(.audioFile(audioFileURL.path)) }
    let message = LiteRTLM.Message(contents: contents)

    // Hard guarantee against KV-cache overflow (which corrupts the native
    // heap): everything this turn adds must fit the room left. Tool rounds run
    // inside LiteRT-LM (each = a tool result + another generation under the
    // same cap), so with tools the room is split: a quarter per generation,
    // an eighth per tool result, at most two tool calls (3/4 + 2/8 = 1).
    let prefilled = await tokensAfterPrefill(
      text: text, imageData: imageData, audioFileURL: audioFileURL)
    guard
      let room = ContextBudget.outputCap(
        maxNumTokens: resolved.maxNumTokens, used: prefilled, input: 0)
    else {
      Log.generation.error(
        "context full: \(prefilled) after prefill, window=\(resolved.maxNumTokens)")
      continuation.finish(throwing: ChatError.contextFull)
      return
    }
    // Stopped while the message was being counted.
    if cancelRequested || Task.isCancelled {
      continuation.finish(throwing: ChatError.generationCancelled)
      return
    }
    // `web_search` is registered on its own (automatic web search) even when
    // the on-device tools are off, so it needs the same split.
    let budget = ToolBudget.plan(
      room: room, toolsOffered: toolsEnabled || options?.webSearchTool == true)
    let cap = budget.outputCap
    let maxOutputTokens = min(resolved.maxOutputTokens ?? cap, cap)
    ToolBudget.begin(budget.limits)
    defer { ToolBudget.end() }
    // Safety net for tool rounds (results are trimmed by estimate): stop before streamed output
    // and tool results could exceed the room. Without tools the runtime's cap is exact.
    let guardsToolRounds = budget.limits.maxCalls > 0
    var emittedBytes = 0
    var emittedWeight = 0

    let started = Date()
    var firstChunkAt: Date?
    // Tool calls run inside LiteRT-LM and never appear in streamed chunks;
    // report the tools that actually ran (status line, chips, parts).
    let toolCursor = ToolActivity.cursor
    var reportedTools = 0
    func newToolActivity() -> [ToolActivityRecord] {
      let records = ToolActivity.records(since: toolCursor)
      defer { reportedTools = records.count }
      return Array(records.dropFirst(reportedTools))
    }

    func stats(started: Date, firstChunkAt: Date?) -> GenerationStats {
      // Token counts and speed from the runtime; time to first token from this reply's own
      // clock (the runtime's figure is the conversation's first reply, not this one).
      if let info = try? conversation.getBenchmarkInfo() {
        return GenerationStats(
          timeToFirstToken: firstChunkAt?.timeIntervalSince(started),
          totalTime: Date().timeIntervalSince(started),
          inputTokens: info.lastPrefillTokenCount,
          outputTokens: info.lastDecodeTokenCount,
          decodeTokensPerSecond: info.lastDecodeTokensPerSecond > 0
            ? info.lastDecodeTokensPerSecond : nil,
          backend: resolved.backendLabel,
          modelID: spec.id
        )
      }
      return GenerationStats(
        timeToFirstToken: firstChunkAt?.timeIntervalSince(started),
        totalTime: Date().timeIntervalSince(started),
        inputTokens: nil,
        outputTokens: nil,
        decodeTokensPerSecond: nil,
        backend: resolved.backendLabel,
        modelID: spec.id
      )
    }

    do {
      // Rounds after a tool response get the same cap; at most one more round than the
      // reply's tool calls (the last answers "limit reached"), then the stream ends.
      let stream = conversation.sendMessageStream(
        message, maxOutputTokens: maxOutputTokens, followUpMaxOutputTokens: maxOutputTokens,
        maxToolRounds: budget.limits.maxCalls + 1)
      for try await chunk in stream {
        if Task.isCancelled {
          try? conversation.cancel()
          continuation.finish(throwing: ChatError.generationCancelled)
          return
        }
        if firstChunkAt == nil { firstChunkAt = Date() }
        let thought = chunk.channels["thought"]
        if guardsToolRounds {
          for piece in [chunk.toString, thought ?? ""] {
            emittedBytes += piece.utf8.count
            emittedWeight += Chunker.weight(of: piece)
          }
        }
        let activity = newToolActivity()
        continuation.yield(
          .chunk(
            ChatChunk(
              textDelta: chunk.toString,
              thoughtDelta: thought,
              toolNames: chunk.toolCalls.map(\.name) + activity.map(\.name),
              toolActivity: activity
            )))
        let emittedTokens = ContextBudget.estimateTextTokens(bytes: emittedBytes, weight: emittedWeight)
        if guardsToolRounds, emittedTokens + ToolBudget.resultTokens > room {
          Log.generation.error(
            "context guard: stopping at ~\(emittedTokens)+\(ToolBudget.resultTokens) tokens of \(room)")
          try? conversation.cancel()
          continuation.finish(throwing: ChatError.replyTruncated)
          return
        }
      }
      // Iteration ends without an error when this task is cancelled (the caller stopped
      // reading); the wrapper has already stopped the native work, which leaves the
      // conversation cancelled.
      if Task.isCancelled {
        Log.generation.info("cancelled (task)")
        continuation.finish(throwing: ChatError.generationCancelled)
        return
      }
      let lateActivity = newToolActivity()
      if !lateActivity.isEmpty {
        continuation.yield(
          .chunk(
            ChatChunk(
              textDelta: "", thoughtDelta: nil, toolNames: lateActivity.map(\.name),
              toolActivity: lateActivity)))
      }
      if cancelRequested {
        Log.generation.info("cancelled (user)")
        continuation.finish(throwing: ChatError.generationCancelled)
        return
      }
      let final = stats(started: started, firstChunkAt: firstChunkAt)
      Log.generation.info(
        "finished: \(final.footerLine, privacy: .public), out=\(final.outputTokens ?? -1) cap=\(maxOutputTokens) kv=\(self.usedTokens())/\(resolved.maxNumTokens)"
      )
      continuation.yield(.finished(final))
      continuation.finish()
    } catch {
      if cancelRequested || Task.isCancelled || error is CancellationError {
        Log.generation.info("cancelled: \(String(describing: error), privacy: .public)")
        continuation.finish(throwing: ChatError.generationCancelled)
        return
      }
      if let streamError = error as? LiteRTLMError,
        case .conversation(.recurringToolCallLimitExceeded) = streamError
      {
        Log.generation.error("tool rounds: limit reached")
        continuation.finish(throwing: ChatError.replyTruncated)
        return
      }
      Log.generation.error("stream error: \(String(describing: error), privacy: .public)")
      // The native side may still be decoding (an unreadable chunk) or hold a half-written
      // turn: stop it; the caller rebuilds the conversation before the next send.
      try? conversation.cancel()
      if let chatError = error as? ChatError {
        continuation.finish(throwing: chatError)
      } else {
        continuation.finish(
          throwing: ChatError.underlying(message: error.localizedDescription))
      }
    }
  }

  func cancel() async {
    Log.generation.info("cancel requested (generating=\(self.generating))")
    guard generating else { return }
    cancelRequested = true
    if helperActive {
      // Before its conversation exists the helper sees `cancelRequested`; the kept main
      // conversation must not be cancelled (it would reject the next message).
      try? helperConversation?.cancel()
    } else {
      try? conversation?.cancel()
    }
  }
}

// MARK: - Mock engine (previews, simulator UI smoke tests)

/// Deterministic scripted engine. No model required.
///
/// It models what the runtime does to the conversation, so tests check behavior: the texts
/// the "native" conversation holds (``held``), helpers that wipe it as Google's LiteRT-LM does
/// (or keep it, like ours), a cancelled conversation that rejects the next send until it is
/// reseeded, injected stream errors, and a gate that holds the next helper.
actor MockChatEngine: ChatEngineProtocol {
  var script: [ChatChunk]
  var stats: GenerationStats
  private(set) var loadedModel: ModelID?
  var loadResult: ResolvedInference
  /// Test instrumentation: how often `load` ran and every reseeded history.
  private(set) var loadCount = 0
  private(set) var reseedLog: [[String]] = []
  /// Texts the native conversation holds, oldest first (the KV cache's contents).
  private(set) var held: [String] = []
  /// What the conversation held when each send started.
  private(set) var heldAtSend: [[String]] = []
  /// Cancelled: LiteRT-LM rejects the next message ("CANCELLED") until a reseed or load.
  private(set) var poisoned = false
  /// Fail the next send with `error` after `afterChunks` chunks (tests).
  private var streamFailure: (afterChunks: Int, error: ChatError)?
  func failNextSend(afterChunks: Int, with error: ChatError) {
    streamFailure = (afterChunks, error)
  }
  /// Hold the next helper until ``releaseHelper()`` (tests interleave sends with it).
  private var gateNextHelper = false
  private var gate: CheckedContinuation<Void, Never>?
  /// A helper is waiting at the gate.
  private(set) var helperWaiting = false
  /// Stop arrived while a helper ran: it ends with ``ChatError/generationCancelled``.
  private var helperCancelRequested = false
  private var helperRunning = false
  func holdNextHelper() { gateNextHelper = true }
  func releaseHelper() {
    gate?.resume()
    gate = nil
  }

  /// Runs at the start of every helper: busy check, gate, then the conversation as a helper
  /// leaves it on this runtime.
  private func beginHelper() async throws {
    if generating { throw ChatError.underlying(message: "Busy generating.") }
    helperRunning = true
    helperCancelRequested = false
    defer { helperRunning = false }
    if gateNextHelper {
      gateNextHelper = false
      helperWaiting = true
      await withCheckedContinuation { gate = $0 }
      helperWaiting = false
    }
    if !helpersKeepConversation { held = [] }
    if helperCancelRequested {
      lastHelperKeptConversation = false
      throw ChatError.generationCancelled
    }
    lastHelperKeptConversation = helpersKeepConversation
  }
  /// Simulated load latency (exposes overlapping-load races in tests).
  var loadDelay: Duration = .zero

  func setLoadDelay(_ delay: Duration) { loadDelay = delay }

  init(
    script: [ChatChunk] = [
      ChatChunk(textDelta: "Hello", thoughtDelta: "Drafting"),
      ChatChunk(textDelta: " from", thoughtDelta: " a reply"),
      ChatChunk(textDelta: " the mock engine!", thoughtDelta: nil),
    ],
    modelID: ModelID = .e4b
  ) {
    self.script = script
    self.stats = GenerationStats(
      timeToFirstToken: 0.2, totalTime: 0.6, inputTokens: 8, outputTokens: 12,
      decodeTokensPerSecond: 40, backend: "Mock", modelID: modelID)
    self.loadResult = InferencePlanner.resolve(
      options: InferenceOptions(), model: modelID, memoryBytes: 8_000_000_000)
  }

  func load(
    spec: ModelSpec, modelURL: URL, options: InferenceOptions, memoryBytes: UInt64,
    enableTools: Bool
  ) async throws -> ResolvedInference {
    loadCount += 1
    applyConversationOptions(options)
    loadedModel = nil
    held = []
    poisoned = false
    if loadDelay > .zero { try? await Task.sleep(for: loadDelay) }
    loadedModel = spec.id
    loadResult = InferencePlanner.resolve(options: options, model: spec.id, memoryBytes: memoryBytes)
    return loadResult
  }

  func unload() async { loadedModel = nil }
  var isLoaded: Bool { loadedModel != nil }
  var currentModelID: ModelID? { loadedModel }

  func reseed(history: [(role: ChatRole, text: String)]) async throws {
    reseedLog.append(history.map(\.text))
    held = history.map(\.text)
    poisoned = false
  }

  /// Scripted `fitContext` outcome (tests): `.success(true)` = trimmed.
  private(set) var fitResult: Result<Bool, ChatError> = .success(false)
  private(set) var fitCalls = 0
  func setFitResult(_ result: Result<Bool, ChatError>) { fitResult = result }

  func fitContext(
    text: String, imageData: Data?, audioFileURL: URL?,
    history: [(role: ChatRole, text: String)]
  ) async throws -> Bool {
    fitCalls += 1
    // Like the live engine: a message too long even alone is found on an empty conversation.
    if case .failure = fitResult { held = [] }
    return try fitResult.get()
  }

  nonisolated func send(
    text: String, imageData: Data?, audioFileURL: URL?
  ) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        let script =
          text.localizedCaseInsensitiveContains("markdown")
          ? MockChatEngine.markdownSample : await self.script
        // Like the real model: reasoning only streams when thinking is on.
        let thinking = await self.thinkingEnabled
        let stats = await self.stats
        await self.recordSend(text)
        if await self.poisoned {
          continuation.finish(throwing: ChatError.underlying(message: "CANCELLED"))
          return
        }
        let failure = await self.takeStreamFailure()
        await self.setGenerating(true)
        var reply = ""
        for (index, chunk) in script.enumerated() {
          if let failure, index == failure.afterChunks {
            await self.setGenerating(false)
            continuation.finish(throwing: failure.error)
            return
          }
          try? await Task.sleep(for: .milliseconds(60))
          let stopRequested = await self.cancelRequested
          if Task.isCancelled || stopRequested {
            await self.setGenerating(false)
            await self.poison()
            continuation.finish(throwing: ChatError.generationCancelled)
            return
          }
          var chunk = chunk
          if !thinking { chunk.thoughtDelta = nil }
          reply += chunk.textDelta
          continuation.yield(.chunk(chunk))
        }
        await self.setGenerating(false)
        await self.hold(text, reply)
        continuation.yield(.finished(stats))
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private var generating = false
  private(set) var cancelRequested = false
  private(set) var thinkingEnabled = false
  /// Test instrumentation: the system prompt of the current conversation.
  private(set) var systemPrompt = ""
  func applyConversationOptions(_ options: InferenceOptions) {
    thinkingEnabled = options.enableThinking
    systemPrompt = options.systemPrompt
  }
  /// Test instrumentation: every prompt sent.
  private(set) var sendLog: [String] = []
  private func recordSend(_ text: String) {
    sendLog.append(text)
    heldAtSend.append(held)
  }
  private func takeStreamFailure() -> (afterChunks: Int, error: ChatError)? {
    defer { streamFailure = nil }
    return streamFailure
  }
  private func poison() { poisoned = true }
  private func hold(_ text: String, _ reply: String) { held += [text, reply] }

  private func setGenerating(_ value: Bool) {
    generating = value
    if value { cancelRequested = false }
  }

  func cancel() async {
    if generating { cancelRequested = true }
    if helperRunning { helperCancelRequested = true }
  }

  /// Rich reply for UI checks of markdown rendering (prompt contains "markdown").
  static let markdownSample: [ChatChunk] = {
    let text = """
      ## Lighthouse facts

      Lighthouses use **Fresnel lenses** to focus light. A beam is visible for about *20 nautical miles*.

      1. Lamp
      2. Lens
         - Fresnel rings
      3. Gallery

      ```swift
      let range = 20 // nautical miles
      print("Visible for \\(range) nm")
      ```

      | Part | Purpose |
      | :--- | :--- |
      | Lens | Focus the light |
      | Gallery | Maintenance access |

      Since $d \\approx 1.17\\sqrt{h}$, a taller tower sees farther:

      $$
      d = 1.17 \\sqrt{h}
      $$

      > Keep the lens polished.
      """
    // Stream in a few chunks like a real reply.
    let parts = stride(from: 0, to: text.count, by: 120).map { offset -> String in
      let start = text.index(text.startIndex, offsetBy: offset)
      let end = text.index(start, offsetBy: min(120, text.count - offset))
      return String(text[start..<end])
    }
    return parts.map { ChatChunk(textDelta: $0, thoughtDelta: nil) }
  }()

  /// Scripted helper output (tests) and a log of prompts.
  private(set) var helperResponse = Data(#"{"title":"Mock chat"}"#.utf8)
  private(set) var helperPrompts: [String] = []
  func setHelperResponse(_ json: String) { helperResponse = Data(json.utf8) }
  func setScript(_ text: String) { script = [ChatChunk(textDelta: text, thoughtDelta: nil)] }
  /// Whether helpers keep the main conversation, as our runtime does (tests).
  private(set) var helpersKeepConversation = false
  func setHelpersKeepConversation(_ value: Bool) { helpersKeepConversation = value }
  private(set) var lastHelperKeptConversation = false

  func helperJSON(prompt: String, schemaJSON: String, maxOutputTokens: Int) async throws -> Data {
    try await beginHelper()
    helperPrompts.append(prompt)
    return helperResponse
  }

  /// Test instrumentation: recordings transcribed.
  private(set) var transcribed: [URL] = []
  var transcript = "Dictated text."
  func setTranscript(_ text: String) { transcript = text }

  func transcribe(audioFileURL: URL) async throws -> String {
    try await beginHelper()
    transcribed.append(audioFileURL)
    return transcript
  }

  /// Test instrumentation: every plain-text helper prompt.
  private(set) var helperTextPrompts: [String] = []

  func helperTexts(
    _ prompts: [String], maxOutputTokens: Int, progress: @Sendable (Int) async -> Void
  ) async throws -> [String] {
    try await beginHelper()
    var outputs: [String] = []
    for prompt in prompts {
      helperTextPrompts.append(prompt)
      outputs.append("- Key point \(outputs.count + 1) of this part.")
      await progress(outputs.count)
    }
    return outputs
  }
}
