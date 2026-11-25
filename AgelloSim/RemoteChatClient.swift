import Foundation

/// HTTP/SSE wire client talking to `agello serve` (`127.0.0.1`) for `AgelloSim`.
enum RemoteChatClient {
  struct HealthInfo: Sendable {
    let modelID: String
    let kvTokens: Int
    let hasEmbeddings: Bool
    let buildID: String
  }

  struct ToolCallItem: Sendable {
    let id: String
    let name: String
    let argumentsJSON: String
  }

  struct StreamResult: Sendable {
    let assistantText: String
    let toolCalls: [ToolCallItem]
    let finishReason: String
    let promptTokens: Int?
    let completionTokens: Int?
  }

  static func resolveBaseURL() -> URL {
    let env = ProcessInfo.processInfo.environment
    let args = ProcessInfo.processInfo.arguments
    if let idx = args.firstIndex(of: "--remote-engine"), idx + 1 < args.count,
      let url = normalizeURL(args[idx + 1])
    {
      return url
    }
    if let raw = env["AGELLO_REMOTE_ENGINE_URL"], let url = normalizeURL(raw) {
      return url
    }
    return URL(string: "http://127.0.0.1:8091/v1")!
  }

  private static func normalizeURL(_ raw: String) -> URL? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return nil }
    return url.path.hasSuffix("/v1") ? url : url.appendingPathComponent("v1")
  }

  static func checkHealth(baseURL: URL) async throws -> HealthInfo {
    var request = URLRequest(url: baseURL.appendingPathComponent("health"))
    request.timeoutInterval = 5
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await URLSession.shared.data(for: request)
    } catch {
      throw ChatError.underlying(
        message:
          "Cannot reach agello serve at \(baseURL.absoluteString). Start it on your Mac with scripts/sim-launch.sh."
      )
    }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      throw ChatError.underlying(message: "agello serve returned an unexpected health response.")
    }
    return HealthInfo(
      modelID: (json["model"] as? String) ?? "google/gemma-4-E4B-it",
      kvTokens: (json["kv"] as? Int) ?? 65_536,
      hasEmbeddings: (json["embeddings"] as? Bool) ?? false,
      buildID: (json["build"] as? String) ?? "unknown"
    )
  }

  static func completeJSON(baseURL: URL, payloadData: Data) async throws -> String {
    var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 180
    request.httpBody = payloadData

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw ChatError.underlying(message: parseErrorMessage(data: data, response: response))
    }
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let choices = json["choices"] as? [[String: Any]],
      let message = choices.first?["message"] as? [String: Any]
    else {
      throw ChatError.underlying(message: "Malformed completion response from agello serve.")
    }
    return (message["content"] as? String) ?? ""
  }

  static func streamCompletion(
    baseURL: URL,
    payloadData: Data,
    onDelta: @Sendable (String, String?) -> Void
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
      throw ChatError.underlying(message: parseErrorMessage(data: errData, response: response))
    }

    var state = StreamAccumulator()
    for try await line in bytes.lines {
      try Task.checkCancellation()
      guard line.hasPrefix("data: ") else { continue }
      let payload = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
      if payload == "[DONE]" { break }
      try state.consume(jsonLine: payload, onDelta: onDelta)
    }
    return state.finalize()
  }

  private struct StreamAccumulator {
    var assistantText = ""
    var finishReason = "stop"
    var promptTokens: Int?
    var completionTokens: Int?
    var pendingTools: [Int: (id: String, name: String, args: String)] = [:]

    mutating func consume(
      jsonLine: String, onDelta: @Sendable (String, String?) -> Void
    ) throws {
      guard let data = jsonLine.data(using: .utf8),
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      else { return }
      if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
        throw ChatError.underlying(message: msg)
      }
      if let usage = obj["usage"] as? [String: Any] {
        promptTokens = usage["prompt_tokens"] as? Int
        completionTokens = usage["completion_tokens"] as? Int
      }
      guard let choice = (obj["choices"] as? [[String: Any]])?.first else { return }
      if let reason = choice["finish_reason"] as? String { finishReason = reason }
      guard let delta = choice["delta"] as? [String: Any] else { return }

      let textDelta = (delta["content"] as? String) ?? ""
      let thoughtDelta = (delta["reasoning"] as? String) ?? (delta["reasoning_content"] as? String)
      if !textDelta.isEmpty || (thoughtDelta != nil && !(thoughtDelta?.isEmpty ?? true)) {
        assistantText += textDelta
        onDelta(textDelta, thoughtDelta)
      }
      if let toolDeltas = delta["tool_calls"] as? [[String: Any]] {
        for item in toolDeltas { consumeToolDelta(item) }
      }
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

    func finalize() -> StreamResult {
      let calls = pendingTools.keys.sorted().compactMap { idx -> ToolCallItem? in
        guard let item = pendingTools[idx], !item.name.isEmpty else { return nil }
        return ToolCallItem(
          id: item.id.isEmpty ? "call_\(idx)" : item.id,
          name: item.name,
          argumentsJSON: item.args.isEmpty ? "{}" : item.args
        )
      }
      return StreamResult(
        assistantText: assistantText,
        toolCalls: calls,
        finishReason: finishReason,
        promptTokens: promptTokens,
        completionTokens: completionTokens
      )
    }
  }

  private static func parseErrorMessage(data: Data, response: URLResponse) -> String {
    if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let err = json["error"] as? [String: Any],
      let msg = err["message"] as? String
    {
      return msg
    }
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    return "agello serve HTTP \(code)"
  }
}
