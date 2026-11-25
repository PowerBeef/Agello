import Foundation
import LiteRTLM

/// OpenAI `/v1/chat/completions` request execution, KV budgeting, and response/SSE formatting
/// for `agello serve` (`Serve.swift`). Message/multimodal translation lives in `ServeMessages.swift`.
enum ServeProtocol {
  struct ExecutionContext: Sendable {
    let options: Serve.Options
    let allocatedPositions: Int
    let visualTokenBudget: Int32
    let requestIndex: Int
  }

  private struct CompletionRequest: Sendable {
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

  private struct CompletionEnvelope {
    let id: String
    let created: Int
    let model: String
    let message: [String: Any]
    let finishReason: String
    let usage: [String: Any]
  }

  static func runCompletion(
    engine: Engine, context: ExecutionContext, requestData: Data
  ) async -> (Int, String, Data) {
    guard let body = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
      let rawMessages = body["messages"] as? [[String: Any]], !rawMessages.isEmpty
    else {
      let (s, d) = errorResponse(
        status: 400, message: "Request requires a non-empty 'messages' array.")
      return (s, "application/json", d)
    }

    let (prefix, lastRawBatch, toolNameByID) = ServeMessages.splitMessages(rawMessages)
    guard !lastRawBatch.isEmpty else {
      let (s, d) = errorResponse(status: 400, message: "No user or tool message to send.")
      return (s, "application/json", d)
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

      // Exact KV budget check before sending: on a fresh conversation with
      // prefill_preface_on_init == false, renderMessageIntoString(lastMessage)
      // already renders the full preface (system + tools + initialMessages) plus lastMessage.
      let rendered = (try? conversation.renderMessageIntoString(lastMessage)) ?? ""
      let renderedTokens =
        (try? await engine.countTokens(rendered)) ?? ContextBudget.estimateTextTokens(rendered)
      let promptTokens = renderedTokens + 1 + prefixMediaEstimate + lastMediaEstimate
      let availableRoom = context.allocatedPositions - promptTokens - 64
      guard availableRoom > 0 else {
        let (s, d) = errorResponse(
          status: 400,
          message:
            "Prompt (\(promptTokens) tokens) exceeds KV window (\(context.allocatedPositions)).",
          type: "invalid_request_error")
        return (s, "application/json", d)
      }
      let cappedOutput = min(max(1, req.requestedMax), availableRoom)

      let started = ContinuousClock.now
      let reply = try await conversation.sendMessage(
        lastMessage,
        maxOutputTokens: cappedOutput,
        thinkingConfig: ThinkingConfig(
          enableThinking: req.enableThinking, thinkingTokenBudget: req.thinkingBudget),
        responseFormat: responseFormat
      )
      let elapsed = (ContinuousClock.now - started) / .seconds(1)
      let totalKV = (try? conversation.getTokenCount()) ?? promptTokens
      let completionTokens = max(1, totalKV - promptTokens)

      let envelope = buildEnvelope(
        reply: reply,
        request: req,
        context: context,
        counts: (prompt: promptTokens, completion: completionTokens, cap: cappedOutput)
      )
      let toolCount = (envelope.message["tool_calls"] as? [[String: Any]])?.count ?? 0
      note(
        String(
          format: "[#%d] in=%d out=%d tools=%d think=%@ finish=%@ %.2fs",
          context.requestIndex, promptTokens, completionTokens, toolCount,
          req.enableThinking ? "on" : "off", envelope.finishReason, elapsed)
      )
      return serializeResponse(envelope: envelope, stream: req.stream)
    } catch {
      note("[#\(context.requestIndex)] error: \(error)")
      let (s, d) = errorResponse(status: 500, message: "Inference failed: \(error)")
      return (s, "application/json", d)
    }
  }

  // MARK: - Request parsing

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

  // MARK: - Conversation construction (disjoint region for Swift 6 Sendable safety)

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

  // MARK: - Response formatting

  private static func buildEnvelope(
    reply: LiteRTLM.Message,
    request: CompletionRequest,
    context: ExecutionContext,
    counts: (prompt: Int, completion: Int, cap: Int)
  ) -> CompletionEnvelope {
    let rawThought = reply.channels["thought"] ?? ""
    let (trimmedContent, matchedStop) = applyStopStrings(
      reply.toString, stopStrings: request.stopStrings)
    let openAIToolCalls = formatToolCalls(reply.toolCalls, requestIndex: context.requestIndex)

    // Match gbench server-parser policy: when thinking is off, never move output into `reasoning`.
    let finalContent: Any
    let finalReasoning: String?
    if !openAIToolCalls.isEmpty && trimmedContent.isEmpty {
      finalContent = NSNull()
      finalReasoning = (request.enableThinking && !rawThought.isEmpty) ? rawThought : nil
    } else if request.enableThinking {
      finalContent = trimmedContent
      finalReasoning = rawThought.isEmpty ? nil : rawThought
    } else {
      finalContent = rawThought.isEmpty ? trimmedContent : (rawThought + trimmedContent)
      finalReasoning = nil
    }

    var messageObj: [String: Any] = ["role": "assistant", "content": finalContent]
    if let finalReasoning {
      messageObj["reasoning"] = finalReasoning
      messageObj["reasoning_content"] = finalReasoning
    }
    if !openAIToolCalls.isEmpty { messageObj["tool_calls"] = openAIToolCalls }

    let finishReason: String
    if !openAIToolCalls.isEmpty {
      finishReason = "tool_calls"
    } else if matchedStop != nil {
      finishReason = "stop"
    } else if counts.completion >= counts.cap {
      finishReason = "length"
    } else {
      finishReason = "stop"
    }

    let usage: [String: Any] = [
      "prompt_tokens": counts.prompt,
      "completion_tokens": counts.completion,
      "total_tokens": counts.prompt + counts.completion,
    ]
    return CompletionEnvelope(
      id: "chatcmpl-agello-\(context.requestIndex)",
      created: Int(Date().timeIntervalSince1970),
      model: request.requestedModel,
      message: messageObj,
      finishReason: finishReason,
      usage: usage
    )
  }

  private static func applyStopStrings(_ text: String, stopStrings: [String]) -> (String, String?) {
    guard !stopStrings.isEmpty && !text.isEmpty else { return (text, nil) }
    var earliest: String.Index?
    var matched: String?
    for seq in stopStrings {
      if let range = text.range(of: seq), earliest == nil || range.lowerBound < earliest! {
        earliest = range.lowerBound
        matched = seq
      }
    }
    guard let cut = earliest else { return (text, nil) }
    return (String(text[..<cut]), matched)
  }

  private static func formatToolCalls(
    _ toolCalls: [LiteRTLM.ToolCall], requestIndex: Int
  ) -> [[String: Any]] {
    toolCalls.enumerated().map { idx, call in
      let argsString: String
      if let data = try? JSONSerialization.data(
        withJSONObject: call.arguments, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8)
      {
        argsString = text
      } else {
        argsString = "{}"
      }
      return [
        "id": call.id.isEmpty ? "call_\(requestIndex)_\(idx)" : call.id,
        "type": "function",
        "function": ["name": call.name, "arguments": argsString],
      ]
    }
  }

  private static func serializeResponse(
    envelope: CompletionEnvelope, stream: Bool
  ) -> (Int, String, Data) {
    if stream {
      return (200, "text/event-stream", buildSSEResponse(envelope))
    }
    let responseObj: [String: Any] = [
      "id": envelope.id,
      "object": "chat.completion",
      "created": envelope.created,
      "model": envelope.model,
      "choices": [
        [
          "index": 0,
          "message": envelope.message,
          "finish_reason": envelope.finishReason,
        ]
      ],
      "usage": envelope.usage,
    ]
    let data = (try? JSONSerialization.data(withJSONObject: responseObj)) ?? Data("{}".utf8)
    return (200, "application/json", data)
  }

  private static func buildSSEResponse(_ envelope: CompletionEnvelope) -> Data {
    var out = ""
    let deltaChunk: [String: Any] = [
      "id": envelope.id,
      "object": "chat.completion.chunk",
      "created": envelope.created,
      "model": envelope.model,
      "choices": [["index": 0, "delta": envelope.message, "finish_reason": NSNull()]],
    ]
    let finalChunk: [String: Any] = [
      "id": envelope.id,
      "object": "chat.completion.chunk",
      "created": envelope.created,
      "model": envelope.model,
      "choices": [
        ["index": 0, "delta": [:] as [String: Any], "finish_reason": envelope.finishReason]
      ],
      "usage": envelope.usage,
    ]
    for obj in [deltaChunk, finalChunk] {
      if let data = try? JSONSerialization.data(withJSONObject: obj),
        let str = String(data: data, encoding: .utf8)
      {
        out += "data: \(str)\n\n"
      }
    }
    out += "data: [DONE]\n\n"
    return Data(out.utf8)
  }

  static func errorResponse(
    status: Int, message: String, type: String = "server_error"
  ) -> (Int, Data) {
    let payload: [String: Any] = ["error": ["message": message, "type": type]]
    let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    return (status, data)
  }
}
