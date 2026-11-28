import Foundation
import LiteRTLM

/// OpenAI `/v1/chat/completions` (blocking + live token-by-token SSE streaming), `/v1/tokenize`,
/// `/v1/embeddings`, and single-session prefix-KV reuse execution for `agello serve` (`Serve.swift`).
enum ServeProtocol {
  static let maxClampedTokens = 131_072, maxClampedTopK = 262_144

  struct ExecutionContext: Sendable {
    let options: Serve.Options
    let allocatedPositions, requestIndex: Int
    let visualTokenBudget: Int32
  }

  struct CachedSession: Sendable {
    let conversation: Conversation
    let config: ServeSessionConfig
    var messages: [ServeMessage]
  }

  struct CompletionOutcome: Sendable {
    let status: Int
    let contentType: String
    let body: Data
    let cachedSession: CachedSession?
  }

  struct CompletionRequest: Sendable {
    let requestedModel, toolsSignature: String
    let stream, enableThinking, useMTP, hasResponseFormat, isHelper: Bool
    let thinkingBudget, topK, seed, requestedMax: Int
    let temperature, topP: Float
    let stopStrings: [String]
    let rawToolsJSON: String?
    let prefixData: Data
  }

  struct PreparedTurn {
    let request: CompletionRequest
    let sessionConfig: ServeSessionConfig
    let incomingMessages: [ServeMessage]
    let conversation: Conversation
    let lastMessage: LiteRTLM.Message
    let responseFormat: ResponseFormat?
    let promptTokens, cappedOutput: Int
    let kvReused: Bool
  }

  static func healthObject(
    modelID: String, allocatedPositions: Int, hasEmbedder: Bool, runtimeBuildID: String = EngineCache.runtimeBuildID
  ) -> [String: Any] {
    ["status": "ok", "model": modelID, "kv": allocatedPositions, "embeddings": hasEmbedder, "build": runtimeBuildID, "runtime_build": runtimeBuildID]
  }

  static func wantsStreaming(requestData: Data) -> Bool {
    ((try? JSONSerialization.jsonObject(with: requestData) as? [String: Any])?["stream"] as? Bool) ?? false
  }

  static func drainConversation(_ conversation: Conversation) async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      DispatchQueue.global(qos: .userInitiated).async {
        _ = try? conversation.waitUntilDone()
        cont.resume()
      }
    }
  }

  static func runTokenize(
    engine: Engine, context: ExecutionContext, cachedSession: CachedSession?, requestData: Data
  ) async -> (Int, Data) {
    guard let body = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any] else {
      return errorResponse(status: 400, message: "Expected JSON object for /v1/tokenize.", type: "invalid_request_error")
    }
    if let text = (body["text"] as? String) ?? (body["prompt"] as? String) {
      do {
        return tokenizeSuccessResponse(
          tokens: try await engine.countTokens(text), allocatedPositions: context.allocatedPositions)
      } catch { return errorResponse(status: 500, message: "Tokenize failed: \(error)") }
    }
    guard let rawMessages = body["messages"] as? [[String: Any]], !rawMessages.isEmpty else {
      return errorResponse(status: 400, message: "Expected 'text' string or non-empty 'messages' array.", type: "invalid_request_error")
    }
    do {
      let count = try await countConversationTokens(
        engine: engine, body: body, rawMessages: rawMessages, context: context, cachedSession: cachedSession)
      return tokenizeSuccessResponse(tokens: count, allocatedPositions: context.allocatedPositions)
    } catch { return errorResponse(status: 500, message: "Message tokenize failed: \(error)") }
  }

  static func tokenizeSuccessResponse(tokens: Int, allocatedPositions: Int) -> (Int, Data) {
    (200, (try? JSONSerialization.data(withJSONObject: ["tokens": max(0, tokens), "allocated_positions": allocatedPositions])) ?? Data("{}".utf8))
  }

  static func runCompletion(
    engine: Engine, context: ExecutionContext, cachedSession: CachedSession?, requestData: Data
  ) async -> CompletionOutcome {
    let prepared: PreparedTurn
    switch await prepareTurn(engine: engine, context: context, cachedSession: cachedSession, requestData: requestData) {
    case .success(let turn): prepared = turn
    case .failure(let err): return .init(status: err.status, contentType: "application/json", body: err.rowData, cachedSession: err.retainedSession)
    }
    do {
      let started = ContinuousClock.now
      let reply = try await prepared.conversation.sendMessage(
        prepared.lastMessage, maxOutputTokens: prepared.cappedOutput,
        thinkingConfig: ThinkingConfig(enableThinking: prepared.request.enableThinking, thinkingTokenBudget: prepared.request.thinkingBudget),
        responseFormat: prepared.responseFormat)
      let elapsed = (ContinuousClock.now - started) / .seconds(1)
      let totalKV = (try? prepared.conversation.getTokenCount()) ?? prepared.promptTokens
      let completionTokens = max(1, totalKV - prepared.promptTokens)
      let (_, matchedStop) = applyStopStrings(reply.toString, stopStrings: prepared.request.stopStrings)
      let envelope = buildEnvelope(
        reply: reply, request: prepared.request, context: context,
        counts: (prompt: prepared.promptTokens, completion: completionTokens, cap: prepared.cappedOutput))
      let nextCached = updatedSessionAfterCompletion(
        prepared: prepared, previousCached: cachedSession,
        reply: .init(
          text: (envelope.message["content"] as? String) ?? "", toolCalls: reply.toolCalls,
          requestIndex: context.requestIndex, invalidatedByStop: matchedStop != nil))
      logCompletion(context: context, envelope: envelope, prepared: prepared, out: completionTokens, elapsed: elapsed)
      let (s, ct, d) = serializeCompletionResponse(envelope: envelope, kvReused: prepared.kvReused)
      return CompletionOutcome(status: s, contentType: ct, body: d, cachedSession: nextCached)
    } catch {
      note("[#\(context.requestIndex)] error: \(error)")
      try? prepared.conversation.cancel()
      await drainConversation(prepared.conversation)
      let retained = restoreHelperSession(isHelper: prepared.request.isHelper, previous: cachedSession)
      let (s, d) = errorResponse(status: 500, message: "Inference failed: \(error)")
      return CompletionOutcome(status: s, contentType: "application/json", body: d, cachedSession: retained)
    }
  }

  static func runStreamingCompletion(
    engine: Engine, context: ExecutionContext, cachedSession: CachedSession?, requestData: Data, fd: Int32
  ) async -> CachedSession? {
    let prepared: PreparedTurn
    switch await prepareTurn(engine: engine, context: context, cachedSession: cachedSession, requestData: requestData) {
    case .success(let turn): prepared = turn
    case .failure(let err):
      Serve.writeRaw(fd, status: err.status, contentType: "application/json", body: err.rowData)
      return err.retainedSession
    }
    guard Serve.writeSSEHeaders(fd) else {
      try? prepared.conversation.cancel()
      await drainConversation(prepared.conversation)
      return restoreHelperSession(isHelper: prepared.request.isHelper, previous: cachedSession)
    }
    return await streamPreparedTurn(prepared: prepared, context: context, previousCached: cachedSession, fd: fd)
  }

  @discardableResult
  static func writeSSEErrorAndHalt(fd: Int32, message: String, type: String = "server_error") -> Bool {
    Serve.writeSSEObject(fd, ["error": ["message": message, "type": type]])
  }
}

// MARK: - Streaming & turn preparation

extension ServeProtocol {
  fileprivate struct ReplySummary {
    let text: String
    let toolCalls: [LiteRTLM.ToolCall]
    let requestIndex: Int
    let invalidatedByStop: Bool
  }

  fileprivate struct StreamRunOutcome {
    var assistantText = ""
    var toolCalls: [LiteRTLM.ToolCall] = []
    var disconnected = false, stoppedBySequence = false, streamFailed = false
  }

  fileprivate struct StreamFrameMeta {
    let id, model: String
    let created: Int
    var elapsed: Double = 0
  }

  fileprivate struct PrepareError: Error {
    let status: Int
    let rowData: Data
    let retainedSession: CachedSession?
  }

  fileprivate static func countConversationTokens(
    engine: Engine, body: [String: Any], rawMessages: [[String: Any]], context: ExecutionContext, cachedSession: CachedSession?
  ) async throws -> Int {
    let (prefix, lastRawBatch, toolNameByID) = ServeMessages.splitMessages(rawMessages)
    var syntheticBody = body
    if let thinking = body["thinking"] as? Bool, body["enable_thinking"] == nil { syntheticBody["enable_thinking"] = thinking }
    let req = parseRequest(body: syntheticBody, prefix: prefix, options: context.options)
    let candidate = (config: makeSessionConfig(request: req, rawMessages: rawMessages), messages: ServeMessages.canonicalize(rawMessages))
    if let warm = try? await measureWarmDelta(engine: engine, cachedSession: cachedSession, candidate: candidate, budget: context.visualTokenBudget) {
      return warm.promptTokens
    }
    defer { if let cached = cachedSession { _ = try? cached.conversation.getTokenCount() } }
    if lastRawBatch.isEmpty {
      let tempConv = try await createConversation(engine: engine, request: req, visualTokenBudget: context.visualTokenBudget)
      let media = ServeMessages.estimateMediaTokens(rawMessages, visualTokenBudget: context.visualTokenBudget)
      return (try await engine.countTokens(try tempConv.renderPrefaceIntoString())) + 1 + media
    }
    return try await buildColdConversation(
      engine: engine, request: req, budget: context.visualTokenBudget,
      split: (prefix: prefix, lastBatch: lastRawBatch, toolNames: toolNameByID)).promptTokens
  }

  private static func measureWarmDelta(
    engine: Engine, cachedSession: CachedSession?,
    candidate: (config: ServeSessionConfig, messages: [ServeMessage]), budget: Int32
  ) async throws -> (conversation: Conversation, deltaMsg: LiteRTLM.Message, promptTokens: Int)? {
    guard let cached = cachedSession,
      case .reuse(let delta) = ServeMessages.matchPrefix(
        cachedMessages: cached.messages, cachedConfig: cached.config,
        incomingMessages: candidate.messages, incomingConfig: candidate.config)
    else { return nil }
    let cachedKV = try cached.conversation.getTokenCount()
    guard cachedKV > 0 else { return nil }
    let (deltaMsg, deltaMedia) = ServeMessages.buildDeltaMessage(delta, visualTokenBudget: budget)
    let rendered = try cached.conversation.renderMessageIntoString(deltaMsg)
    return (cached.conversation, deltaMsg, cachedKV + (try await engine.countTokens(rendered)) + deltaMedia)
  }

  private static func buildColdConversation(
    engine: Engine, request: CompletionRequest, budget: Int32,
    split: (prefix: [[String: Any]], lastBatch: [[String: Any]], toolNames: [String: String])
  ) async throws -> (conversation: Conversation, lastMessage: LiteRTLM.Message, promptTokens: Int) {
    let conversation = try await createConversation(engine: engine, request: request, visualTokenBudget: budget)
    let (lastMessage, lastMedia) = ServeMessages.buildFinalMessage(
      split.lastBatch, toolNameByID: split.toolNames, visualTokenBudget: budget)
    let prefixMedia = ServeMessages.estimateMediaTokens(split.prefix, visualTokenBudget: budget)
    let rendered = try conversation.renderMessageIntoString(lastMessage)
    return (conversation, lastMessage, (try await engine.countTokens(rendered)) + 1 + prefixMedia + lastMedia)
  }

  fileprivate static func streamPreparedTurn(
    prepared: PreparedTurn, context: ExecutionContext, previousCached: CachedSession?, fd: Int32
  ) async -> CachedSession? {
    let started = ContinuousClock.now
    var meta = StreamFrameMeta(
      id: "chatcmpl-agello-\(context.requestIndex)", model: prepared.request.requestedModel,
      created: Int(Date().timeIntervalSince1970))
    let run = await consumeNativeStream(prepared: prepared, context: context, meta: meta, fd: fd)
    if run.streamFailed || run.disconnected {
      await drainConversation(prepared.conversation)
      if run.disconnected { note("[#\(context.requestIndex)] stream cancelled by client") }
      return restoreHelperSession(isHelper: prepared.request.isHelper, previous: previousCached)
    }
    if run.stoppedBySequence { await drainConversation(prepared.conversation) }
    meta.elapsed = (ContinuousClock.now - started) / .seconds(1)
    emitStreamCompletionFrames(prepared: prepared, context: context, run: run, meta: meta, fd: fd)
    return updatedSessionAfterCompletion(
      prepared: prepared, previousCached: previousCached,
      reply: .init(
        text: run.assistantText, toolCalls: run.toolCalls,
        requestIndex: context.requestIndex, invalidatedByStop: run.stoppedBySequence))
  }

  private static func consumeNativeStream(
    prepared: PreparedTurn, context: ExecutionContext, meta: StreamFrameMeta, fd: Int32
  ) async -> StreamRunOutcome {
    var outcome = StreamRunOutcome()
    var stopFilter = StreamingStopFilter(stopStrings: prepared.request.stopStrings)
    func emit(_ delta: [String: Any]) -> Bool {
      Serve.writeSSEObject(
        fd,
        [
          "id": meta.id, "object": "chat.completion.chunk", "created": meta.created,
          "model": meta.model, "choices": [["index": 0, "delta": delta, "finish_reason": NSNull()]],
        ])
    }
    do {
      let stream = prepared.conversation.sendMessageStream(
        prepared.lastMessage, maxOutputTokens: prepared.cappedOutput,
        thinkingConfig: ThinkingConfig(enableThinking: prepared.request.enableThinking, thinkingTokenBudget: prepared.request.thinkingBudget),
        responseFormat: prepared.responseFormat)
      for try await chunk in stream {
        if !chunk.toolCalls.isEmpty { outcome.toolCalls.append(contentsOf: chunk.toolCalls) }
        guard let rawDelta = makeStreamDelta(chunk: chunk, enableThinking: prepared.request.enableThinking) else { continue }
        let step = filterChunkDelta(rawDelta, stopFilter: &stopFilter, textOut: &outcome.assistantText)
        if !step.delta.isEmpty, !emit(step.delta) {
          outcome.disconnected = true
          try? prepared.conversation.cancel()
          return outcome
        }
        if step.stopped {
          outcome.stoppedBySequence = true
          try? prepared.conversation.cancel()
          return outcome
        }
      }
      let trailing = stopFilter.flush()
      if !trailing.isEmpty {
        outcome.assistantText += trailing
        if !emit(["content": trailing]) {
          outcome.disconnected = true
          try? prepared.conversation.cancel()
        }
      }
    } catch {
      outcome.streamFailed = true
      if !outcome.disconnected {
        note("[#\(context.requestIndex)] stream error: \(error)")
        _ = writeSSEErrorAndHalt(fd: fd, message: "\(error)")
      }
      try? prepared.conversation.cancel()
    }
    return outcome
  }

  private static func filterChunkDelta(
    _ rawDelta: [String: Any], stopFilter: inout StreamingStopFilter, textOut: inout String
  ) -> (delta: [String: Any], stopped: Bool) {
    var outDelta: [String: Any] = [:]
    if let reasoning = rawDelta["reasoning"] as? String, !reasoning.isEmpty {
      outDelta["reasoning"] = reasoning
      outDelta["reasoning_content"] = reasoning
    }
    guard let content = rawDelta["content"] as? String, !content.isEmpty else { return (outDelta, false) }
    let (safeContent, hitStop) = stopFilter.push(content)
    if !safeContent.isEmpty {
      textOut += safeContent
      outDelta["content"] = safeContent
    }
    return (outDelta, hitStop)
  }

  private static func emitStreamCompletionFrames(
    prepared: PreparedTurn, context: ExecutionContext, run: StreamRunOutcome, meta: StreamFrameMeta, fd: Int32
  ) {
    let totalKV = (try? prepared.conversation.getTokenCount()) ?? prepared.promptTokens
    let outTokens = max(1, totalKV - prepared.promptTokens)
    if !run.toolCalls.isEmpty {
      let calls = formatToolCalls(run.toolCalls, requestIndex: context.requestIndex, includeIndex: true)
      _ = Serve.writeSSEObject(
        fd,
        [
          "id": meta.id, "object": "chat.completion.chunk", "created": meta.created, "model": meta.model,
          "choices": [["index": 0, "delta": ["tool_calls": calls], "finish_reason": NSNull()]],
        ])
    }
    let finish = !run.toolCalls.isEmpty ? "tool_calls" : (!run.stoppedBySequence && outTokens >= prepared.cappedOutput ? "length" : "stop")
    let finalFrame: [String: Any] = [
      "id": meta.id, "object": "chat.completion.chunk", "created": meta.created, "model": meta.model,
      "choices": [["index": 0, "delta": [:] as [String: Any], "finish_reason": finish]],
      "usage": ["prompt_tokens": prepared.promptTokens, "completion_tokens": outTokens, "total_tokens": prepared.promptTokens + outTokens],
      "kv_reused": prepared.kvReused,
    ]
    _ = Serve.writeSSEObject(fd, finalFrame)
    _ = Serve.writeBytes(fd, Data("data: [DONE]\n\n".utf8))
    note(
      String(
        format: "[#%d] sse in=%d out=%d tools=%d think=%@ kv_reused=%@ finish=%@ %.2fs",
        context.requestIndex, prepared.promptTokens, outTokens, run.toolCalls.count,
        prepared.request.enableThinking ? "on" : "off", prepared.kvReused ? "true" : "false", finish, meta.elapsed))
  }

  fileprivate static func prepareTurn(
    engine: Engine, context: ExecutionContext, cachedSession: CachedSession?, requestData: Data
  ) async -> Result<PreparedTurn, PrepareError> {
    guard let body = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
      let rawMessages = body["messages"] as? [[String: Any]], !rawMessages.isEmpty
    else {
      let (s, d) = errorResponse(status: 400, message: "Request requires a non-empty 'messages' array.", type: "invalid_request_error")
      return .failure(PrepareError(status: s, rowData: d, retainedSession: cachedSession))
    }
    let (prefix, lastRawBatch, toolNameByID) = ServeMessages.splitMessages(rawMessages)
    guard !lastRawBatch.isEmpty else {
      let (s, d) = errorResponse(status: 400, message: "No user or tool message to send.", type: "invalid_request_error")
      return .failure(PrepareError(status: s, rowData: d, retainedSession: cachedSession))
    }
    let req = parseRequest(body: body, prefix: prefix, options: context.options)
    let candidate = (
      req: req, config: makeSessionConfig(request: req, rawMessages: rawMessages),
      messages: ServeMessages.canonicalize(rawMessages),
      format: ServeMessages.parseResponseFormat(body["response_format"] as? [String: Any]))
    if !req.isHelper {
      do {
        if let warm = try await measureWarmDelta(
          engine: engine, cachedSession: cachedSession,
          candidate: (config: candidate.config, messages: candidate.messages), budget: context.visualTokenBudget)
        {
          let room = context.allocatedPositions - warm.promptTokens - ContextBudget.safetyMargin
          guard room > 0 else {
            await drainConversation(warm.conversation)
            let (s, d) = kvOverflowError(promptTokens: warm.promptTokens, limit: context.allocatedPositions)
            return .failure(PrepareError(status: s, rowData: d, retainedSession: nil))
          }
          return .success(
            PreparedTurn(
              request: req, sessionConfig: candidate.config, incomingMessages: candidate.messages,
              conversation: warm.conversation, lastMessage: warm.deltaMsg, responseFormat: candidate.format,
              promptTokens: warm.promptTokens, cappedOutput: min(max(1, req.requestedMax), room), kvReused: true))
        }
      } catch { if let cached = cachedSession { await drainConversation(cached.conversation) } }
      if let stale = cachedSession { await drainConversation(stale.conversation) }
    }
    return await prepareColdTurn(
      engine: engine, context: context, cachedSession: cachedSession,
      split: (prefix: prefix, lastBatch: lastRawBatch, toolNames: toolNameByID), candidate: candidate)
  }

  private static func prepareColdTurn(
    engine: Engine, context: ExecutionContext, cachedSession: CachedSession?,
    split: (prefix: [[String: Any]], lastBatch: [[String: Any]], toolNames: [String: String]),
    candidate: (req: CompletionRequest, config: ServeSessionConfig, messages: [ServeMessage], format: ResponseFormat?)
  ) async -> Result<PreparedTurn, PrepareError> {
    do {
      let cold = try await buildColdConversation(
        engine: engine, request: candidate.req, budget: context.visualTokenBudget, split: split)
      let room = context.allocatedPositions - cold.promptTokens - ContextBudget.safetyMargin
      guard room > 0 else {
        let retained = restoreHelperSession(isHelper: candidate.req.isHelper, previous: cachedSession)
        let (s, d) = kvOverflowError(promptTokens: cold.promptTokens, limit: context.allocatedPositions)
        return .failure(PrepareError(status: s, rowData: d, retainedSession: retained))
      }
      return .success(
        PreparedTurn(
          request: candidate.req, sessionConfig: candidate.config, incomingMessages: candidate.messages,
          conversation: cold.conversation, lastMessage: cold.lastMessage, responseFormat: candidate.format,
          promptTokens: cold.promptTokens, cappedOutput: min(max(1, candidate.req.requestedMax), room), kvReused: false))
    } catch {
      let retained = restoreHelperSession(isHelper: candidate.req.isHelper, previous: cachedSession)
      let (s, d) = errorResponse(status: 500, message: "Conversation setup failed: \(error)")
      return .failure(PrepareError(status: s, rowData: d, retainedSession: retained))
    }
  }

  private static func kvOverflowError(promptTokens: Int, limit: Int) -> (Int, Data) {
    errorResponse(status: 400, message: "Prompt (\(promptTokens) tokens) exceeds KV window (\(limit)).", type: "invalid_request_error")
  }

  fileprivate static func updatedSessionAfterCompletion(
    prepared: PreparedTurn, previousCached: CachedSession?, reply: ReplySummary
  ) -> CachedSession? {
    if prepared.request.isHelper { return restoreHelperSession(isHelper: true, previous: previousCached) }
    guard !reply.invalidatedByStop else { return nil }
    let assistantMsg = ServeMessages.assistantServeMessage(
      text: reply.text, toolCalls: reply.toolCalls, requestIndex: reply.requestIndex)
    return CachedSession(
      conversation: prepared.conversation, config: prepared.sessionConfig, messages: prepared.incomingMessages + [assistantMsg])
  }

  fileprivate static func restoreHelperSession(isHelper: Bool, previous: CachedSession?) -> CachedSession? {
    guard isHelper, let previous else { return nil }
    _ = try? previous.conversation.getTokenCount()
    return previous
  }

  private static func createConversation(
    engine: Engine, request: CompletionRequest, visualTokenBudget: Int32
  ) async throws -> Conversation {
    let prefixMessages = (try? JSONSerialization.jsonObject(with: request.prefixData)) as? [[String: Any]] ?? []
    let (systemMessage, initialMessages) = ServeMessages.translatePrefix(prefixMessages, visualTokenBudget: visualTokenBudget)
    let sampler = try SamplerConfig(
      topK: max(1, request.topK), topP: min(max(request.topP, 0), 1),
      temperature: max(0, request.temperature), seed: request.seed)
    let config = ConversationConfig(
      systemMessage: systemMessage, initialMessages: initialMessages, tools: [], samplerConfig: sampler,
      thinkingConfig: ThinkingConfig(enableThinking: request.enableThinking, thinkingTokenBudget: request.thinkingBudget),
      automaticToolCalling: false, enableResponseFormat: request.hasResponseFormat,
      visualTokenBudget: visualTokenBudget, enableSpeculativeDecoding: request.useMTP, rawToolsJSON: request.rawToolsJSON)
    return try await engine.createConversation(with: config)
  }

  fileprivate static func serializeCompletionResponse(envelope: CompletionEnvelope, kvReused: Bool) -> (Int, String, Data) {
    let obj: [String: Any] = [
      "id": envelope.id, "object": "chat.completion", "created": envelope.created, "model": envelope.model,
      "choices": [["index": 0, "message": envelope.message, "finish_reason": envelope.finishReason]],
      "usage": envelope.usage, "kv_reused": kvReused,
    ]
    return (200, "application/json", (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8))
  }

  fileprivate static func logCompletion(
    context: ExecutionContext, envelope: CompletionEnvelope, prepared: PreparedTurn, out: Int, elapsed: Double
  ) {
    let toolCount = (envelope.message["tool_calls"] as? [[String: Any]])?.count ?? 0
    note(
      String(
        format: "[#%d] in=%d out=%d tools=%d think=%@ kv_reused=%@ finish=%@ %.2fs",
        context.requestIndex, prepared.promptTokens, out, toolCount,
        prepared.request.enableThinking ? "on" : "off", prepared.kvReused ? "true" : "false", envelope.finishReason, elapsed))
  }
}
