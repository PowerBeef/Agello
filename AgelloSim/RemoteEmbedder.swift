import Foundation
import LiteRTLMTools

/// Loopback embedder for `AgelloSim`: proxies EmbeddingGemma 2 vector requests to
/// `POST /v1/embeddings` on the host Mac's `agello serve` (backed by `CoreAIEmbedder` on ANE).
actor RemoteEmbedder: TextEmbedder {
  nonisolated let dimensions = EmbeddingGemmaPrompts.outputSize
  nonisolated let identifier = EmbeddingGemmaPrompts.identifier
  nonisolated let relatedThreshold: Float = 0.60
  nonisolated let relatedMargin: Float = 0.07
  nonisolated let usesGPU = false

  private let baseURL: URL

  init(baseURL: URL = RemoteChatClient.resolveBaseURL()) {
    self.baseURL = baseURL
  }

  func embed(documents: [(title: String, text: String)]) async throws -> [[Float]] {
    guard !documents.isEmpty else { return [] }
    let payload: [String: Any] = [
      "input": documents.map(\.text), "titles": documents.map(\.title), "task": "document",
    ]
    return try await fetchVectors(payload: payload, expectedCount: documents.count)
  }

  func embed(query: String) async throws -> [Float] {
    try await embed(query: query, task: .search)
  }

  func embed(query: String, task: EmbeddingQueryTask) async throws -> [Float] {
    let payload: [String: Any] = ["input": query, "task": task == .code ? "code" : "search"]
    let vectors = try await fetchVectors(payload: payload, expectedCount: 1)
    guard let first = vectors.first else {
      throw ChatError.underlying(message: "Remote embeddings returned no vector.")
    }
    return first
  }

  func unload() async {}

  private func fetchVectors(payload: [String: Any], expectedCount: Int) async throws -> [[Float]] {
    var request = URLRequest(url: baseURL.appendingPathComponent("embeddings"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 60
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
      throw ChatError.underlying(message: "Remote embeddings failed: \(msg)")
    }
    return try Self.decodeEmbeddingsResponse(data, expectedCount: expectedCount)
  }

  /// Parses `/v1/embeddings` JSON, sorting rows strictly by `index` (with arrival-order tie-break)
  /// so out-of-order batch vectors never misalign document chunks (`W3-24`).
  nonisolated static func decodeEmbeddingsResponse(
    _ data: Data, expectedCount: Int? = nil
  ) throws -> [[Float]] {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let rows = json["data"] as? [[String: Any]]
    else { throw ChatError.underlying(message: "Malformed /v1/embeddings response.") }
    var indexed: [(index: Int, order: Int, vector: [Float])] = []
    indexed.reserveCapacity(rows.count)
    for (order, row) in rows.enumerated() {
      guard let nums = row["embedding"] as? [NSNumber] else {
        throw ChatError.underlying(message: "Missing embedding vector at row \(order).")
      }
      let vec = try nums.map { n -> Float in
        let f = n.floatValue
        guard f.isFinite else {
          throw ChatError.underlying(message: "Non-finite float in /v1/embeddings response.")
        }
        return f
      }
      let idx = (row["index"] as? Int) ?? (row["index"] as? NSNumber)?.intValue ?? order
      indexed.append((index: idx, order: order, vector: vec))
    }
    indexed.sort { $0.index != $1.index ? $0.index < $1.index : $0.order < $1.order }
    let vectors = indexed.map(\.vector)
    if let expectedCount, vectors.count != expectedCount {
      throw ChatError.underlying(
        message: "Expected \(expectedCount) embeddings, received \(vectors.count).")
    }
    return vectors
  }
}

// MARK: - Verified SSE [DONE], /v1/tokenize, /v1/reset & Simulator tool execution

extension RemoteChatClient {
  static func tokenizeText(baseURL: URL, text: String) async -> Int? {
    guard let body = try? JSONSerialization.data(withJSONObject: ["text": text]) else { return nil }
    return await tokenizePayload(baseURL: baseURL, payloadData: body)
  }

  static func makeTokenizePayloadData(
    messages: [[String: Any]], tools: [[String: Any]], enableThinking: Bool
  ) -> Data? {
    var payload: [String: Any] = ["messages": messages, "thinking": enableThinking]
    if !tools.isEmpty { payload["tools"] = tools }
    guard JSONSerialization.isValidJSONObject(payload) else { return nil }
    return try? JSONSerialization.data(withJSONObject: payload)
  }

  static func tokenizePayload(baseURL: URL, payloadData: Data) async -> Int? {
    var request = URLRequest(url: baseURL.appendingPathComponent("tokenize"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 10
    request.httpBody = payloadData
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      let http = response as? HTTPURLResponse, http.statusCode == 200,
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let tokens = (json["tokens"] as? Int) ?? (json["count"] as? Int)
    else { return nil }
    return max(0, tokens)
  }

  static func resetSession(baseURL: URL) async {
    var request = URLRequest(url: baseURL.appendingPathComponent("reset"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 5
    request.httpBody = Data("{}".utf8)
    _ = try? await URLSession.shared.data(for: request)
  }

  static func streamVerifiedCompletion(
    baseURL: URL, payloadData: Data, onDelta: @Sendable (String, String?) -> Void
  ) async throws -> StreamResult {
    var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 600
    request.httpBody = payloadData

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
      var errData = Data()
      for try await byte in bytes { errData.append(byte) }
      throw ChatError.underlying(message: decodeHTTPError(data: errData, response: response))
    }

    var parser = VerifiedSSEAccumulator()
    for try await line in bytes.lines {
      try Task.checkCancellation()
      if try parser.consumeLine(line, onDelta: onDelta) { break }
    }
    try Task.checkCancellation()
    return try parser.finalize()
  }

  struct ToolCallResponseMessage: Sendable {
    let id, name, content: String
    var dictionary: [String: Any] {
      ["role": "tool", "tool_call_id": id, "name": name, "content": content]
    }
  }

  static func executeToolCalls(
    _ calls: [ToolCallItem], using toolManager: ToolManager
  ) async -> [ToolCallResponseMessage] {
    defer { ToolManager.endBatch() }
    if calls.count > 1, calls.allSatisfy({ toolManager.isReadOnly(name: $0.name) }) {
      return await withTaskGroup(of: (Int, ToolCallResponseMessage).self) { group in
        for (idx, call) in calls.enumerated() {
          group.addTask { (idx, await runSingleTool(call, using: toolManager)) }
        }
        var ordered = Array(
          repeating: ToolCallResponseMessage(id: "", name: "", content: ""), count: calls.count)
        for await (idx, msg) in group { ordered[idx] = msg }
        return ordered
      }
    }
    let mutating = calls.enumerated().filter {
      toolManager.isRegistered(name: $0.element.name) && !toolManager.isReadOnly(name: $0.element.name)
    }
    var batchOutcome: BatchConfirmationOutcome?
    if mutating.count > 1 {
      let invocations = mutating.map { idx, call in
        PendingToolInvocation(
          index: idx, name: call.name,
          argumentsJSON: call.argumentsJSON.data(using: .utf8) ?? Data("{}".utf8))
      }
      batchOutcome = await ToolManager.confirmBatch(invocations)
    }
    var results: [ToolCallResponseMessage] = []
    for (idx, call) in calls.enumerated() {
      if toolManager.isRegistered(name: call.name), !toolManager.isReadOnly(name: call.name),
        let outcome = batchOutcome, outcome.skippedByUser.contains(idx)
      {
        results.append(
          ToolCallResponseMessage(
            id: call.id, name: call.name, content: #"{"executed":false,"status":"skipped_by_user"}"#))
        continue
      }
      results.append(await runSingleTool(call, using: toolManager))
    }
    return results
  }

  private static func runSingleTool(
    _ call: ToolCallItem, using toolManager: ToolManager
  ) async -> ToolCallResponseMessage {
    let args =
      call.argumentsJSON.data(using: .utf8).flatMap {
        (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
      } ?? [:]
    let responseValue: Any
    do { responseValue = try await toolManager.execute(name: call.name, arguments: args) } catch {
      responseValue = ["error": error.localizedDescription]
    }
    let contentStr =
      (try? JSONSerialization.data(withJSONObject: responseValue)).flatMap {
        String(data: $0, encoding: .utf8)
      } ?? String(describing: responseValue)
    return ToolCallResponseMessage(id: call.id, name: call.name, content: contentStr)
  }

  static func assistantToolCallMessage(_ result: StreamResult) -> [String: Any] {
    let calls: [[String: Any]] = result.toolCalls.map { call in
      ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.argumentsJSON]]
    }
    return [
      "role": "assistant", "tool_calls": calls,
      "content": result.assistantText.isEmpty ? NSNull() : result.assistantText,
    ]
  }

  static func parseToolSchemas(_ json: String) -> [[String: Any]] {
    guard let data = json.data(using: .utf8),
      let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    else { return [] }
    return arr
  }

  static func promptText(_ text: String, _ imageData: Data?, _ audioFileURL: URL?) -> String {
    if imageData != nil, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Describe this image in detail."
    }
    if !text.isEmpty { return PromptText.neutralized(text) }
    return audioFileURL != nil ? "Listen to this voice message and respond to it." : "Hello!"
  }

  static func formatHistory(
    systemPrompt: String, turns: [(role: ChatRole, text: String)]
  ) -> [[String: Any]] {
    var msgs: [[String: Any]] = []
    if !systemPrompt.isEmpty {
      msgs.append(["role": "system", "content": PromptText.neutralized(systemPrompt)])
    }
    for turn in turns {
      msgs.append([
        "role": turn.role == .user ? "user" : "assistant",
        "content": PromptText.neutralized(turn.text),
      ])
    }
    return msgs
  }

  static func buildUserContent(_ text: String, _ imageData: Data?, _ audioFileURL: URL?) -> Any {
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

  static func buildStreamPayload(
    modelID: String, messages: [[String: Any]], tools: [[String: Any]],
    resolved: ResolvedInference,
    params: (seed: Int?, maxTokens: Int, thinkingBudget: Int?, stopStrings: [String])
  ) throws -> Data {
    let temperature: Double = params.seed != nil ? Double(resolved.temperature) : 0.0
    var templateKwargs: [String: Any] = ["enable_thinking": params.thinkingBudget != nil]
    if let tb = params.thinkingBudget { templateKwargs["thinking_budget"] = tb }
    var payload: [String: Any] = [
      "model": modelID, "messages": messages, "temperature": temperature,
      "top_p": Double(resolved.topP), "top_k": resolved.topK, "seed": params.seed ?? 0,
      "max_tokens": params.maxTokens, "stream": true, "chat_template_kwargs": templateKwargs,
    ]
    if let tb = params.thinkingBudget { payload["thinking_budget"] = tb }
    if !params.stopStrings.isEmpty { payload["stop"] = params.stopStrings }
    if !tools.isEmpty { payload["tools"] = tools }
    return try JSONSerialization.data(withJSONObject: payload)
  }

  private struct VerifiedSSEAccumulator {
    var assistantText = "", finishReason = "stop"
    var promptTokens: Int?, completionTokens: Int?
    var sawDone = false
    var pendingTools: [Int: (id: String, name: String, args: String)] = [:]

    mutating func consumeLine(
      _ line: String, onDelta: @Sendable (String, String?) -> Void
    ) throws -> Bool {
      guard line.hasPrefix("data:") else { return false }
      let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
      if payload == "[DONE]" {
        sawDone = true
        return true
      }
      guard let data = payload.data(using: .utf8),
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else { return false }
      if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
        throw ChatError.underlying(message: msg)
      }
      if let usage = obj["usage"] as? [String: Any] {
        promptTokens = usage["prompt_tokens"] as? Int
        completionTokens = usage["completion_tokens"] as? Int
      }
      guard let choice = (obj["choices"] as? [[String: Any]])?.first else { return false }
      if let reason = choice["finish_reason"] as? String { finishReason = reason }
      guard let delta = choice["delta"] as? [String: Any] else { return false }
      let textDelta = (delta["content"] as? String) ?? ""
      let thoughtDelta = (delta["reasoning"] as? String) ?? (delta["reasoning_content"] as? String)
      if !textDelta.isEmpty || (thoughtDelta != nil && !(thoughtDelta?.isEmpty ?? true)) {
        assistantText += textDelta
        onDelta(textDelta, thoughtDelta)
      }
      if let toolDeltas = delta["tool_calls"] as? [[String: Any]] {
        for item in toolDeltas { consumeToolDelta(item) }
      }
      return false
    }

    private mutating func consumeToolDelta(_ item: [String: Any]) {
      let idx = (item["index"] as? Int) ?? pendingTools.count
      var current = pendingTools[idx] ?? (id: "", name: "", args: "")
      if let id = item["id"] as? String, !id.isEmpty { current.id = id }
      if let fn = item["function"] as? [String: Any] {
        if let name = fn["name"] as? String { current.name += name }
        if let args = fn["arguments"] as? String { current.args += args }
      }
      pendingTools[idx] = current
    }

    func finalize() throws -> StreamResult {
      guard sawDone else {
        throw ChatError.underlying(message: "agello serve stream ended before [DONE].")
      }
      let calls = pendingTools.keys.sorted().compactMap { idx -> ToolCallItem? in
        guard let item = pendingTools[idx], !item.name.isEmpty else { return nil }
        return ToolCallItem(
          id: item.id.isEmpty ? "call_\(idx)" : item.id, name: item.name,
          argumentsJSON: item.args.isEmpty ? "{}" : item.args)
      }
      return StreamResult(
        assistantText: assistantText, toolCalls: calls, finishReason: finishReason,
        promptTokens: promptTokens, completionTokens: completionTokens)
    }
  }

  private static func decodeHTTPError(data: Data, response: URLResponse) -> String {
    if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let err = json["error"] as? [String: Any],
      let msg = err["message"] as? String
    {
      return msg
    }
    return "agello serve HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)"
  }
}

// MARK: - Lock-protected stream trackers

final class RemoteFirstTokenTracker: @unchecked Sendable {
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

final class RemoteEmittedTokenCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes = 0, weight = 0

  func record(textDelta: String, thoughtDelta: String?) {
    var deltaBytes = textDelta.utf8.count
    var deltaWeight = Chunker.weight(of: textDelta)
    if let thoughtDelta, !thoughtDelta.isEmpty {
      deltaBytes += thoughtDelta.utf8.count
      deltaWeight += Chunker.weight(of: thoughtDelta)
    }
    lock.lock()
    bytes += deltaBytes
    weight += deltaWeight
    lock.unlock()
  }

  var estimatedTokens: Int {
    lock.lock()
    let b = bytes, w = weight
    lock.unlock()
    return ContextBudget.estimateTextTokens(bytes: b, weight: w)
  }
}
