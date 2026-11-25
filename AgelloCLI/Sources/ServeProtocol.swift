import Foundation
import LiteRTLM

/// OpenAI `/v1/chat/completions` (blocking + live token-by-token SSE streaming) and
/// `/v1/embeddings` execution for `agello serve` (`Serve.swift`).
enum ServeProtocol {
  struct ExecutionContext: Sendable {
    let options: Serve.Options
    let allocatedPositions: Int
    let visualTokenBudget: Int32
    let requestIndex: Int
  }

  struct CompletionRequest: Sendable {
    let requestedModel: String
    let stream: Bool
    let enableThinking: Bool
    let thinkingBudget: Int
    let temperature: Float
    let topP: Float
    let topK: Int
    let seed: Int
    let useMTP: Bool
    let requestedMax: Int
    let stopStrings: [String]
    let rawToolsJSON: String?
    let hasResponseFormat: Bool
    let prefixData: Data
  }

  struct PreparedTurn {
    let request: CompletionRequest
    let conversation: Conversation
    let lastMessage: LiteRTLM.Message
    let responseFormat: ResponseFormat?
    let promptTokens: Int
    let cappedOutput: Int
  }

  static func wantsStreaming(requestData: Data) -> Bool {
    guard let body = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any] else {
      return false
    }
    return (body["stream"] as? Bool) ?? false
  }

  static func runCompletion(
    engine: Engine, context: ExecutionContext, requestData: Data
  ) async -> (Int, String, Data) {
    let prepared: PreparedTurn
    switch await prepareTurn(engine: engine, context: context, requestData: requestData) {
    case .success(let turn): prepared = turn
    case .failure(let err): return (err.status, "application/json", err.data)
    }

    do {
      let started = ContinuousClock.now
      let reply = try await prepared.conversation.sendMessage(
        prepared.lastMessage,
        maxOutputTokens: prepared.cappedOutput,
        thinkingConfig: ThinkingConfig(
          enableThinking: prepared.request.enableThinking,
          thinkingTokenBudget: prepared.request.thinkingBudget),
        responseFormat: prepared.responseFormat
      )
      let elapsed = (ContinuousClock.now - started) / .seconds(1)
      let totalKV = (try? prepared.conversation.getTokenCount()) ?? prepared.promptTokens
      let completionTokens = max(1, totalKV - prepared.promptTokens)

      let envelope = buildEnvelope(
        reply: reply,
        request: prepared.request,
        context: context,
        counts: (
          prompt: prepared.promptTokens, completion: completionTokens, cap: prepared.cappedOutput
        )
      )
      logTurn(context: context, envelope: envelope, prepared: prepared, out: completionTokens, elapsed: elapsed)
      return serializeResponse(envelope: envelope)
    } catch {
      note("[#\(context.requestIndex)] error: \(error)")
      let (s, d) = errorResponse(status: 500, message: "Inference failed: \(error)")
      return (s, "application/json", d)
    }
  }

  static func runStreamingCompletion(
    engine: Engine, context: ExecutionContext, requestData: Data, fd: Int32
  ) async {
    let prepared: PreparedTurn
    switch await prepareTurn(engine: engine, context: context, requestData: requestData) {
    case .success(let turn): prepared = turn
    case .failure(let err):
      Serve.writeRaw(fd, status: err.status, contentType: "application/json", body: err.data)
      return
    }

    let id = "chatcmpl-agello-\(context.requestIndex)"
    let created = Int(Date().timeIntervalSince1970)
    let model = prepared.request.requestedModel
    guard Serve.writeSSEHeaders(fd) else { return }

    let started = ContinuousClock.now
    var collectedToolCalls: [LiteRTLM.ToolCall] = []
    var clientDisconnected = false

    do {
      let stream = prepared.conversation.sendMessageStream(
        prepared.lastMessage,
        maxOutputTokens: prepared.cappedOutput,
        thinkingConfig: ThinkingConfig(
          enableThinking: prepared.request.enableThinking,
          thinkingTokenBudget: prepared.request.thinkingBudget),
        responseFormat: prepared.responseFormat
      )
      for try await chunk in stream {
        if !chunk.toolCalls.isEmpty { collectedToolCalls.append(contentsOf: chunk.toolCalls) }
        guard let delta = makeStreamDelta(chunk: chunk, enableThinking: prepared.request.enableThinking)
        else { continue }
        let frame: [String: Any] = [
          "id": id, "object": "chat.completion.chunk", "created": created, "model": model,
          "choices": [["index": 0, "delta": delta, "finish_reason": NSNull()]],
        ]
        if !Serve.writeSSEObject(fd, frame) {
          clientDisconnected = true
          try? prepared.conversation.cancel()
          break
        }
      }
    } catch {
      if !clientDisconnected {
        note("[#\(context.requestIndex)] stream error: \(error)")
        _ = Serve.writeSSEObject(fd, ["error": ["message": "\(error)", "type": "server_error"]])
      }
    }

    guard !clientDisconnected else {
      note("[#\(context.requestIndex)] stream cancelled by client")
      return
    }

    let elapsed = (ContinuousClock.now - started) / .seconds(1)
    let totalKV = (try? prepared.conversation.getTokenCount()) ?? prepared.promptTokens
    let completionTokens = max(1, totalKV - prepared.promptTokens)

    if !collectedToolCalls.isEmpty {
      let calls = formatToolCalls(collectedToolCalls, requestIndex: context.requestIndex, includeIndex: true)
      let toolFrame: [String: Any] = [
        "id": id, "object": "chat.completion.chunk", "created": created, "model": model,
        "choices": [["index": 0, "delta": ["tool_calls": calls], "finish_reason": NSNull()]],
      ]
      _ = Serve.writeSSEObject(fd, toolFrame)
    }

    let finishReason =
      !collectedToolCalls.isEmpty
      ? "tool_calls" : (completionTokens >= prepared.cappedOutput ? "length" : "stop")
    let usage: [String: Any] = [
      "prompt_tokens": prepared.promptTokens,
      "completion_tokens": completionTokens,
      "total_tokens": prepared.promptTokens + completionTokens,
    ]
    let finalFrame: [String: Any] = [
      "id": id, "object": "chat.completion.chunk", "created": created, "model": model,
      "choices": [["index": 0, "delta": [:] as [String: Any], "finish_reason": finishReason]],
      "usage": usage,
    ]
    _ = Serve.writeSSEObject(fd, finalFrame)
    _ = Serve.writeBytes(fd, Data("data: [DONE]\n\n".utf8))
    note(
      String(
        format: "[#%d] sse in=%d out=%d tools=%d think=%@ finish=%@ %.2fs",
        context.requestIndex, prepared.promptTokens, completionTokens, collectedToolCalls.count,
        prepared.request.enableThinking ? "on" : "off", finishReason, elapsed)
    )
  }

  // MARK: - Preparation

  private struct HTTPError: Error {
    let status: Int
    let data: Data
  }

  private static func prepareTurn(
    engine: Engine, context: ExecutionContext, requestData: Data
  ) async -> Result<PreparedTurn, HTTPError> {
    guard let body = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
      let rawMessages = body["messages"] as? [[String: Any]], !rawMessages.isEmpty
    else {
      let (s, d) = errorResponse(status: 400, message: "Request requires a non-empty 'messages' array.")
      return .failure(HTTPError(status: s, data: d))
    }

    let (prefix, lastRawBatch, toolNameByID) = ServeMessages.splitMessages(rawMessages)
    guard !lastRawBatch.isEmpty else {
      let (s, d) = errorResponse(status: 400, message: "No user or tool message to send.")
      return .failure(HTTPError(status: s, data: d))
    }

    let req = parseRequest(body: body, prefix: prefix, options: context.options)
    let responseFormat = ServeMessages.parseResponseFormat(body["response_format"] as? [String: Any])

    do {
      let conversation = try await createConversation(
        engine: engine, request: req, visualTokenBudget: context.visualTokenBudget)
      let (lastMessage, lastMediaEstimate) = ServeMessages.buildFinalMessage(
        lastRawBatch, toolNameByID: toolNameByID, visualTokenBudget: context.visualTokenBudget)
      let prefixMediaEstimate = ServeMessages.estimateMediaTokens(
        prefix, visualTokenBudget: context.visualTokenBudget)

      let rendered = (try? conversation.renderMessageIntoString(lastMessage)) ?? ""
      let renderedTokens =
        (try? await engine.countTokens(rendered)) ?? ContextBudget.estimateTextTokens(rendered)
      let promptTokens = renderedTokens + 1 + prefixMediaEstimate + lastMediaEstimate
      let availableRoom = context.allocatedPositions - promptTokens - 64
      guard availableRoom > 0 else {
        let (s, d) = errorResponse(
          status: 400,
          message: "Prompt (\(promptTokens) tokens) exceeds KV window (\(context.allocatedPositions)).",
          type: "invalid_request_error")
        return .failure(HTTPError(status: s, data: d))
      }
      return .success(
        PreparedTurn(
          request: req,
          conversation: conversation,
          lastMessage: lastMessage,
          responseFormat: responseFormat,
          promptTokens: promptTokens,
          cappedOutput: min(max(1, req.requestedMax), availableRoom)
        ))
    } catch {
      let (s, d) = errorResponse(status: 500, message: "Conversation setup failed: \(error)")
      return .failure(HTTPError(status: s, data: d))
    }
  }

  private static func parseRequest(
    body: [String: Any], prefix: [[String: Any]], options: Serve.Options
  ) -> CompletionRequest {
    let enableThinking = resolveThinking(body: body, defaultValue: options.thinkByDefault)
    let temperature = Float(
      (body["temperature"] as? Double)
        ?? (body["temperature"] as? Int).map(Double.init)
        ?? 0.0
    )
    let topP = Float((body["top_p"] as? Double) ?? (temperature <= 0 ? 1.0 : 0.95))
    let topK = (body["top_k"] as? Int) ?? (temperature <= 0 ? 1 : 64)
    let requestedMax =
      (body["max_completion_tokens"] as? Int)
      ?? (body["max_tokens"] as? Int)
      ?? 4096

    let rawToolsJSON: String?
    if let rawTools = body["tools"] as? [[String: Any]], !rawTools.isEmpty,
      let toolsData = try? JSONSerialization.data(withJSONObject: rawTools),
      let toolsString = String(data: toolsData, encoding: .utf8)
    {
      rawToolsJSON = toolsString
    } else {
      rawToolsJSON = nil
    }

    let prefixData = (try? JSONSerialization.data(withJSONObject: prefix)) ?? Data("[]".utf8)
    return CompletionRequest(
      requestedModel: (body["model"] as? String) ?? options.modelID,
      stream: (body["stream"] as? Bool) ?? false,
      enableThinking: enableThinking,
      thinkingBudget: enableThinking ? max(options.thinkingBudget, requestedMax) : 0,
      temperature: temperature,
      topP: topP,
      topK: topK,
      seed: (body["seed"] as? Int) ?? 0,
      useMTP: options.allowMTP && temperature <= 0,
      requestedMax: requestedMax,
      stopStrings: parseStopStrings(body["stop"]),
      rawToolsJSON: rawToolsJSON,
      hasResponseFormat: ServeMessages.parseResponseFormat(body["response_format"] as? [String: Any])
        != nil,
      prefixData: prefixData
    )
  }

  private static func resolveThinking(body: [String: Any], defaultValue: Bool) -> Bool {
    if let kwargs = body["chat_template_kwargs"] as? [String: Any],
      let flag = kwargs["enable_thinking"] as? Bool
    {
      return flag
    }
    if let flag = body["enable_thinking"] as? Bool { return flag }
    if let effort = body["reasoning_effort"] as? String {
      let lowered = effort.lowercased()
      return lowered != "none" && lowered != "off"
    }
    return defaultValue
  }

  private static func parseStopStrings(_ raw: Any?) -> [String] {
    if let single = raw as? String, !single.isEmpty { return [single] }
    if let list = raw as? [String] { return list.filter { !$0.isEmpty } }
    return []
  }

  private static func createConversation(
    engine: Engine, request: CompletionRequest, visualTokenBudget: Int32
  ) async throws -> Conversation {
    let prefixMessages =
      (try? JSONSerialization.jsonObject(with: request.prefixData)) as? [[String: Any]] ?? []
    let (systemMessage, initialMessages) = ServeMessages.translatePrefix(
      prefixMessages, visualTokenBudget: visualTokenBudget)
    let sampler = try SamplerConfig(
      topK: max(1, request.topK),
      topP: min(max(request.topP, 0), 1),
      temperature: max(0, request.temperature),
      seed: request.seed
    )
    let config = ConversationConfig(
      systemMessage: systemMessage,
      initialMessages: initialMessages,
      tools: [],
      samplerConfig: sampler,
      thinkingConfig: ThinkingConfig(
        enableThinking: request.enableThinking, thinkingTokenBudget: request.thinkingBudget),
      automaticToolCalling: false,
      enableResponseFormat: request.hasResponseFormat,
      visualTokenBudget: visualTokenBudget,
      enableSpeculativeDecoding: request.useMTP,
      rawToolsJSON: request.rawToolsJSON
    )
    return try await engine.createConversation(with: config)
  }

  static func errorResponse(
    status: Int, message: String, type: String = "server_error"
  ) -> (Int, Data) {
    let payload: [String: Any] = ["error": ["message": message, "type": type]]
    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    return (status, data)
  }
}
