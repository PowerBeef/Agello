import Foundation
import LiteRTLMTools

/// `ChatEngineProtocol` actor for `AgelloSim` (iOS Simulator).
/// Streams real Gemma 4 E4B Metal 4 replies from `agello serve` (`127.0.0.1`) while executing
/// all 21 real Swift tools (EventKit Calendar/Reminders, Contacts/Messages, MapKit, WeatherKit,
/// AlarmKit, Photos OCR, Shortcuts, WebSearch, Files, Calculator, Units, CSV/JSON) and
/// `ToolConfirmationGate` natively inside the iOS Simulator.
actor RemoteChatEngine: ChatEngineProtocol {
  nonisolated let requiresLocalModelFile = false
  nonisolated let engineDisplayName = "Agello Serve (127.0.0.1)"

  private let baseURL: URL
  private var serverModelID = "google/gemma-4-E4B-it"
  private var serverKV = 65_536
  private var loadedModel: ModelID?
  private var resolved: ResolvedInference?
  private var options = InferenceOptions()
  private var toolsEnabled = true
  private var history: [(role: ChatRole, text: String)] = []
  private var samplingSeed: Int?
  private var generating = false
  private var cancelRequested = false
  private var activeTask: Task<Void, Never>?

  private(set) var lastHelperKeptConversation = true
  private(set) var lastEvictedHistory: [(role: ChatRole, text: String)] = []
  var maxVisionTokenBudget: Int? { 280 }

  init(baseURL: URL = RemoteChatClient.resolveBaseURL()) {
    self.baseURL = baseURL
  }

  var isLoaded: Bool { loadedModel != nil && resolved != nil }
  var currentModelID: ModelID? { loadedModel }

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
    self.history = []
    self.samplingSeed = nil
    let plan = InferencePlanner.resolve(
      options: options, model: spec.id, memoryBytes: memoryBytes,
      contextTokens: serverKV, exportWindow: serverKV)
    resolved = plan
    return plan
  }

  func unload() async {
    await cancel()
    loadedModel = nil
    resolved = nil
    history = []
  }

  func updateConversationOptions(
    _ newOptions: InferenceOptions, enableTools: Bool, history: [(role: ChatRole, text: String)]
  ) async throws -> ResolvedInference {
    self.options = newOptions
    self.toolsEnabled = enableTools
    self.history = history
    self.samplingSeed = nil
    let plan = InferencePlanner.resolve(
      options: newOptions, model: loadedModel ?? .e4b,
      memoryBytes: DeviceProfile.current.physicalMemoryBytes,
      contextTokens: serverKV, exportWindow: serverKV)
    resolved = plan
    return plan
  }

  func reseed(history: [(role: ChatRole, text: String)]) async throws {
    self.history = history
    self.samplingSeed = nil
  }

  func reseedSampling(history: [(role: ChatRole, text: String)], seed: Int) async throws {
    self.history = history
    self.samplingSeed = seed
  }

  func fitContext(
    text: String, imageData: Data?, audioFileURL: URL?,
    history: [(role: ChatRole, text: String)]
  ) async throws -> Bool {
    guard let resolved else { throw ChatError.engineNotReady }
    lastEvictedHistory = []
    let tools = ActiveTools.make(toolsEnabled: toolsEnabled, options: options)
    let toolSchemaTokens = ContextBudget.estimateToolSchemaTokens(
      ToolManager(tools: tools).toolsJsonDescription)
    let preamble = ContextBudget.preambleTokens(
      systemPrompt: options.systemPrompt, toolCount: tools.count,
      toolSchemaTokens: toolSchemaTokens)
    let inputTokens =
      ContextBudget.estimateTextTokens(text)
      + (imageData == nil ? 0 : Int(resolved.visualTokenBudget ?? 280))
      + (audioFileURL == nil ? 0 : 250)
    let budget = ContextBudget.historyBudget(
      maxNumTokens: resolved.maxNumTokens, input: inputTokens,
      thinkingBudget: resolved.thinkingBudget, preamble: preamble)
    guard budget >= 0 else { throw ChatError.messageTooLong }
    let tokens = history.map { ContextBudget.estimateTextTokens($0.text) }
    let split = ContextBudget.trimHistory(history, budget: budget, tokens: tokens)
    self.history = split.kept
    lastEvictedHistory = split.evicted
    return !split.evicted.isEmpty
  }

  nonisolated func send(
    text: String, imageData: Data?, audioFileURL: URL?
  ) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        await self.runSend(
          text: text, imageData: imageData, audioFileURL: audioFileURL, continuation: continuation)
      }
      Task { await self.setActiveTask(task) }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func setActiveTask(_ task: Task<Void, Never>?) {
    activeTask = task
  }

  func cancel() async {
    cancelRequested = true
    activeTask?.cancel()
  }

  func cancelAndDrain() async {
    await cancel()
  }

  // MARK: - Helpers & dictation

  func helperJSON(prompt: String, schemaJSON: String, maxOutputTokens: Int) async throws -> Data {
    guard !generating else { throw ChatError.underlying(message: "Busy generating.") }
    lastHelperKeptConversation = true
    var payload: [String: Any] = [
      "model": serverModelID,
      "messages": [["role": "user", "content": PromptText.neutralized(prompt)]],
      "temperature": 0.0,
      "max_tokens": maxOutputTokens,
      "stream": false,
      "chat_template_kwargs": ["enable_thinking": false],
    ]
    if let schemaData = schemaJSON.data(using: .utf8),
      let schemaObj = try? JSONSerialization.jsonObject(with: schemaData)
    {
      payload["response_format"] = [
        "type": "json_schema",
        "json_schema": ["name": "helper", "schema": schemaObj],
      ]
    }
    let body = try JSONSerialization.data(withJSONObject: payload)
    let text = try await RemoteChatClient.completeJSON(baseURL: baseURL, payloadData: body)
    return Data(text.utf8)
  }

  func helperTexts(
    _ prompts: [String], maxOutputTokens: Int, progress: @Sendable (Int) async -> Void
  ) async throws -> [String] {
    guard !generating else { throw ChatError.underlying(message: "Busy generating.") }
    lastHelperKeptConversation = true
    var outputs: [String] = []
    for prompt in prompts {
      if Task.isCancelled { break }
      let payload: [String: Any] = [
        "model": serverModelID,
        "messages": [["role": "user", "content": PromptText.neutralized(prompt)]],
        "temperature": 0.0,
        "max_tokens": maxOutputTokens,
        "stream": false,
        "chat_template_kwargs": ["enable_thinking": false],
      ]
      let body = try JSONSerialization.data(withJSONObject: payload)
      let reply = try await RemoteChatClient.completeJSON(baseURL: baseURL, payloadData: body)
      outputs.append(reply.trimmingCharacters(in: .whitespacesAndNewlines))
      await progress(outputs.count)
    }
    return outputs
  }

  func transcribe(audioFileURL: URL) async throws -> String {
    guard !generating else { throw ChatError.underlying(message: "Busy generating.") }
    lastHelperKeptConversation = true
    let audioBytes = try Data(contentsOf: audioFileURL)
    let content: [[String: Any]] = [
      ["type": "text", "text": Dictation.instruction],
      [
        "type": "input_audio",
        "input_audio": ["data": audioBytes.base64EncodedString(), "format": "wav"],
      ],
    ]
    let payload: [String: Any] = [
      "model": serverModelID,
      "messages": [["role": "user", "content": content]],
      "temperature": 0.0,
      "max_tokens": Dictation.maxOutputTokens,
      "stream": false,
      "chat_template_kwargs": ["enable_thinking": false],
    ]
    let body = try JSONSerialization.data(withJSONObject: payload)
    let text = try await RemoteChatClient.completeJSON(baseURL: baseURL, payloadData: body)
    return Dictation.clean(text)
  }

  // MARK: - Live streaming & multi-round Simulator tool loop

  private func runSend(
    text: String, imageData: Data?, audioFileURL: URL?,
    continuation: AsyncThrowingStream<ChatEvent, Error>.Continuation
  ) async {
    guard let resolved, let loadedModel else {
      continuation.finish(throwing: ChatError.engineNotReady)
      return
    }
    guard !generating else {
      continuation.finish(throwing: ChatError.underlying(message: "Already generating."))
      return
    }
    generating = true
    cancelRequested = false
    defer {
      generating = false
      activeTask = nil
    }

    let tools = ActiveTools.make(toolsEnabled: toolsEnabled, options: options)
    let toolManager = ToolManager(tools: tools)
    let toolSchemas = parseToolSchemas(toolManager.toolsJsonDescription)
    let toolSchemaTokens = ContextBudget.estimateToolSchemaTokens(toolManager.toolsJsonDescription)
    let userPrompt = promptText(text, imageData, audioFileURL)
    let estimatedPrefill =
      ContextBudget.preambleTokens(
        systemPrompt: options.systemPrompt, toolCount: tools.count,
        toolSchemaTokens: toolSchemaTokens)
      + ContextBudget.estimateHistory(history)
      + ContextBudget.estimateInput(
        text: userPrompt,
        imageTokens: imageData == nil ? nil : Int(resolved.visualTokenBudget ?? 280),
        audioSeconds: audioFileURL == nil ? nil : 10)
    let room =
      ContextBudget.outputCap(maxNumTokens: resolved.maxNumTokens, used: estimatedPrefill, input: 0)
      ?? max(ContextBudget.minReplyTokens, resolved.maxNumTokens / 4)
    let budget = ToolBudget.plan(
      room: room,
      toolsOffered: !tools.isEmpty,
      thinkingBudget: resolved.thinkingBudget,
      maxOutputTokens: resolved.maxOutputTokens
    )
    ToolBudget.begin(budget.limits)
    defer { ToolBudget.end() }

    var messages = buildInitialMessages(
      userText: userPrompt, imageData: imageData, audioFileURL: audioFileURL)
    let started = Date()
    let firstTokenTracker = FirstTokenTracker()
    let toolCursor = ToolActivity.cursor
    var reportedTools = 0
    let cardCursor = ToolCardRecorder.cursor
    var reportedCards = 0
    var totalInput = 0
    var totalOutput = 0
    var finalReplyText = ""
    var reachedLimit = false

    func drainToolActivity() -> [ToolActivityRecord] {
      let all = ToolActivity.records(since: toolCursor)
      defer { reportedTools = all.count }
      return Array(all.dropFirst(reportedTools))
    }

    func drainActionCards() -> [ActionCardRecord] {
      let all = ToolCardRecorder.records(since: cardCursor)
      defer { reportedCards = all.count }
      return Array(all.dropFirst(reportedCards))
    }

    do {
      let maxRounds = budget.limits.maxCalls + 1
      for round in 0..<maxRounds {
        try checkCancelled()
        let roundCap = round == 0 ? budget.outputCap : budget.followUpCap
        let payloadData = try buildRequestData(
          messages: messages, tools: toolSchemas, resolved: resolved, maxTokens: roundCap)
        let roundResult = try await RemoteChatClient.streamCompletion(
          baseURL: baseURL, payloadData: payloadData
        ) { textDelta, thoughtDelta in
          firstTokenTracker.markIfNeeded()
          continuation.yield(.chunk(ChatChunk(textDelta: textDelta, thoughtDelta: thoughtDelta)))
        }
        try checkCancelled()
        totalInput = roundResult.promptTokens ?? totalInput
        totalOutput += roundResult.completionTokens ?? 0
        finalReplyText += roundResult.assistantText

        if roundResult.toolCalls.isEmpty {
          reachedLimit = roundResult.finishReason == "length"
          break
        }

        // Record assistant tool_calls turn and execute real Swift tools inside the iOS Simulator.
        messages.append(assistantToolCallMessage(roundResult))
        let toolResponses = await executeToolCalls(roundResult.toolCalls, using: toolManager)
        let activity = drainToolActivity()
        let cards = drainActionCards()
        if !activity.isEmpty || !cards.isEmpty {
          continuation.yield(
            .chunk(
              ChatChunk(
                textDelta: "", thoughtDelta: nil, toolNames: activity.map(\.name),
                toolActivity: activity, actionCards: cards)))
        }
        messages.append(contentsOf: toolResponses)
      }

      let lateActivity = drainToolActivity()
      let lateCards = drainActionCards()
      if !lateActivity.isEmpty || !lateCards.isEmpty {
        continuation.yield(
          .chunk(
            ChatChunk(
              textDelta: "", thoughtDelta: nil, toolNames: lateActivity.map(\.name),
              toolActivity: lateActivity, actionCards: lateCards)))
      }

      history.append((role: .user, text: userPrompt))
      history.append((role: .model, text: finalReplyText))
      let totalTime = max(0.01, Date().timeIntervalSince(started))
      let tps = totalOutput > 0 ? Double(totalOutput) / totalTime : nil
      var stats = GenerationStats(
        timeToFirstToken: firstTokenTracker.elapsed(since: started),
        totalTime: totalTime,
        inputTokens: totalInput > 0 ? totalInput : nil,
        outputTokens: totalOutput > 0 ? totalOutput : nil,
        decodeTokensPerSecond: tps,
        backend: "Metal 4 (Mac Bridge)",
        modelID: loadedModel
      )
      stats.reachedLimit = reachedLimit
      continuation.yield(.finished(stats))
      continuation.finish()
    } catch is CancellationError {
      continuation.finish(throwing: ChatError.generationCancelled)
    } catch {
      if cancelRequested || Task.isCancelled {
        continuation.finish(throwing: ChatError.generationCancelled)
      } else {
        continuation.finish(throwing: error)
      }
    }
  }

  private func checkCancelled() throws {
    if cancelRequested || Task.isCancelled { throw ChatError.generationCancelled }
  }

  private func buildInitialMessages(
    userText: String, imageData: Data?, audioFileURL: URL?
  ) -> [[String: Any]] {
    var msgs: [[String: Any]] = []
    if !options.systemPrompt.isEmpty {
      msgs.append(["role": "system", "content": PromptText.neutralized(options.systemPrompt)])
    }
    for turn in history {
      msgs.append([
        "role": turn.role == .user ? "user" : "assistant",
        "content": PromptText.neutralized(turn.text),
      ])
    }
    msgs.append(["role": "user", "content": buildUserContent(userText, imageData, audioFileURL)])
    return msgs
  }

  private func buildUserContent(_ text: String, _ imageData: Data?, _ audioFileURL: URL?) -> Any {
    guard imageData != nil || audioFileURL != nil else { return text }
    var parts: [[String: Any]] = []
    if let imageData {
      parts.append([
        "type": "image_url",
        "image_url": ["url": "data:image/jpeg;base64,\(imageData.base64EncodedString())"],
      ])
    }
    parts.append(["type": "text", "text": text])
    if let audioFileURL, let audioBytes = try? Data(contentsOf: audioFileURL) {
      parts.append([
        "type": "input_audio",
        "input_audio": ["data": audioBytes.base64EncodedString(), "format": "wav"],
      ])
    }
    return parts
  }

  private func buildRequestData(
    messages: [[String: Any]], tools: [[String: Any]], resolved: ResolvedInference, maxTokens: Int
  ) throws -> Data {
    let useSampling = samplingSeed != nil
    let temperature: Double = useSampling ? Double(resolved.temperature) : 0.0
    var payload: [String: Any] = [
      "model": serverModelID,
      "messages": messages,
      "temperature": temperature,
      "top_p": Double(resolved.topP),
      "top_k": resolved.topK,
      "seed": samplingSeed ?? 0,
      "max_tokens": maxTokens,
      "stream": true,
      "chat_template_kwargs": ["enable_thinking": resolved.thinkingBudget != nil],
    ]
    if !tools.isEmpty { payload["tools"] = tools }
    return try JSONSerialization.data(withJSONObject: payload)
  }

  private struct ToolCallMessage: Sendable {
    let id: String
    let name: String
    let content: String

    var dictionary: [String: Any] {
      ["role": "tool", "tool_call_id": id, "name": name, "content": content]
    }
  }

  private func executeToolCalls(
    _ calls: [RemoteChatClient.ToolCallItem], using toolManager: ToolManager
  ) async -> [[String: Any]] {
    let allReadOnly = calls.count > 1 && calls.allSatisfy { toolManager.isReadOnly(name: $0.name) }
    if allReadOnly {
      let messages = await withTaskGroup(of: (Int, ToolCallMessage).self) { group in
        for (idx, call) in calls.enumerated() {
          group.addTask { (idx, await Self.runSingleTool(call, using: toolManager)) }
        }
        var ordered = Array(repeating: ToolCallMessage(id: "", name: "", content: ""), count: calls.count)
        for await (idx, msg) in group { ordered[idx] = msg }
        return ordered
      }
      return messages.map(\.dictionary)
    }
    let mutatingCalls = calls.enumerated().filter { !toolManager.isReadOnly(name: $0.element.name) }
    var approvedMutatingIndices: Set<Int>?
    if mutatingCalls.count > 1 {
      let invocations = mutatingCalls.map { idx, call in
        PendingToolInvocation(
          index: idx, name: call.name,
          argumentsJSON: call.argumentsJSON.data(using: .utf8) ?? Data("{}".utf8))
      }
      approvedMutatingIndices = await ToolManager.confirmBatch(invocations)
    }

    var results: [[String: Any]] = []
    for (idx, call) in calls.enumerated() {
      if !toolManager.isReadOnly(name: call.name),
        let approved = approvedMutatingIndices,
        !approved.contains(idx)
      {
        results.append(
          ToolCallMessage(
            id: call.id, name: call.name,
            content: #"{"executed":false,"status":"skipped_by_user"}"#
          ).dictionary)
        continue
      }
      results.append(await Self.runSingleTool(call, using: toolManager).dictionary)
    }
    return results
  }

  private nonisolated static func runSingleTool(
    _ call: RemoteChatClient.ToolCallItem, using toolManager: ToolManager
  ) async -> ToolCallMessage {
    let args: [String: Any]
    if let data = call.argumentsJSON.data(using: .utf8),
      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    {
      args = dict
    } else {
      args = [:]
    }
    let responseValue: Any
    do {
      responseValue = try await toolManager.execute(name: call.name, arguments: args)
    } catch {
      responseValue = ["error": error.localizedDescription]
    }
    let contentStr: String
    if let data = try? JSONSerialization.data(withJSONObject: responseValue),
      let text = String(data: data, encoding: .utf8)
    {
      contentStr = text
    } else {
      contentStr = String(describing: responseValue)
    }
    return ToolCallMessage(id: call.id, name: call.name, content: contentStr)
  }

  private func assistantToolCallMessage(_ result: RemoteChatClient.StreamResult) -> [String: Any] {
    let calls: [[String: Any]] = result.toolCalls.map { call in
      [
        "id": call.id,
        "type": "function",
        "function": ["name": call.name, "arguments": call.argumentsJSON],
      ]
    }
    var msg: [String: Any] = ["role": "assistant", "tool_calls": calls]
    msg["content"] = result.assistantText.isEmpty ? NSNull() : result.assistantText
    return msg
  }

  private func parseToolSchemas(_ json: String) -> [[String: Any]] {
    guard let data = json.data(using: .utf8),
      let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    else { return [] }
    return arr
  }

  private func promptText(_ text: String, _ imageData: Data?, _ audioFileURL: URL?) -> String {
    if imageData != nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Describe this image in detail."
    }
    if !text.isEmpty { return PromptText.neutralized(text) }
    return audioFileURL != nil ? "Listen to this voice message and respond to it." : "Hello!"
  }
}

private final class FirstTokenTracker: @unchecked Sendable {
  private let lock = NSLock()
  private var firstAt: Date?

  func markIfNeeded() {
    lock.lock()
    if firstAt == nil { firstAt = Date() }
    lock.unlock()
  }

  func elapsed(since started: Date) -> TimeInterval? {
    lock.lock()
    defer { lock.unlock() }
    return firstAt.map { $0.timeIntervalSince(started) }
  }
}
