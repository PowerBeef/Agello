import AVFoundation
import Foundation
import LiteRTLM
import OSLog

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
  /// The window the last load chose from the memory left (32K on 12 GB devices or 16K, stepping
  /// down when short). Later plans keep it, so a settings change doesn't reload the engine to try
  /// a larger window again.
  private var loadedContextTokens: Int?
  private var toolsEnabled = true
  private var generating = false
  /// The last reply's chunks as the wrapper delivered them, when a probe asks for them
  /// (``recordChunks(_:)``; probe 35): text, channels and tool calls, one line a chunk.
  private(set) var chunkLog: [String]?

  func recordChunks(_ on: Bool) { chunkLog = on ? [] : nil }
  /// Set by ``cancel()`` during a generation. LiteRT-LM leaves the
  /// conversation cancelled afterwards (the next message fails with
  /// "CANCELLED"), so a cancelled generation always ends as
  /// ``ChatError/generationCancelled`` and the caller must reseed.
  private var cancelRequested = false
  private(set) var lastHelperKeptConversation = false
  private(set) var lastEvictedHistory: [(role: ChatRole, text: String)] = []
  var maxVisionTokenBudget: Int? {
    capabilities.flatMap { $0.maxVisionTokenBudget > 0 ? $0.maxVisionTokenBudget : nil }
  }
  /// The helper conversation running now, so ``cancel()`` stops it rather
  /// than the kept main conversation.
  private var helperConversation: Conversation?
  /// The throwaway validation probe running during ``load(...)``, so backgrounding cancels and drains it.
  private var loadingConversation: Conversation?
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
  /// Set by ``reseedSampling(history:seed:)``: the conversation samples (no MTP, this seed).
  private var samplingSeed: Int?

  var isLoaded: Bool { engine != nil && resolved != nil }

  /// Tokens the live conversation holds in the KV cache, as the runtime
  /// counts them (0 until the first send; device tests).
  func cachedTokenCount() -> Int { (try? conversation?.getTokenCount()) ?? 0 }

  /// Tokens currently held by the KV cache (measured once anything was sent).
  private func usedTokens() -> Int {
    let measured = (try? conversation?.getTokenCount()) ?? 0
    return measured > 0 ? measured : seedTokens
  }

  /// `text` as the model's tokenizer encodes it, or nil without an engine. For comparing
  /// replies token by token (docs/CLI.md): these are the text's tokens, re-encoded, not the
  /// ids the sampler chose.
  func tokenIDs(_ text: String) async -> [Int]? {
    guard let engine else { return nil }
    return try? await engine.tokenize(text)
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

  /// The text a message is sent with (a prompt of its own when it's only an image or audio), its
  /// chat markers neutralized (``PromptText``).
  private static func promptText(_ text: String, _ imageData: Data?, _ audioFileURL: URL?) -> String {
    if imageData != nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Describe this image in detail."
    }
    if !text.isEmpty { return PromptText.neutralized(text) }
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
    // Stats for the per-reply footer (TTFT, tok/s) come from the runtime's telemetry: benchmark
    // mode would make every GPU wait spin (RuntimeTelemetry).
    ExperimentalFlags.optIntoExperimentalAPIs()
    ExperimentalFlags.enableBenchmark = false
    RuntimeTelemetry.recordSpans()
    // Reasoning never stays in the KV cache: at the next message the runtime
    // rewinds and refills the answer without it. That keeps the room for
    // the conversation, and matches a reseed from saved history (which has
    // no reasoning). LiteRT-LM defaults to this too; set it explicitly.
    ExperimentalFlags.filterChannelContentFromKvCache = true

    guard FileManager.default.fileExists(atPath: modelURL.path) else {
      throw ChatError.modelFileMissing
    }

    unloadAndRecord()
    // 64K (as the file allows) or less as memory allows: measured after the old engine is gone.
    let room = MemoryProbe.roomBytes()
    loadedContextTokens = DeviceProfile.contextTokens(
      standard: DeviceProfile.defaultMaxTokens(model: spec.id, memoryBytes: memoryBytes), roomBytes: room)
    // Introspect the model file (cheap, no engine needed): its export window caps the plan, and
    // the plan is intersected with its capabilities (MTP support, thinking, modalities, the
    // model's context and visual-token limits).
    let inspected = Self.inspect(modelURL: modelURL)
    let exportWindow = ContextBudget.exportWindow(reported: inspected?.maxContextTokens)
    var plan = InferencePlanner.resolve(
      options: options, model: spec.id, memoryBytes: memoryBytes, contextTokens: loadedContextTokens,
      exportWindow: exportWindow)
    loadLog = lastUnload.map { [$0] } ?? []
    loadLog.append(
      String(
        format: "window: %d tokens (the file's %d) with %@ left", plan.maxNumTokens, exportWindow,
        room.map { String(format: "%.2f GB", Double($0) / 1e9) } ?? "no limit"))
    if let caps = inspected {
      capabilities = caps
      plan = InferencePlanner.applyCapabilities(caps, to: plan)
      loadLog.append(
        "caps: mtp=\(caps.speculativeDecoding) thinking=\(caps.thinking) "
          + "tools=\(caps.functionCalling) vision=\(caps.vision) audio=\(caps.audio) "
          + "maxContext=\(caps.maxContextTokens) maxVisionBudget=\(caps.maxVisionTokenBudget)")
    } else {
      capabilities = nil
      // Assume what Gemma 4's phone files support (vision tokens clamped to their default).
      plan = InferencePlanner.applyCapabilities(.full, to: plan)
      loadLog.append("caps: unavailable (ModelInfo failed)")
    }

    // Engine-level flags must be set before the engine is created. The
    // conversation-level MTP flag (set in makeConversation) inherits these.
    ExperimentalFlags.enableSpeculativeDecoding = plan.enableSpeculativeDecoding

    // Attempt ladder: multimodal, then text-only, so a model file without
    // vision/audio executors still loads. Everything runs on the GPU: a
    // load that fails on the last attempt is retried once, then reported.
    let attempts = InferencePlanner.attempts(for: plan)
    var lastError: Error = ChatError.engineNotReady
    for attempt in attempts {
      let label = Self.describe(attempt)
      for trial in 1...2 {
        // In the background a GPU load fails: stop, and load when the app is back.
        guard GPUGate.isOpen else {
          loadLog.append("stopped: the app is in the background")
          throw GPUGate.closedError
        }
        let started = Date()
        do {
          let engine = try await Self.makeEngine(modelURL: modelURL, resolved: attempt)
          guard GPUGate.isOpen else {
            loadLog.append("stopped: the app is in the background")
            throw GPUGate.closedError
          }
          try await validate(engine)
          guard GPUGate.isOpen else {
            loadLog.append("stopped: the app is in the background")
            throw GPUGate.closedError
          }
          let conversation = try await Self.makeConversation(
            engine: engine, resolved: attempt, options: options, toolsEnabled: enableTools,
            history: []
          )
          self.engine = engine
          self.conversation = conversation
          self.samplingSeed = nil
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
          // Stop immediately if backgrounding closed the GPU gate mid-load.
          if (error as? ChatError) == GPUGate.closedError || !GPUGate.isOpen {
            throw GPUGate.closedError
          }
          // A broken-but-"successful" engine usually means a section failed
          // to map while a previous engine's mappings were still alive: give
          // them a moment to be released and retry the same configuration.
          // The last attempt gets its second try whatever the error: nothing
          // comes after it.
          guard trial == 1, !(error is CancellationError),
            error is EngineValidationError || attempt == attempts.last
          else { break }
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
    weak let released = engine
    let before = MemoryProbe.footprintBytes()
    unloadLocked()
    let after = MemoryProbe.footprintBytes()
    lastUnload = String(
      format: "unload: footprint %.2f -> %.2f GB, engine object %@", Double(before) / 1e9,
      Double(after) / 1e9, released == nil ? "freed" : "still referenced")
    Log.engine.info("\(self.lastUnload ?? "", privacy: .public)")
  }

  private func unloadLocked() {
    loadingConversation = nil
    helperConversation = nil
    helperActive = false
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
      backend: .gpu,
      // Vision runs on Metal GPU (A19 Pro Neural Accelerators, P4.2); audio
      // Conformer stays on P-core XNNPACK with lazy load/unload.
      visionBackend: resolved.enableVision ? .gpu : nil,
      audioBackend: resolved.enableAudio ? .cpu() : nil,
      maxNumTokens: resolved.maxNumTokens,
      cacheDir: try EngineCache.directory()
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
  private func validate(_ engine: Engine) async throws {
    guard GPUGate.isOpen else { throw GPUGate.closedError }
    let probe = try await engine.createConversation(with: ConversationConfig())
    loadingConversation = probe
    defer { loadingConversation = nil }
    guard GPUGate.isOpen else { throw GPUGate.closedError }
    do {
      _ = try await probe.sendMessage(LiteRTLM.Message("Hi"), maxOutputTokens: 1)
    } catch {
      if !GPUGate.isOpen { throw GPUGate.closedError }
      if error is CancellationError { throw error }
      throw EngineValidationError(underlying: String(describing: error))
    }
  }

  private static func activeTools(toolsEnabled: Bool, options: InferenceOptions) -> [any Tool] {
    ActiveTools.make(toolsEnabled: toolsEnabled, options: options)
  }

  private static func makeConversation(
    engine: Engine, resolved: ResolvedInference, options: InferenceOptions,
    toolsEnabled: Bool, history: [(role: ChatRole, text: String)], samplingSeed: Int? = nil,
    alreadyTrimmed: Bool = false
  ) async throws -> Conversation {
    let sampler = try SamplerConfig(
      topK: resolved.topK, topP: resolved.topP, temperature: resolved.temperature,
      seed: samplingSeed ?? 0)
    let tools = activeTools(toolsEnabled: toolsEnabled, options: options)
    let toolSchemaTokens = ContextBudget.estimateToolSchemaTokens(
      ToolManager(tools: tools).toolsJsonDescription)
    let replayed: [(role: ChatRole, text: String)]
    if alreadyTrimmed {
      replayed = history
    } else {
      let budget = ContextBudget.historyBudget(
        maxNumTokens: resolved.maxNumTokens, input: 0, thinkingBudget: resolved.thinkingBudget,
        preamble: ContextBudget.preambleTokens(
          systemPrompt: options.systemPrompt, toolCount: tools.count,
          toolSchemaTokens: toolSchemaTokens))
      replayed = ContextBudget.trimmedHistory(history, budget: budget)
    }
    let initial = replayed.map { turn -> LiteRTLM.Message in
      switch turn.role {
      case .user: return LiteRTLM.Message(PromptText.neutralized(turn.text), role: .user)
      case .model: return LiteRTLM.Message(PromptText.neutralized(turn.text), role: .model)
      }
    }
    let config = ConversationConfig(
      // Memories and personalization are text from chats: no chat markers either.
      systemMessage: options.systemPrompt.isEmpty
        ? nil : LiteRTLM.Message(PromptText.neutralized(options.systemPrompt)),
      initialMessages: initial,
      tools: tools,
      samplerConfig: sampler,
      thinkingConfig: resolved.thinkingBudget.map {
        ThinkingConfig(enableThinking: true, thinkingTokenBudget: $0)
      },
      visualTokenBudget: resolved.visualTokenBudget,
      // MTP decodes greedily whatever the sampler (probe 18): off when this one samples.
      enableSpeculativeDecoding: samplingSeed == nil ? resolved.enableSpeculativeDecoding : false
    )
    return try await engine.createConversation(with: config)
  }

  // MARK: Reseed

  func reseed(history: [(role: ChatRole, text: String)]) async throws {
    samplingSeed = nil
    try await rebuild(history: history)
  }

  func reseedSampling(history: [(role: ChatRole, text: String)], seed: Int) async throws {
    samplingSeed = seed
    try await rebuild(history: history)
  }

  /// A new conversation holding `history`, sampling or not as it is now.
  private func rebuild(
    history: [(role: ChatRole, text: String)], alreadyTrimmed: Bool = false
  ) async throws {
    guard let engine, let resolved, let options else { throw ChatError.engineNotReady }
    guard GPUGate.isOpen else { throw GPUGate.closedError }
    let conversation = try await Self.makeConversation(
      engine: engine, resolved: resolved, options: options, toolsEnabled: toolsEnabled,
      history: history, samplingSeed: samplingSeed, alreadyTrimmed: alreadyTrimmed
    )
    self.conversation = conversation
    let tools = Self.activeTools(toolsEnabled: toolsEnabled, options: options)
    let toolSchemaTokens = ContextBudget.estimateToolSchemaTokens(
      ToolManager(tools: tools).toolsJsonDescription)
    seedTokens = await Self.seedTokens(
      conversation, engine: engine, history: history, systemPrompt: options.systemPrompt,
      toolCount: tools.count, toolSchemaTokens: toolSchemaTokens,
      resolved: resolved, alreadyTrimmed: alreadyTrimmed)
  }

  /// What a new conversation prefills before its first message: its preamble and replayed
  /// history as the runtime renders them, plus BOS; estimated if the runtime can't count.
  private static func seedTokens(
    _ conversation: Conversation, engine: Engine, history: [(role: ChatRole, text: String)],
    systemPrompt: String, toolCount: Int = 0, toolSchemaTokens: Int? = nil,
    resolved: ResolvedInference? = nil, alreadyTrimmed: Bool = false
  ) async -> Int {
    if let preface = try? conversation.renderPrefaceIntoString(),
      let exact = try? await engine.countTokens(preface)
    {
      return exact + 1
    }
    let preamble = ContextBudget.preambleTokens(
      systemPrompt: systemPrompt, toolCount: toolCount, toolSchemaTokens: toolSchemaTokens)
    let replayed: [(role: ChatRole, text: String)]
    if alreadyTrimmed || resolved == nil {
      replayed = history
    } else if let resolved {
      let budget = ContextBudget.historyBudget(
        maxNumTokens: resolved.maxNumTokens, input: 0, thinkingBudget: resolved.thinkingBudget,
        preamble: preamble)
      replayed = ContextBudget.trimmedHistory(history, budget: budget)
    } else {
      replayed = history
    }
    return preamble + ContextBudget.estimateHistory(replayed)
  }

  private static let signposter = OSSignposter(
    subsystem: "com.patricedery.agello", category: .pointsOfInterest)

  // MARK: Context window

  /// Make room for `text` and a reply: nothing to do when it fits after what the conversation
  /// holds; otherwise the conversation is rebuilt with the newest history that fits beside it
  /// (true). Throws ``ChatError/messageTooLong`` when the message doesn't fit even alone, which
  /// leaves the conversation empty: the caller reseeds before the next send.
  func fitContext(
    text: String, imageData: Data?, audioFileURL: URL?,
    history: [(role: ChatRole, text: String)]
  ) async throws -> Bool {
    guard let resolved else { throw ChatError.engineNotReady }
    lastEvictedHistory = []
    if conversation == nil { try await rebuild(history: []) }
    guard conversation != nil else { throw ChatError.engineNotReady }
    let window = resolved.maxNumTokens
    let thinking = resolved.thinkingBudget
    func fits(_ total: Int) -> Bool {
      ContextBudget.fits(used: total, input: 0, maxNumTokens: window, thinkingBudget: thinking)
    }
    let used = await tokensAfterPrefill(text: text, imageData: imageData, audioFileURL: audioFileURL)
    if fits(used) {
      ReplyTrace.mark("fit", ["trimmed": .bool(false), "used": .int(used)])
      return false
    }

    // The message alone, on an empty conversation: preamble, tools and the message, counted.
    try await rebuild(history: [], alreadyTrimmed: true)
    let alone = await tokensAfterPrefill(text: text, imageData: imageData, audioFileURL: audioFileURL)
    guard fits(alone) else { throw ChatError.messageTooLong }
    var budget = ContextBudget.historyBudget(
      maxNumTokens: window, input: alone, thinkingBudget: thinking, preamble: 0)
    var turnTokens: [Int] = []
    for turn in history { turnTokens.append(await textTokens(PromptText.neutralized(turn.text))) }
    var trimmed: [(role: ChatRole, text: String)] = []
    var evicted: [(role: ChatRole, text: String)] = history
    var total = alone
    // The turns' own template tokens aren't counted per turn: check the rebuilt conversation and
    // trim by what it's over until it fits.
    for _ in 0..<4 {
      let split = ContextBudget.trimHistory(history, budget: budget, tokens: turnTokens)
      trimmed = split.kept
      evicted = split.evicted
      if trimmed.isEmpty { break }
      try await rebuild(history: trimmed, alreadyTrimmed: true)
      total = await tokensAfterPrefill(text: text, imageData: imageData, audioFileURL: audioFileURL)
      if fits(total) { break }
      let over =
        total + ContextBudget.replyReserve(maxNumTokens: window, thinkingBudget: thinking)
        + ContextBudget.safetyMargin - window
      budget -= max(over, ContextBudget.perTurnOverhead)
      trimmed = []
      evicted = history
    }
    if trimmed.isEmpty {
      try await rebuild(history: [], alreadyTrimmed: true)
      total = alone
    }
    lastEvictedHistory = evicted
    Log.engine.info(
      "context: was \(used), now \(total) of \(window) (alone \(alone)); replaying \(trimmed.count)/\(history.count) turns"
    )
    return true
  }

  /// Plan for `options` on this model, intersected with the file's capabilities.
  private func plan(for options: InferenceOptions, model: ModelID) -> ResolvedInference {
    let plan = InferencePlanner.resolve(
      options: options, model: model, memoryBytes: DeviceProfile.current.physicalMemoryBytes,
      contextTokens: loadedContextTokens,
      exportWindow: ContextBudget.exportWindow(reported: capabilities?.maxContextTokens))
    return InferencePlanner.applyCapabilities(capabilities ?? .full, to: plan)
  }

  /// Whether engine-level settings changed (needs full `load`, not just reseed).
  /// Compared with the plan the engine was built for (before fallbacks), so a
  /// text-only fallback doesn't force a reload on every change.
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
  /// (``DeviceProfile/keepsConversationAcrossHelpers(usedTokens:availableBytes:)``). If not,
  /// it's released first, so the runtime doesn't copy its KV cache aside.
  private func beginHelper() -> Bool {
    lastHelperKeptConversation = false
    helperActive = true
    cancelRequested = false
    let keep =
      conversation != nil
      && DeviceProfile.keepsConversationAcrossHelpers(
        usedTokens: usedTokens(), availableBytes: MemoryProbe.availableBytes(),
        exportWindow: ContextBudget.exportWindow(reported: capabilities?.maxContextTokens))
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
    if !GPUGate.isOpen {
      // Never trigger a Metal KV-restore blit or session setup while backgrounded: leave the
      // main conversation untouched (kept or nil) and mark it for reseed on foreground return.
      lastHelperKeptConversation = false
      return
    }
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
    samplingSeed = nil
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
      Log.engine.error("helper: couldn't restore a conversation: \(LogText.errorKind(error), privacy: .public)")
    }
    // A failed helper reports the conversation as not kept, so the caller reseeds.
    lastHelperKeptConversation = false
  }

  /// Whether JSON helpers keep speculative decoding (PERFORMANCE.md, B4). Our runtime's grammar
  /// states stopped sharing one matcher across a speculative round in fork `1382157b` (shipped
  /// since `agello-one-20261122`), so JSON helpers speculate by default; set `AGELLO_JSON_MTP=0`
  /// to turn it off for debugging.
  #if DEBUG || BENCH
    nonisolated static let jsonHelpersSpeculate =
      ProcessInfo.processInfo.environment["AGELLO_JSON_MTP"] != "0"
  #else
    nonisolated static let jsonHelpersSpeculate = true
  #endif

  func helperJSON(prompt: String, schemaJSON: String, maxOutputTokens: Int) async throws -> Data {
    guard let engine, let resolved, let options else { throw ChatError.engineNotReady }
    guard GPUGate.isOpen else { throw GPUGate.closedError }
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
      // Speculative decoding (MTP) broke grammar-constrained decoding: the
      // runtime's grammar states shared one matcher across a round (garbled
      // output or "compute_mask() called after stop"), so helpers decode
      // plainly unless the runtime has the fix (``jsonHelpersSpeculate``).
      let helper = try await engine.createConversation(
        with: ConversationConfig(
          enableResponseFormat: true,
          enableSpeculativeDecoding: Self.jsonHelpersSpeculate ? resolved.enableSpeculativeDecoding : false))
      helperConversation = helper
      try checkHelperNotCancelled()
      guard GPUGate.isOpen else { throw GPUGate.closedError }
      let reply = try await helper.sendMessage(
        LiteRTLM.Message(PromptText.neutralized(prompt)), maxOutputTokens: maxOutputTokens,
        responseFormat: try .json(schema: schemaJSON))
      output = reply.toString
    } catch {
      await endHelperAfterFailure(keep: keep, engine: engine, resolved: resolved, options: options)
      throw error
    }
    try await endHelper(keep: keep, engine: engine, resolved: resolved, options: options)
    Log.engine.info(
      "helper: \(output.utf8.count) bytes in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s, kept \(keep)")
    ReplyTrace.mark(
      "helper",
      ["helperSeconds": .double(Date().timeIntervalSince(started)), "output": .string(String(output.prefix(600))), "kept": .bool(keep)])
    return Data(output.utf8)
  }

  func helperTexts(
    _ prompts: [String], maxOutputTokens: Int, progress: @Sendable (Int) async -> Void
  ) async throws -> [String] {
    guard let engine, let resolved, let options else { throw ChatError.engineNotReady }
    guard GPUGate.isOpen else { throw GPUGate.closedError }
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
        guard GPUGate.isOpen else { throw GPUGate.closedError }
        // No grammar here, so speculative decoding stays on for speed.
        helperConversation = nil
        let helper = try await engine.createConversation(
          with: ConversationConfig(enableSpeculativeDecoding: resolved.enableSpeculativeDecoding))
        helperConversation = helper
        if Task.isCancelled || cancelRequested { break }
        guard GPUGate.isOpen else { throw GPUGate.closedError }
        let reply = try await helper.sendMessage(
          LiteRTLM.Message(PromptText.neutralized(prompt)), maxOutputTokens: maxOutputTokens)
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
    ReplyTrace.mark(
      "helper texts",
      [
        "helperSeconds": .double(Date().timeIntervalSince(started)), "count": .int(outputs.count),
        "output": .string(String((outputs.first ?? "").prefix(200))), "kept": .bool(keep),
      ])
    return outputs
  }

  func transcribe(audioFileURL: URL) async throws -> String {
    guard let engine, let resolved, let options else { throw ChatError.engineNotReady }
    guard GPUGate.isOpen else { throw GPUGate.closedError }
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
      guard GPUGate.isOpen else { throw GPUGate.closedError }
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

  private static func generationStats(
    started: Date, firstChunkAt: Date?, telemetryBefore: TelemetryTotals?,
    backend: String, modelID: ModelID
  ) -> GenerationStats {
    if let telemetryBefore, let after = RuntimeTelemetry.totals(),
      let reply = ReplyTelemetry(before: telemetryBefore, after: after)
    {
      return GenerationStats(
        timeToFirstToken: firstChunkAt?.timeIntervalSince(started),
        totalTime: Date().timeIntervalSince(started),
        inputTokens: reply.inputTokens,
        outputTokens: reply.outputTokens,
        decodeTokensPerSecond: reply.decodeTokensPerSecond,
        backend: backend,
        modelID: modelID
      )
    }
    return GenerationStats(
      timeToFirstToken: firstChunkAt?.timeIntervalSince(started),
      totalTime: Date().timeIntervalSince(started),
      inputTokens: nil,
      outputTokens: nil,
      decodeTokensPerSecond: nil,
      backend: backend,
      modelID: modelID
    )
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

    // Gemma 4's canonical multimodal order places image tokens before the
    // user's text prompt so causal attention attends to visual context first.
    var contents: [Content] = []
    if let imageData { contents.append(.imageData(imageData)) }
    contents.append(.text(Self.promptText(text, imageData, audioFileURL)))
    if let audioFileURL { contents.append(.audioFile(audioFileURL.path)) }
    let message = LiteRTLM.Message(contents: contents)

    // Hard guarantee against KV-cache overflow (which corrupts the native
    // heap): everything this turn adds must fit the room left. Tool rounds run
    // inside LiteRT-LM (each = a tool result + another generation), so with
    // tools the room is split between rounds and results (ToolBudget.plan).
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
    guard GPUGate.isOpen else {
      continuation.finish(throwing: GPUGate.closedError)
      return
    }
    // `web_search` is registered on its own (automatic web search) even when
    // the on-device tools are off, so it needs the same split. With Think the
    // first round's reasoning budget leaves its answer room.
    let budget = ToolBudget.plan(
      room: room, toolsOffered: toolsEnabled || options?.webSearchTool == true,
      thinkingBudget: resolved.thinkingBudget, maxOutputTokens: resolved.maxOutputTokens)
    ToolBudget.begin(budget.limits)
    defer { ToolBudget.end() }
    ReplyTrace.mark(
      "engine send",
      [
        "window": .int(resolved.maxNumTokens), "afterPrefill": .int(prefilled), "room": .int(room),
        "outputCap": .int(budget.outputCap), "followUpCap": .int(budget.followUpCap),
        "thinkingBudget": .int(budget.thinkingBudget ?? 0), "toolCalls": .int(budget.limits.maxCalls),
      ])
    // Safety net for tool rounds (results are trimmed by estimate): stop before streamed output
    // and tool results could exceed the room. Without tools the runtime's cap is exact.
    let guardsToolRounds = budget.limits.maxCalls > 0
    var emittedBytes = 0
    var emittedWeight = 0

    let started = Date()
    var firstChunkAt: Date?
    var streamedChunks = 0
    // The runtime's totals before the reply; its stats are the difference (RuntimeTelemetry).
    let telemetryBefore = RuntimeTelemetry.totals()
    // Instruments (Points of Interest): the reply as an interval, its first token as an event.
    let signpostID = Self.signposter.makeSignpostID()
    let replyInterval = Self.signposter.beginInterval("Reply", id: signpostID)
    defer { Self.signposter.endInterval("Reply", replyInterval) }
    // Tool calls run inside LiteRT-LM and never appear in streamed chunks;
    // report the tools that actually ran (status line, chips, parts).
    var toolCursor = ToolActivity.cursor
    var reportedTools = 0
    func newToolActivity() -> [ToolActivityRecord] {
      let current = ToolActivity.cursor
      guard current > toolCursor else { return [] }
      let records = ToolActivity.records(since: toolCursor)
      toolCursor += records.count
      reportedTools += records.count
      return records
    }
    var cardCursor = ToolCardRecorder.cursor
    func newActionCards() -> [ActionCardRecord] {
      let current = ToolCardRecorder.cursor
      guard current > cardCursor else { return [] }
      let cards = ToolCardRecorder.records(since: cardCursor)
      cardCursor = max(current, cardCursor + cards.count)
      return cards
    }

    do {
      // Rounds after a tool response get their own output and reasoning caps so Think can never
      // consume 100% of `followUpCap` and leave zero visible answer tokens; at most one more round
      // than the reply's tool calls (the last answers "limit reached"), then the stream ends.
      let stream = conversation.sendMessageStream(
        message, maxOutputTokens: budget.outputCap,
        thinkingConfig: budget.thinkingBudget.map {
          ThinkingConfig(enableThinking: true, thinkingTokenBudget: $0)
        },
        followUpMaxOutputTokens: budget.followUpCap,
        followUpThinkingConfig: budget.followUpThinkingBudget.map {
          ThinkingConfig(enableThinking: true, thinkingTokenBudget: $0)
        },
        maxToolRounds: budget.limits.maxCalls + 1)
      for try await chunk in stream {
        if Task.isCancelled {
          try? conversation.cancel()
          continuation.finish(throwing: ChatError.generationCancelled)
          return
        }
        if firstChunkAt == nil {
          firstChunkAt = Date()
          Self.signposter.emitEvent("First token", id: signpostID)
          ReplyTrace.markOnce("first token")
        }
        streamedChunks += 1
        if streamedChunks.isMultiple(of: 100) { ReplyTrace.progress(chunks: streamedChunks) }
        if chunkLog != nil {
          chunkLog?.append(
            "text=\(chunk.toString.debugDescription) channels=\(chunk.channels.sorted { $0.key < $1.key }) "
              + "toolCalls=\(chunk.toolCalls.map(\.name))")
        }
        let thought = chunk.channels["thought"]
        if guardsToolRounds {
          for piece in [chunk.toString, thought ?? ""] {
            emittedBytes += piece.utf8.count
            emittedWeight += Chunker.weight(of: piece)
          }
        }
        let activity = newToolActivity()
        let cards = newActionCards()
        let toolNames =
          chunk.toolCalls.isEmpty && activity.isEmpty
          ? [] : chunk.toolCalls.map(\.name) + activity.map(\.name)
        continuation.yield(
          .chunk(
            ChatChunk(
              textDelta: chunk.toString,
              thoughtDelta: thought,
              toolNames: toolNames,
              toolActivity: activity,
              actionCards: cards
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
      let lateCards = newActionCards()
      if !lateActivity.isEmpty || !lateCards.isEmpty {
        continuation.yield(
          .chunk(
            ChatChunk(
              textDelta: "", thoughtDelta: nil, toolNames: lateActivity.map(\.name),
              toolActivity: lateActivity, actionCards: lateCards)))
      }
      if cancelRequested {
        Log.generation.info("cancelled (user)")
        continuation.finish(throwing: ChatError.generationCancelled)
        return
      }
      var final = Self.generationStats(
        started: started, firstChunkAt: firstChunkAt, telemetryBefore: telemetryBefore,
        backend: resolved.backendLabel, modelID: spec.id)
      // The last round's decode count reached its cap (a later round's when a tool ran).
      let lastCap = reportedTools > 0 ? budget.followUpCap : budget.outputCap
      if let decoded = final.outputTokens, decoded >= lastCap { final.reachedLimit = true }
      Log.generation.info(
        "finished: \(final.footerLine, privacy: .public), out=\(final.outputTokens ?? -1) cap=\(budget.outputCap)/\(budget.followUpCap) think=\(budget.thinkingBudget ?? 0) kv=\(self.usedTokens())/\(resolved.maxNumTokens)"
      )
      ReplyTrace.mark(
        "engine finished",
        [
          "outputTokens": .int(final.outputTokens ?? -1), "lastCap": .int(lastCap), "tools": .int(reportedTools),
          "kvUsed": .int(self.usedTokens()),
        ])
      continuation.yield(.finished(final))
      continuation.finish()
    } catch {
      if cancelRequested || Task.isCancelled || error is CancellationError {
        Log.generation.info("cancelled: \(LogText.errorKind(error), privacy: .public)")
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
      Log.generation.error("stream error: \(LogText.errorKind(error), privacy: .public)")
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
    if let probe = loadingConversation {
      try? probe.cancel()
    }
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

  func cancelAndDrain() async {
    let target: Conversation? =
      loadingConversation ?? (helperActive ? helperConversation : conversation)
    await cancel()
    guard let target else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global(qos: .userInitiated).async {
        _ = try? target.waitUntilDone()
        continuation.resume()
      }
    }
  }
}
