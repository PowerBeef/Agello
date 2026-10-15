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
  /// Human-readable trace of the most recent `load`: capabilities and every
  /// attempt on the backend ladder with its outcome (read by the device harness).
  private(set) var loadLog: [String] = []
  /// Estimated tokens the conversation will prefill before its first send
  /// (preamble + replayed history). `getTokenCount()` reads 0 until then.
  private var pendingSeedTokens = ContextBudget.preambleTokens
  /// Preamble of the current conversation (its system prompt included).
  private var preambleTokens: Int {
    ContextBudget.preambleTokens(systemPrompt: options?.systemPrompt ?? "")
  }
  /// Multiplier learned from the runtime's exact prefill counts, so byte
  /// estimates track how this model actually tokenizes (never below 1).
  private(set) var estimateCalibration = 1.0

  var isLoaded: Bool { engine != nil && conversation != nil }

  /// Tokens the live conversation holds in the KV cache, as the runtime
  /// counts them (0 until the first send; device tests).
  func cachedTokenCount() -> Int { (try? conversation?.getTokenCount()) ?? 0 }

  /// Tokens currently held by the KV cache (measured once anything was sent).
  private func usedTokens() -> Int {
    let measured = (try? conversation?.getTokenCount()) ?? 0
    return measured > 0 ? measured : pendingSeedTokens
  }

  private func estimateInput(text: String, imageData: Data?, audioFileURL: URL?) -> Int {
    let imageTokens = imageData == nil ? nil : Int(resolved?.visualTokenBudget ?? 280)
    let audioSeconds = audioFileURL.map(Self.audioDuration)
    return ContextBudget.estimateInput(
      text: text, imageTokens: imageTokens, audioSeconds: audioSeconds,
      calibration: estimateCalibration)
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

    unloadLocked()
    var plan = InferencePlanner.resolve(options: options, model: spec.id, memoryBytes: memoryBytes)

    // Introspect the model file (cheap, no engine needed) and intersect the
    // plan with real capabilities: MTP support, thinking, modalities, and
    // the model's context / visual-token limits.
    loadLog = []
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
          self.pendingSeedTokens = ContextBudget.preambleTokens(systemPrompt: options.systemPrompt)
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
    unloadLocked()
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
    conversation = try await Self.makeConversation(
      engine: engine, resolved: resolved, options: options, toolsEnabled: toolsEnabled,
      history: history
    )
    pendingSeedTokens =
      preambleTokens
      + ContextBudget.estimateHistory(
        Array(history.suffix(Self.maxReplayedTurns)), calibration: estimateCalibration)
  }

  /// Learn how this model tokenizes from an exact KV-cache delta: grow the
  /// multiplier immediately when estimates ran low, relax it slowly.
  private func calibrate(text: String, measuredBefore: Int, outputTokens: Int?) {
    // Short prompts are dominated by fixed template tokens (turn markers),
    // which would inflate the per-byte ratio and over-trim history.
    guard text.utf8.count >= Self.minCalibrationBytes, let outputTokens,
      let measuredAfter = try? conversation?.getTokenCount()
    else { return }
    let actualInput = measuredAfter - measuredBefore - outputTokens
    let raw = ContextBudget.estimateTokens(text)
    guard actualInput > 0, raw > 0 else { return }
    let ratio = Double(actualInput) / Double(raw)
    let next = ratio > estimateCalibration ? ratio : 0.8 * estimateCalibration + 0.2 * ratio
    estimateCalibration = min(3, max(1, next))
    Log.engine.info(
      "calibration: actual=\(actualInput) raw≈\(raw) ratio=\(ratio) → \(self.estimateCalibration)")
  }

  static let minCalibrationBytes = 400

  /// Upper bound on replayed turns (see ``makeConversation``).
  static let maxReplayedTurns = 20

  // MARK: Context window

  func fitContext(
    text: String, imageData: Data?, audioFileURL: URL?,
    history: [(role: ChatRole, text: String)]
  ) async throws -> Bool {
    guard conversation != nil, let resolved else { throw ChatError.engineNotReady }
    let input = estimateInput(text: text, imageData: imageData, audioFileURL: audioFileURL)
    let window = resolved.maxNumTokens
    guard
      ContextBudget.fits(
        used: preambleTokens, input: input, maxNumTokens: window,
        thinkingBudget: resolved.thinkingBudget)
    else {
      throw ChatError.messageTooLong
    }
    let used = usedTokens()
    if ContextBudget.fits(
      used: used, input: input, maxNumTokens: window, thinkingBudget: resolved.thinkingBudget)
    {
      return false
    }
    let budget = ContextBudget.historyBudget(
      maxNumTokens: window, input: input, thinkingBudget: resolved.thinkingBudget,
      preamble: preambleTokens)
    let trimmed = ContextBudget.trimmedHistory(
      history, budget: budget, calibration: estimateCalibration)
    Log.engine.info(
      "context: used=\(used) input≈\(input) window=\(window) budget=\(budget) calibration=\(self.estimateCalibration); replaying \(trimmed.count)/\(history.count) turns"
    )
    try await reseed(history: trimmed)
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
    let keep =
      conversation != nil
      && DeviceProfile.keepsConversationAcrossHelpers(
        runtimeKeepsSessions: EngineCache.runtimeBuildID != nil,
        maxNumTokens: resolved?.maxNumTokens ?? 0, availableBytes: MemoryProbe.availableBytes())
    if !keep { conversation = nil }
    return keep
  }

  /// After a helper: the main conversation as it was, or an empty one.
  private func endHelper(
    keep: Bool, engine: Engine, resolved: ResolvedInference, options: InferenceOptions
  ) async throws {
    helperConversation = nil
    lastHelperKeptConversation = keep
    guard !keep else { return }
    conversation = try await Self.makeConversation(
      engine: engine, resolved: resolved, options: options, toolsEnabled: toolsEnabled,
      history: [])
    pendingSeedTokens = preambleTokens
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
      let reply = try await helper.sendMessage(
        LiteRTLM.Message(prompt), maxOutputTokens: maxOutputTokens,
        responseFormat: try .json(schema: schemaJSON))
      output = reply.toString
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
    for prompt in prompts {
      if Task.isCancelled { break }
      // No grammar here, so speculative decoding stays on for speed.
      helperConversation = nil
      let helper = try await engine.createConversation(
        with: ConversationConfig(enableSpeculativeDecoding: resolved.enableSpeculativeDecoding))
      helperConversation = helper
      let reply = try await helper.sendMessage(
        LiteRTLM.Message(prompt), maxOutputTokens: maxOutputTokens)
      outputs.append(reply.toString.trimmingCharacters(in: .whitespacesAndNewlines))
      await progress(outputs.count)
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
    let helper = try await engine.createConversation(
      with: ConversationConfig(
        samplerConfig: try SamplerConfig(topK: 1, topP: 1, temperature: 0),
        enableSpeculativeDecoding: resolved.enableSpeculativeDecoding))
    helperConversation = helper
    let reply = try await helper.sendMessage(
      LiteRTLM.Message(contents: [
        .text(Dictation.instruction), .audioFile(audioFileURL.path),
      ]), maxOutputTokens: Dictation.maxOutputTokens)
    try await endHelper(keep: keep, engine: engine, resolved: resolved, options: options)
    Log.engine.info(
      "transcribe: \(reply.toString.count) chars in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s, kept \(keep)")
    return Dictation.clean(reply.toString)
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
    generating = true
    cancelRequested = false
    defer { generating = false }

    var contents: [Content] = []
    if imageData != nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      contents.append(.text("Describe this image in detail."))
    } else if !text.isEmpty {
      contents.append(.text(text))
    } else if audioFileURL != nil {
      contents.append(.text("Listen to this voice message and respond to it."))
    } else {
      contents.append(.text("Hello!"))
    }
    if let imageData { contents.append(.imageData(imageData)) }
    if let audioFileURL { contents.append(.audioFile(audioFileURL.path)) }
    let message = LiteRTLM.Message(contents: contents)

    // Hard guarantee against KV-cache overflow (which corrupts the native
    // heap): everything this turn adds must fit the room left. Tool rounds run
    // inside LiteRT-LM (each = a tool result + another generation under the
    // same cap), so with tools the room is split: a quarter per generation,
    // an eighth per tool result, at most two tool calls (3/4 + 2/8 = 1).
    let measuredBefore = (try? conversation.getTokenCount()) ?? 0
    let usedBefore = usedTokens()
    let inputEstimate = estimateInput(
      text: text, imageData: imageData, audioFileURL: audioFileURL)
    guard
      let room = ContextBudget.outputCap(
        maxNumTokens: resolved.maxNumTokens, used: usedBefore, input: inputEstimate)
    else {
      Log.generation.error(
        "context full: used=\(usedBefore) input≈\(inputEstimate) window=\(resolved.maxNumTokens)")
      continuation.finish(throwing: ChatError.contextFull)
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
    // Safety net for what the budgets can't bound (e.g. extra tool rounds):
    // stop before streamed output + tool results could exceed the room.
    let roomBytes = Int(Double(room) * ContextBudget.bytesPerToken)
    var emittedBytes = 0

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
      // Prefer exact runtime measurements; fall back to client-side timing.
      if let info = try? conversation.getBenchmarkInfo() {
        return GenerationStats(
          timeToFirstToken: info.timeToFirstTokenInSecond > 0
            ? info.timeToFirstTokenInSecond : firstChunkAt?.timeIntervalSince(started),
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
      let stream = conversation.sendMessageStream(message, maxOutputTokens: maxOutputTokens)
      for try await chunk in stream {
        if Task.isCancelled {
          try? conversation.cancel()
          continuation.finish(throwing: ChatError.generationCancelled)
          return
        }
        if firstChunkAt == nil { firstChunkAt = Date() }
        let thought = chunk.channels["thought"]
        emittedBytes += chunk.toString.utf8.count + (thought?.utf8.count ?? 0)
        let activity = newToolActivity()
        continuation.yield(
          .chunk(
            ChatChunk(
              textDelta: chunk.toString,
              thoughtDelta: thought,
              toolNames: chunk.toolCalls.map(\.name) + activity.map(\.name),
              toolActivity: activity
            )))
        if emittedBytes + ToolBudget.resultBytes > roomBytes {
          Log.generation.error(
            "context guard: stopping at \(emittedBytes)+\(ToolBudget.resultBytes) bytes of \(roomBytes)")
          try? conversation.cancel()
          continuation.finish(throwing: ChatError.replyTruncated)
          return
        }
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
      if imageData == nil, audioFileURL == nil, measuredBefore > 0 {
        calibrate(text: text, measuredBefore: measuredBefore, outputTokens: final.outputTokens)
      }
      Log.generation.info(
        "finished: \(final.footerLine, privacy: .public), out=\(final.outputTokens ?? -1) cap=\(maxOutputTokens) kv=\(self.usedTokens())/\(resolved.maxNumTokens)"
      )
      continuation.yield(.finished(final))
      continuation.finish()
    } catch is CancellationError {
      Log.generation.info("cancelled (task)")
      try? conversation.cancel()
      continuation.finish(throwing: ChatError.generationCancelled)
    } catch {
      if cancelRequested {
        Log.generation.info("cancelled (user): \(String(describing: error), privacy: .public)")
        continuation.finish(throwing: ChatError.generationCancelled)
        return
      }
      Log.generation.error("stream error: \(String(describing: error), privacy: .public)")
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
    try? (helperConversation ?? conversation)?.cancel()
  }
}

// MARK: - Mock engine (previews, simulator UI smoke tests)

/// Deterministic scripted engine. No model required.
actor MockChatEngine: ChatEngineProtocol {
  var script: [ChatChunk]
  var stats: GenerationStats
  private(set) var loadedModel: ModelID?
  var loadResult: ResolvedInference
  /// Test instrumentation: how often `load` ran and every reseeded history.
  private(set) var loadCount = 0
  private(set) var reseedLog: [[String]] = []
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
    return try fitResult.get()
  }

  nonisolated func send(
    text: String, imageData: Data?, audioFileURL: URL?
  ) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      Task {
        let script =
          text.localizedCaseInsensitiveContains("markdown")
          ? MockChatEngine.markdownSample : await self.script
        // Like the real model: reasoning only streams when thinking is on.
        let thinking = await self.thinkingEnabled
        let stats = await self.stats
        await self.recordSend(text)
        await self.setGenerating(true)
        for chunk in script {
          try? await Task.sleep(for: .milliseconds(60))
          let stopRequested = await self.cancelRequested
          if Task.isCancelled || stopRequested {
            await self.setGenerating(false)
            continuation.finish(throwing: ChatError.generationCancelled)
            return
          }
          var chunk = chunk
          if !thinking { chunk.thoughtDelta = nil }
          continuation.yield(.chunk(chunk))
        }
        await self.setGenerating(false)
        continuation.yield(.finished(stats))
        continuation.finish()
      }
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
  private func recordSend(_ text: String) { sendLog.append(text) }

  private func setGenerating(_ value: Bool) {
    generating = value
    if value { cancelRequested = false }
  }

  func cancel() async {
    if generating { cancelRequested = true }
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
    helperPrompts.append(prompt)
    lastHelperKeptConversation = helpersKeepConversation
    return helperResponse
  }

  /// Test instrumentation: recordings transcribed.
  private(set) var transcribed: [URL] = []
  var transcript = "Dictated text."
  func setTranscript(_ text: String) { transcript = text }

  func transcribe(audioFileURL: URL) async throws -> String {
    transcribed.append(audioFileURL)
    lastHelperKeptConversation = helpersKeepConversation
    return transcript
  }

  /// Test instrumentation: every plain-text helper prompt.
  private(set) var helperTextPrompts: [String] = []

  func helperTexts(
    _ prompts: [String], maxOutputTokens: Int, progress: @Sendable (Int) async -> Void
  ) async throws -> [String] {
    var outputs: [String] = []
    for prompt in prompts {
      helperTextPrompts.append(prompt)
      outputs.append("- Key point \(outputs.count + 1) of this part.")
      await progress(outputs.count)
    }
    lastHelperKeptConversation = helpersKeepConversation
    return outputs
  }
}
