import Foundation
import LiteRTLM

/// Embeddings endpoint and OpenAI completion response formatting for `agello serve`.
extension ServeProtocol {
  struct CompletionEnvelope {
    let id: String
    let created: Int
    let model: String
    let message: [String: Any]
    let finishReason: String
    let usage: [String: Any]
  }

  static func runEmbeddings(embedder: CoreAIEmbedder, requestData: Data) async -> (Int, Data) {
    guard let body = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any] else {
      return errorResponse(status: 400, message: "Expected JSON body for /v1/embeddings.")
    }
    let inputs: [String]
    if let single = body["input"] as? String {
      inputs = [single]
    } else if let list = body["input"] as? [String] {
      inputs = list
    } else {
      return errorResponse(status: 400, message: "Expected 'input' string or string array.")
    }
    let task = (body["task"] as? String ?? "search").lowercased()
    let titles = body["titles"] as? [String] ?? []

    do {
      let vectors: [[Float]]
      if task == "document" {
        let docs = inputs.enumerated().map { idx, text in
          (title: idx < titles.count ? titles[idx] : "", text: text)
        }
        vectors = try await embedder.embed(documents: docs)
      } else {
        let queryTask: EmbeddingQueryTask = task == "code" ? .code : .search
        var out: [[Float]] = []
        out.reserveCapacity(inputs.count)
        for text in inputs {
          out.append(try await embedder.embed(query: text, task: queryTask))
        }
        vectors = out
      }
      let rows: [[String: Any]] = vectors.enumerated().map { idx, vec in
        ["object": "embedding", "index": idx, "embedding": vec]
      }
      let payload: [String: Any] = [
        "object": "list",
        "data": rows,
        "model": embedder.identifier,
        "dimensions": embedder.dimensions,
      ]
      let data = try JSONSerialization.data(withJSONObject: payload)
      return (200, data)
    } catch {
      return errorResponse(status: 500, message: "Embeddings failed: \(error)")
    }
  }

  static func makeStreamDelta(
    chunk: LiteRTLM.Message, enableThinking: Bool
  ) -> [String: Any]? {
    let text = chunk.toString
    let thought = chunk.channels["thought"] ?? ""
    var delta: [String: Any] = [:]
    if enableThinking {
      if !thought.isEmpty {
        delta["reasoning"] = thought
        delta["reasoning_content"] = thought
      }
      if !text.isEmpty { delta["content"] = text }
    } else {
      let combined = thought.isEmpty ? text : (thought + text)
      if !combined.isEmpty { delta["content"] = combined }
    }
    return delta.isEmpty ? nil : delta
  }

  static func buildEnvelope(
    reply: LiteRTLM.Message,
    request: CompletionRequest,
    context: ExecutionContext,
    counts: (prompt: Int, completion: Int, cap: Int)
  ) -> CompletionEnvelope {
    let rawThought = reply.channels["thought"] ?? ""
    let (trimmedContent, matchedStop) = applyStopStrings(
      reply.toString, stopStrings: request.stopStrings)
    let openAIToolCalls = formatToolCalls(
      reply.toolCalls, requestIndex: context.requestIndex, includeIndex: false)

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

  static func applyStopStrings(_ text: String, stopStrings: [String]) -> (String, String?) {
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

  static func formatToolCalls(
    _ toolCalls: [LiteRTLM.ToolCall], requestIndex: Int, includeIndex: Bool
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
      var entry: [String: Any] = [
        "id": call.id.isEmpty ? "call_\(requestIndex)_\(idx)" : call.id,
        "type": "function",
        "function": ["name": call.name, "arguments": argsString],
      ]
      if includeIndex { entry["index"] = idx }
      return entry
    }
  }

  static func serializeResponse(envelope: CompletionEnvelope) -> (Int, String, Data) {
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

  static func logTurn(
    context: ExecutionContext, envelope: CompletionEnvelope, prepared: PreparedTurn,
    out: Int, elapsed: Double
  ) {
    let toolCount = (envelope.message["tool_calls"] as? [[String: Any]])?.count ?? 0
    note(
      String(
        format: "[#%d] in=%d out=%d tools=%d think=%@ finish=%@ %.2fs",
        context.requestIndex, prepared.promptTokens, out, toolCount,
        prepared.request.enableThinking ? "on" : "off", envelope.finishReason, elapsed)
    )
  }
}
