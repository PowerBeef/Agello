import AVFoundation
import Foundation
import LiteRTLMTools

/// `ChatEngineProtocol` actor for `AgelloSim` (iOS Simulator).
/// Streams real Gemma 4 E4B Metal 4 replies from `agello serve` (`127.0.0.1`) while executing
/// all 21 real Swift tools and `ToolConfirmationGate` natively inside the iOS Simulator.
actor RemoteChatEngine: ChatEngineProtocol {
  nonisolated let requiresLocalModelFile = false
  nonisolated let engineDisplayName = "Agello Serve (127.0.0.1)"

  fileprivate let baseURL: URL
  fileprivate var serverModelID = "google/gemma-4-E4B-it"
  fileprivate var serverKV = 65_536
  fileprivate var loadedModel: ModelID?
  fileprivate var resolved: ResolvedInference?
  fileprivate var options = InferenceOptions()
  fileprivate var toolsEnabled = true
  fileprivate var stopStrings: [String] = []
  fileprivate var history: [(role: ChatRole, text: String)] = []
  fileprivate var sessionMessages: [[String: Any]] = []
  fileprivate var samplingSeed: Int?
  fileprivate var generating = false, helperActive = false, cancelRequested = false
  fileprivate var activeTask: Task<Void, Never>?
  fileprivate var activeHelperTask: Task<String, Error>?

  private(set) var lastHelperKeptConversation = false
  private(set) var lastEvictedHistory: [(role: ChatRole, text: String)] = []
  var maxVisionTokenBudget: Int? { 280 }

  init(baseURL: URL = RemoteChatClient.resolveBaseURL()) { self.baseURL = baseURL }

  var isLoaded: Bool { loadedModel != nil && resolved != nil }
  var currentModelID: ModelID? { loadedModel }

  func setStopStrings(_ stops: [String]) { stopStrings = stops.filter { !$0.isEmpty } }

  func load(
    spec: ModelSpec, modelURL: URL, options: InferenceOptions, memoryBytes: UInt64,
    enableTools: Bool
  ) async throws -> ResolvedInference {
    let health = try await RemoteChatClient.checkHealth(baseURL: baseURL)
    serverModelID = health.modelID
    serverKV = health.kvTokens
    loadedModel = spec.id
    self.options = options
    self.toolsEnabled = enableTools
    history = []
    sessionMessages = []
    samplingSeed = nil
    let plan = InferencePlanner.resolve(
      options: options, model: spec.id, memoryBytes: memoryBytes,
      contextTokens: serverKV, exportWindow: serverKV)
    resolved = plan
    return plan
  }

  func unload() async {
    await cancelAndDrain()
    loadedModel = nil
    resolved = nil
    resetConversationBuffer(history: [], seed: nil)
    await RemoteChatClient.resetSession(baseURL: baseURL)
  }

  func updateConversationOptions(
    _ newOptions: InferenceOptions, enableTools: Bool, history: [(role: ChatRole, text: String)]
  ) async throws -> ResolvedInference {
    options = newOptions
    toolsEnabled = enableTools
    resetConversationBuffer(history: history, seed: nil)
    let plan = InferencePlanner.resolve(
      options: newOptions, model: loadedModel ?? .e4b,
      memoryBytes: DeviceProfile.current.physicalMemoryBytes,
      contextTokens: serverKV, exportWindow: serverKV)
    resolved = plan
    return plan
  }

  func reseed(history: [(role: ChatRole, text: String)]) async throws {
    resetConversationBuffer(history: history, seed: nil)
  }

  func reseedSampling(history: [(role: ChatRole, text: String)], seed: Int) async throws {
    resetConversationBuffer(history: history, seed: seed)
  }

  private func resetConversationBuffer(history: [(role: ChatRole, text: String)], seed: Int?) {
    self.history = history
    sessionMessages = []
    samplingSeed = seed
  }

  func countTokens(_ text: String) async -> Int {
    await RemoteChatClient.tokenizeText(baseURL: baseURL, text: text) ?? ContextBudget.estimateTextTokens(text)
  }

  func fitContext(
    text: String, imageData: Data?, audioFileURL: URL?, history: [(role: ChatRole, text: String)]
  ) async throws -> Bool {
    guard let resolved else { throw ChatError.engineNotReady }
    lastEvictedHistory = []
    let window = resolved.maxNumTokens, thinking = resolved.thinkingBudget
    func fits(_ total: Int) -> Bool {
      ContextBudget.fits(used: total, input: 0, maxNumTokens: window, thinkingBudget: thinking)
    }
    let used = await tokensAfterPrefill(
      text: text, imageData: imageData, audioFileURL: audioFileURL,
      history: self.history, useSessionMessages: !sessionMessages.isEmpty)
    if fits(used) { return false }

    sessionMessages = []
    let alone = await tokensAfterPrefill(
      text: text, imageData: imageData, audioFileURL: audioFileURL, history: [], useSessionMessages: false)
    guard fits(alone) else {
      self.history = []
      throw ChatError.messageTooLong
    }
    var budget = ContextBudget.historyBudget(maxNumTokens: window, input: alone, thinkingBudget: thinking, preamble: 0)
    var turnTokens: [Int] = []
    turnTokens.reserveCapacity(history.count)
    for turn in history { turnTokens.append(await countTokens(PromptText.neutralized(turn.text))) }

    var trimmed: [(role: ChatRole, text: String)] = [], evicted = history
    for _ in 0..<4 {
      let split = ContextBudget.trimHistory(history, budget: budget, tokens: turnTokens)
      trimmed = split.kept
      evicted = split.evicted
      if trimmed.isEmpty { break }
      let total = await tokensAfterPrefill(
        text: text, imageData: imageData, audioFileURL: audioFileURL, history: trimmed, useSessionMessages: false)
      if fits(total) { break }
      let over = total + ContextBudget.replyReserve(maxNumTokens: window, thinkingBudget: thinking)
        + ContextBudget.safetyMargin - window
      budget -= max(over, ContextBudget.perTurnOverhead)
      trimmed = []
      evicted = history
    }
    self.history = trimmed
    lastEvictedHistory = evicted
    return true
  }

  nonisolated func send(text: String, imageData: Data?, audioFileURL: URL?) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        await self.runSend(text: text, imageData: imageData, audioFileURL: audioFileURL, continuation: continuation)
      }
      Task { await self.setActiveTask(task) }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  fileprivate func setActiveTask(_ task: Task<Void, Never>?) { activeTask = task }

  func cancel() async {
    guard generating else { return }
    cancelRequested = true
    if helperActive { activeHelperTask?.cancel() } else { activeTask?.cancel() }
  }

  func cancelAndDrain() async {
    let helperTask = helperActive ? activeHelperTask : nil
    let sendTask = helperActive ? nil : activeTask
    await cancel()
    _ = try? await helperTask?.value
    await sendTask?.value
  }

  func helperJSON(prompt: String, schemaJSON: String, maxOutputTokens: Int) async throws -> Data {
    guard isLoaded else { throw ChatError.engineNotReady }
    guard GPUGate.isOpen else { throw GPUGate.closedError }
    guard !generating else { throw ChatError.underlying(message: "Busy generating.") }
    beginHelperState()
    defer { endHelperState() }
    var payload = makeHelperPayload(content: PromptText.neutralized(prompt), maxTokens: maxOutputTokens)
    if let schemaData = schemaJSON.data(using: .utf8),
      let schemaObj = try? JSONSerialization.jsonObject(with: schemaData)
    {
      payload["response_format"] = [
        "type": "json_schema", "json_schema": ["name": "helper", "schema": schemaObj],
      ]
    }
    let text = try await runHelperRequest(payload: payload)
    lastHelperKeptConversation = GPUGate.isOpen
    return Data(text.utf8)
  }

  func helperTexts(
    _ prompts: [String], maxOutputTokens: Int, progress: @Sendable (Int) async -> Void
  ) async throws -> [String] {
    guard isLoaded else { throw ChatError.engineNotReady }
    guard GPUGate.isOpen else { throw GPUGate.closedError }
    guard !generating else { throw ChatError.underlying(message: "Busy generating.") }
    beginHelperState()
    defer { endHelperState() }
    var outputs: [String] = []
    for prompt in prompts {
      if Task.isCancelled || cancelRequested { break }
      guard GPUGate.isOpen else { throw GPUGate.closedError }
      let payload = makeHelperPayload(content: PromptText.neutralized(prompt), maxTokens: maxOutputTokens)
      do {
        let reply = try await runHelperRequest(payload: payload)
        outputs.append(reply.trimmingCharacters(in: .whitespacesAndNewlines))
        await progress(outputs.count)
      } catch ChatError.generationCancelled { break }
    }
    lastHelperKeptConversation = GPUGate.isOpen && !cancelRequested && !Task.isCancelled
    return outputs
  }

  func transcribe(audioFileURL: URL) async throws -> String {
    guard let resolved, isLoaded else { throw ChatError.engineNotReady }
    guard GPUGate.isOpen else { throw GPUGate.closedError }
    guard resolved.enableAudio else {
      throw ChatError.underlying(message: "Audio input is off in this session.")
    }
    guard !generating else { throw ChatError.underlying(message: "Busy generating.") }
    beginHelperState()
    defer { endHelperState() }
    let audioBytes = try Data(contentsOf: audioFileURL)
    let content: [[String: Any]] = [
      ["type": "text", "text": Dictation.instruction],
      ["type": "input_audio", "input_audio": ["data": audioBytes.base64EncodedString(), "format": "wav"]],
    ]
    let text = try await runHelperRequest(
      payload: makeHelperPayload(content: content, maxTokens: Dictation.maxOutputTokens))
    lastHelperKeptConversation = GPUGate.isOpen
    return Dictation.clean(text)
  }

  fileprivate func setLastHelperKept(_ kept: Bool) { lastHelperKeptConversation = kept }
}

// MARK: - Streaming rounds & token fitting

extension RemoteChatEngine {
  fileprivate struct RoundLoopSummary {
    var messages: [[String: Any]]
    var totalInput = 0, totalOutput = 0
    var finalReplyText = "", lastRoundAssistantText = ""
    var replyTruncated = false
  }

  fileprivate func beginHelperState() {
    generating = true
    helperActive = true
    cancelRequested = false
    setLastHelperKept(false)
  }

  fileprivate func endHelperState() {
    generating = false
    helperActive = false
    activeHelperTask = nil
  }

  fileprivate func makeHelperPayload(content: Any, maxTokens: Int) -> [String: Any] {
    [
      "model": serverModelID, "messages": [["role": "user", "content": content]],
      "temperature": 0.0, "max_tokens": maxTokens, "stream": false,
      "agello_helper": true, "chat_template_kwargs": ["enable_thinking": false],
    ]
  }

  fileprivate func runHelperRequest(payload: [String: Any]) async throws -> String {
    let body = try JSONSerialization.data(withJSONObject: payload), url = baseURL
    let task = Task<String, Error> { try await RemoteChatClient.completeJSON(baseURL: url, payloadData: body) }
    activeHelperTask = task
    defer { activeHelperTask = nil }
    if cancelRequested || Task.isCancelled {
      task.cancel()
      throw ChatError.generationCancelled
    }
    do {
      let text = try await task.value
      try checkCancelled()
      return text
    } catch {
      let isCancel =
        cancelRequested || Task.isCancelled || error is CancellationError
        || (error as? URLError)?.code == .cancelled
      throw isCancel ? ChatError.generationCancelled : error
    }
  }

  fileprivate func runSend(
    text: String, imageData: Data?, audioFileURL: URL?,
    continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
  ) async {
    guard let resolved, let loadedModel else {
      return continuation.finish(throwing: ChatError.engineNotReady)
    }
    guard !generating else {
      return continuation.finish(throwing: ChatError.underlying(message: "Already generating."))
    }
    guard !Task.isCancelled else { return continuation.finish(throwing: ChatError.generationCancelled) }
    generating = true
    cancelRequested = false
    defer {
      ToolConfirmationGate.clearBatchGrants()
      generating = false
      activeTask = nil
    }
    let prefilled = await tokensAfterPrefill(
      text: text, imageData: imageData, audioFileURL: audioFileURL,
      history: history, useSessionMessages: !sessionMessages.isEmpty)
    guard let room = ContextBudget.outputCap(
      maxNumTokens: resolved.maxNumTokens, used: prefilled, input: 0)
    else {
      sessionMessages = []
      return continuation.finish(throwing: ChatError.contextFull)
    }
    guard !cancelRequested && !Task.isCancelled else {
      return continuation.finish(throwing: ChatError.generationCancelled)
    }
    guard GPUGate.isOpen else { return continuation.finish(throwing: GPUGate.closedError) }

    let tools = ActiveTools.make(toolsEnabled: toolsEnabled, options: options)
    let budget = ToolBudget.plan(
      room: room, toolsOffered: !tools.isEmpty,
      thinkingBudget: resolved.thinkingBudget, maxOutputTokens: resolved.maxOutputTokens)
    ToolBudget.begin(budget.limits)
    defer { ToolBudget.end() }

    let userPrompt = RemoteChatClient.promptText(text, imageData, audioFileURL)
    let initial = buildMessages(
      userText: userPrompt, imageData: imageData, audioFileURL: audioFileURL,
      history: history, useSessionMessages: !sessionMessages.isEmpty)
    let started = Date()
    let tracker = RemoteFirstTokenTracker()

    do {
      let summary = try await runStreamingRounds(
        initialMessages: initial, tools: tools, resolved: resolved,
        budget: (plan: budget, room: room), sink: (tracker: tracker, continuation: continuation))
      if summary.replyTruncated {
        sessionMessages = []
        return continuation.finish(throwing: ChatError.replyTruncated)
      }
      commitCompletedTurn(userPrompt: userPrompt, summary: summary)
      continuation.yield(
        .finished(makeStats(started: started, tracker: tracker, summary: summary, model: loadedModel)))
      continuation.finish()
    } catch is CancellationError {
      sessionMessages = []
      continuation.finish(throwing: ChatError.generationCancelled)
    } catch {
      sessionMessages = []
      let isCancel = cancelRequested || Task.isCancelled || (error as? URLError)?.code == .cancelled
      continuation.finish(throwing: isCancel ? ChatError.generationCancelled : error)
    }
  }

  private func commitCompletedTurn(userPrompt: String, summary: RoundLoopSummary) {
    history.append((role: .user, text: userPrompt))
    history.append((role: .model, text: summary.finalReplyText))
    var updated = summary.messages
    updated.append(["role": "assistant", "content": summary.lastRoundAssistantText])
    sessionMessages = samplingSeed == nil ? updated : []
  }

  private func makeStats(
    started: Date, tracker: RemoteFirstTokenTracker, summary: RoundLoopSummary, model: ModelID
  ) -> GenerationStats {
    let totalTime = max(0.01, Date().timeIntervalSince(started))
    return GenerationStats(
      timeToFirstToken: tracker.elapsed(since: started), totalTime: totalTime,
      inputTokens: summary.totalInput > 0 ? summary.totalInput : nil,
      outputTokens: summary.totalOutput > 0 ? summary.totalOutput : nil,
      decodeTokensPerSecond: summary.totalOutput > 0 ? Double(summary.totalOutput) / totalTime : nil,
      backend: "Metal 4 (Mac Bridge)", modelID: model)
  }

  private func runStreamingRounds(
    initialMessages: [[String: Any]], tools: [any Tool], resolved: ResolvedInference,
    budget: (plan: ToolBudget.Plan, room: Int),
    sink: (tracker: RemoteFirstTokenTracker, continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation)
  ) async throws -> RoundLoopSummary {
    let toolManager = ToolManager(tools: tools)
    let toolSchemas = RemoteChatClient.parseToolSchemas(toolManager.toolsJsonDescription)
    let guardsToolRounds = budget.plan.limits.maxCalls > 0
    let emittedCounter = RemoteEmittedTokenCounter()
    let toolCursor = ToolActivity.cursor, cardCursor = ToolCardRecorder.cursor
    var reportedTools = 0, reportedCards = 0
    var summary = RoundLoopSummary(messages: initialMessages)
    var completedFinalAnswer = false

    func emitNewRecordsIfAny() {
      let allTools = ToolActivity.records(since: toolCursor)
      let newTools = Array(allTools.dropFirst(reportedTools))
      reportedTools = allTools.count
      let allCards = ToolCardRecorder.records(since: cardCursor)
      let newCards = Array(allCards.dropFirst(reportedCards))
      reportedCards = allCards.count
      guard !newTools.isEmpty || !newCards.isEmpty else { return }
      sink.continuation.yield(
        .chunk(
          ChatChunk(
            textDelta: "", thoughtDelta: nil, toolNames: newTools.map(\.name),
            toolActivity: newTools, actionCards: newCards)))
    }

    for round in 0..<(budget.plan.limits.maxCalls + 1) {
      try checkCancelled()
      let roundCap = round == 0 ? budget.plan.outputCap : budget.plan.followUpCap
      let roundThink = round == 0 ? budget.plan.thinkingBudget : budget.plan.followUpThinkingBudget
      let payloadData = try RemoteChatClient.buildStreamPayload(
        modelID: serverModelID, messages: summary.messages, tools: toolSchemas,
        resolved: resolved, params: (
          seed: samplingSeed, maxTokens: roundCap,
          thinkingBudget: roundThink, stopStrings: stopStrings))
      let tracker = sink.tracker, cont = sink.continuation
      let roundResult = try await RemoteChatClient.streamVerifiedCompletion(
        baseURL: baseURL, payloadData: payloadData
      ) { textDelta, thoughtDelta in
        tracker.markIfNeeded()
        if guardsToolRounds { emittedCounter.record(textDelta: textDelta, thoughtDelta: thoughtDelta) }
        cont.yield(.chunk(ChatChunk(textDelta: textDelta, thoughtDelta: thoughtDelta)))
      }
      try checkCancelled()
      summary.totalInput = roundResult.promptTokens ?? summary.totalInput
      summary.totalOutput += roundResult.completionTokens ?? 0
      summary.finalReplyText += roundResult.assistantText
      summary.lastRoundAssistantText = roundResult.assistantText

      if guardsToolRounds, emittedCounter.estimatedTokens + ToolBudget.resultTokens > budget.room {
        summary.replyTruncated = true
        break
      }
      if roundResult.toolCalls.isEmpty {
        completedFinalAnswer = true
        summary.replyTruncated = roundResult.finishReason == "length"
        break
      }
      summary.messages.append(RemoteChatClient.assistantToolCallMessage(roundResult))
      let toolResponses = await RemoteChatClient.executeToolCalls(
        roundResult.toolCalls, using: toolManager)
      emitNewRecordsIfAny()
      summary.messages.append(contentsOf: toolResponses.map(\.dictionary))
    }
    if !completedFinalAnswer { summary.replyTruncated = true }
    emitNewRecordsIfAny()
    return summary
  }

  fileprivate func tokensAfterPrefill(
    text: String, imageData: Data?, audioFileURL: URL?,
    history candidateHistory: [(role: ChatRole, text: String)], useSessionMessages: Bool
  ) async -> Int {
    let tools = ActiveTools.make(toolsEnabled: toolsEnabled, options: options)
    let toolManager = ToolManager(tools: tools)
    let toolSchemas = RemoteChatClient.parseToolSchemas(toolManager.toolsJsonDescription)
    let userPrompt = RemoteChatClient.promptText(text, imageData, audioFileURL)
    let candidateMessages = buildMessages(
      userText: userPrompt, imageData: imageData, audioFileURL: audioFileURL,
      history: candidateHistory, useSessionMessages: useSessionMessages)
    if let tokenizeData = RemoteChatClient.makeTokenizePayloadData(
      messages: candidateMessages, tools: toolSchemas, enableThinking: resolved?.thinkingBudget != nil),
      let exact = await RemoteChatClient.tokenizePayload(baseURL: baseURL, payloadData: tokenizeData)
    {
      return exact
    }
    let toolSchemaTokens = ContextBudget.estimateToolSchemaTokens(toolManager.toolsJsonDescription)
    let preamble = ContextBudget.preambleTokens(
      systemPrompt: options.systemPrompt, toolCount: tools.count, toolSchemaTokens: toolSchemaTokens)
    let media = ContextBudget.mediaTokens(
      imageTokens: imageData == nil ? nil : Int(resolved?.visualTokenBudget ?? 280),
      audioSeconds: audioFileURL.map(Self.audioDuration))
    return preamble + ContextBudget.estimateHistory(candidateHistory)
      + ContextBudget.estimateTokens(userPrompt) + media
  }

  private nonisolated static func audioDuration(_ url: URL) -> Double {
    guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
      return 30
    }
    return Double(file.length) / file.fileFormat.sampleRate
  }

  fileprivate func checkCancelled() throws {
    if cancelRequested || Task.isCancelled { throw ChatError.generationCancelled }
  }

  fileprivate func buildMessages(
    userText: String, imageData: Data?, audioFileURL: URL?,
    history turns: [(role: ChatRole, text: String)], useSessionMessages: Bool
  ) -> [[String: Any]] {
    var msgs =
      useSessionMessages && !sessionMessages.isEmpty
      ? sessionMessages : RemoteChatClient.formatHistory(systemPrompt: options.systemPrompt, turns: turns)
    msgs.append([
      "role": "user",
      "content": RemoteChatClient.buildUserContent(userText, imageData, audioFileURL),
    ])
    return msgs
  }
}
