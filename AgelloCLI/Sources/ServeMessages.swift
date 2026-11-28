import AVFoundation
import CoreFoundation
import Foundation
import LiteRTLM

/// Canonical message representation for single-session prefix-KV cache matching in `agello serve`.
struct ServeMessage: Equatable, Sendable {
  enum Role: String, Equatable, Sendable { case system, user, assistant, tool }
  enum Part: Equatable, Sendable { case text(String), image(Data), audio(Data) }

  struct ToolCallItem: Equatable, Sendable {
    let id, name, canonicalArgumentsJSON: String
  }

  let role: Role
  let parts: [Part]
  let toolCalls: [ToolCallItem]
  let toolCallID, toolName: String

  init(role: Role, parts: [Part] = [], toolCalls: [ToolCallItem] = [], toolCallID: String = "", toolName: String = "") {
    self.role = role
    self.parts = parts
    self.toolCalls = toolCalls
    self.toolCallID = toolCallID
    self.toolName = toolName
  }
}

/// Session-level configuration that must remain invariant to reuse a warm `Conversation`'s KV cache.
struct ServeSessionConfig: Equatable, Sendable {
  let systemPrompt, toolsSignature: String
  let enableThinking, useMTP, hasResponseFormat: Bool
  let topK, seed: Int
  let topP, temperature: Float
}

/// Outcome of comparing an incoming OpenAI `messages` array against the retained warm session.
enum ServePrefixMatch: Equatable, Sendable {
  case reuse(delta: [ServeMessage])
  case rebuild(reason: String)
}

/// OpenAI chat message, tool-call/tool-response, multimodal media, prefix-KV matching, and
/// `response_format` translation helpers used by `ServeProtocol`.
enum ServeMessages {
  static func splitMessages(_ rawMessages: [[String: Any]]) -> ([[String: Any]], [[String: Any]], [String: String]) {
    let toolNameByID = indexToolNames(rawMessages)
    guard let last = rawMessages.last else { return ([], [], toolNameByID) }
    if (last["role"] as? String ?? "user").lowercased() == "tool" {
      var idx = rawMessages.count - 1
      while idx > 0 && (rawMessages[idx - 1]["role"] as? String ?? "").lowercased() == "tool" { idx -= 1 }
      return (Array(rawMessages[..<idx]), Array(rawMessages[idx...]), toolNameByID)
    }
    return (Array(rawMessages.dropLast()), [last], toolNameByID)
  }

  static func buildFinalMessage(
    _ batch: [[String: Any]], toolNameByID: [String: String], visualTokenBudget: Int32
  ) -> (LiteRTLM.Message, Int) {
    if (batch.first?["role"] as? String ?? "").lowercased() == "tool" {
      return (LiteRTLM.Message(contents: batch.map { makeToolResponseContent($0, toolNameByID: toolNameByID) }, role: .tool), 0)
    }
    let (contents, estimate) = extractMultimodalContents(batch[0]["content"], visualTokenBudget: visualTokenBudget)
    return (LiteRTLM.Message(contents: contents.isEmpty ? [.text("")] : contents, role: .user), estimate)
  }

  static func buildDeltaMessage(_ delta: [ServeMessage], visualTokenBudget: Int32) -> (LiteRTLM.Message, Int) {
    if delta.first?.role == .tool {
      let items: [LiteRTLM.Content] = delta.map { msg in
        let rawText: String = if case .text(let t)? = msg.parts.first { t } else { "" }
        return .toolResponse(name: msg.toolName.isEmpty ? "unknown" : msg.toolName, response: parseToolResponseValue(rawText), id: msg.toolCallID)
      }
      return (LiteRTLM.Message(contents: items, role: .tool), 0)
    }
    let parts = delta.first?.parts ?? [], contents = partsToContents(parts)
    let mediaEstimate = parts.reduce(0) { sum, part in
      switch part {
      case .text: return sum
      case .image: return sum + Int(visualTokenBudget)
      case .audio(let data): return sum + estimateAudioTokens(data)
      }
    }
    return (LiteRTLM.Message(contents: contents.isEmpty ? [.text("")] : contents, role: .user), mediaEstimate)
  }

  static func translatePrefix(
    _ rawMessages: [[String: Any]], visualTokenBudget: Int32
  ) -> (LiteRTLM.Message?, [LiteRTLM.Message]) {
    let (systemMessage, nonSystem) = splitSystemPrefix(rawMessages)
    var toolNameByID: [String: String] = [:], converted: [LiteRTLM.Message] = [], pendingTools: [LiteRTLM.Content] = []
    func flushTools() {
      guard !pendingTools.isEmpty else { return }
      converted.append(LiteRTLM.Message(contents: pendingTools, role: .tool))
      pendingTools.removeAll()
    }
    for msg in nonSystem {
      let role = (msg["role"] as? String ?? "user").lowercased()
      if role == "tool" {
        pendingTools.append(makeToolResponseContent(msg, toolNameByID: toolNameByID))
        continue
      }
      flushTools()
      if role == "assistant" || role == "model" {
        if let modelMsg = buildAssistantMessage(msg, toolNameByID: &toolNameByID) { converted.append(modelMsg) }
      } else {
        let (contents, _) = extractMultimodalContents(msg["content"], visualTokenBudget: visualTokenBudget)
        converted.append(LiteRTLM.Message(contents: contents.isEmpty ? [.text("")] : contents, role: .user))
      }
    }
    flushTools()
    return (systemMessage, converted)
  }

  static func canonicalSystemPrompt(_ rawMessages: [[String: Any]]) -> String { splitSystemPrefix(rawMessages).0?.toString ?? "" }

  static func canonicalToolsSignature(_ rawTools: [[String: Any]]?) -> String {
    guard let rawTools, !rawTools.isEmpty,
      let data = try? JSONSerialization.data(withJSONObject: rawTools, options: [.sortedKeys])
    else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
  }

  static func canonicalize(_ rawMessages: [[String: Any]]) -> [ServeMessage] {
    let (systemMsg, rest) = splitSystemPrefix(rawMessages)
    var toolNameByID = indexToolNames(rawMessages), result: [ServeMessage] = []
    if let sysText = systemMsg?.toString, !sysText.isEmpty { result.append(ServeMessage(role: .system, parts: [.text(sysText)])) }
    for msg in rest {
      switch (msg["role"] as? String ?? "user").lowercased() {
      case "tool":
        let callID = (msg["tool_call_id"] as? String) ?? "", explicit = (msg["name"] as? String) ?? ""
        let resolved = explicit.isEmpty ? (toolNameByID[callID] ?? "unknown") : explicit
        let responseText = canonicalJSONString(parseToolResponseValue(msg["content"]))
        result.append(.init(role: .tool, parts: [.text(responseText)], toolCallID: callID, toolName: PromptText.neutralized(resolved)))
      case "assistant", "model":
        let calls = canonicalToolCalls(msg["tool_calls"] as? [[String: Any]], toolNameByID: &toolNameByID)
        let text = extractTextOnly(msg["content"])
        result.append(.init(role: .assistant, parts: text.isEmpty ? [] : [.text(text)], toolCalls: calls))
      default:
        let (parts, _) = extractParts(msg["content"], visualTokenBudget: 280)
        result.append(.init(role: .user, parts: parts.isEmpty ? [.text("")] : parts))
      }
    }
    return result
  }

  static func assistantServeMessage(text: String, toolCalls: [LiteRTLM.ToolCall], requestIndex: Int) -> ServeMessage {
    let safeText = PromptText.neutralized(text)
    let items: [ServeMessage.ToolCallItem] = toolCalls.enumerated().map { idx, call in
      let safeName = PromptText.neutralized(call.name), id = call.id.isEmpty ? "call_\(requestIndex)_\(idx)" : call.id
      let normalizedArgs = (neutralizeJSONValue(call.arguments) as? [String: Any]) ?? call.arguments
      return .init(id: id, name: safeName, canonicalArgumentsJSON: canonicalJSONString(normalizedArgs))
    }
    return ServeMessage(role: .assistant, parts: safeText.isEmpty ? [] : [.text(safeText)], toolCalls: items)
  }

  static func matchPrefix(
    cachedMessages: [ServeMessage], cachedConfig: ServeSessionConfig,
    incomingMessages: [ServeMessage], incomingConfig: ServeSessionConfig
  ) -> ServePrefixMatch {
    guard !cachedMessages.isEmpty else { return .rebuild(reason: "empty_cache") }
    guard cachedConfig == incomingConfig else { return .rebuild(reason: "config_changed") }
    guard incomingMessages.count > cachedMessages.count else { return .rebuild(reason: "not_extension") }
    guard Array(incomingMessages.prefix(cachedMessages.count)) == cachedMessages else { return .rebuild(reason: "prefix_mismatch") }
    let delta = Array(incomingMessages.dropFirst(cachedMessages.count))
    guard let lastCached = cachedMessages.last, lastCached.role == .assistant else { return .rebuild(reason: "cached_tail_not_assistant") }
    if delta.count == 1, delta[0].role == .user {
      return lastCached.toolCalls.isEmpty ? .reuse(delta: delta) : .rebuild(reason: "unanswered_tool_calls")
    }
    if !delta.isEmpty, delta.allSatisfy({ $0.role == .tool }) {
      guard !lastCached.toolCalls.isEmpty, delta.count == lastCached.toolCalls.count,
        delta.map(\.toolCallID) == lastCached.toolCalls.map(\.id)
      else { return .rebuild(reason: "tool_response_mismatch") }
      return .reuse(delta: delta)
    }
    return .rebuild(reason: "unsupported_delta")
  }

  static func estimateMediaTokens(_ messages: [[String: Any]], visualTokenBudget: Int32) -> Int {
    messages.reduce(0) { $0 + extractParts($1["content"], visualTokenBudget: visualTokenBudget).1 }
  }

  static func estimateAudioTokens(_ data: Data) -> Int {
    guard !data.isEmpty else { return 0 }
    if let player = try? AVAudioPlayer(data: data), player.duration.isFinite, player.duration > 0 {
      return max(1, Int((player.duration * ContextBudget.audioTokensPerSecond).rounded(.up)))
    }
    if let wavSeconds = parseWAVDurationSeconds(data), wavSeconds > 0 {
      return max(1, Int((wavSeconds * ContextBudget.audioTokensPerSecond).rounded(.up)))
    }
    return max(32, data.count / 320)
  }

  static func parseResponseFormat(_ dict: [String: Any]?) -> ResponseFormat? {
    guard let dict, let type = (dict["type"] as? String)?.lowercased() else { return nil }
    if type == "json_schema", let schema = (dict["json_schema"] as? [String: Any])?["schema"] as? [String: Any] {
      return try? ResponseFormat.json(schema: schema)
    }
    return type == "json_object" ? (try? ResponseFormat.json(schema: "{\"type\":\"object\"}")) : nil
  }
}

// MARK: - Message parsing & neutralization helpers

extension ServeMessages {
  fileprivate static func parseWAVDurationSeconds(_ data: Data) -> Double? {
    guard data.count >= 44,
      String(data: data.subdata(in: 0..<4), encoding: .ascii) == "RIFF",
      String(data: data.subdata(in: 8..<12), encoding: .ascii) == "WAVE"
    else { return nil }
    let byteRate = data.subdata(in: 28..<32).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    return byteRate > 0 ? Double(max(0, data.count - 44)) / Double(byteRate) : nil
  }

  fileprivate static func indexToolNames(_ messages: [[String: Any]]) -> [String: String] {
    var map: [String: String] = [:]
    for msg in messages {
      for tc in (msg["tool_calls"] as? [[String: Any]]) ?? [] {
        if let id = tc["id"] as? String, !id.isEmpty, let name = (tc["function"] as? [String: Any])?["name"] as? String {
          map[id] = PromptText.neutralized(name)
        }
      }
    }
    return map
  }

  fileprivate static func splitSystemPrefix(_ rawMessages: [[String: Any]]) -> (LiteRTLM.Message?, [[String: Any]]) {
    var systemParts: [String] = [], rest: [[String: Any]] = []
    for msg in rawMessages {
      let role = (msg["role"] as? String ?? "user").lowercased()
      if (role == "system" || role == "developer") && rest.isEmpty {
        let text = extractTextOnly(msg["content"])
        if !text.isEmpty { systemParts.append(text) }
      } else {
        rest.append(msg)
      }
    }
    return (systemParts.isEmpty ? nil : LiteRTLM.Message(systemParts.joined(separator: "\n\n"), role: .system), rest)
  }

  fileprivate static func parseRawToolCalls(
    _ rawCalls: [[String: Any]]?, toolNameByID: inout [String: String]
  ) -> [LiteRTLM.ToolCall] {
    (rawCalls ?? []).compactMap { tc in
      guard let fn = tc["function"] as? [String: Any], let name = fn["name"] as? String else { return nil }
      let safeName = PromptText.neutralized(name), id = (tc["id"] as? String) ?? ""
      if !id.isEmpty { toolNameByID[id] = safeName }
      return LiteRTLM.ToolCall(name: safeName, id: id, arguments: parseArgumentsDict(fn["arguments"]))
    }
  }

  fileprivate static func canonicalToolCalls(
    _ rawCalls: [[String: Any]]?, toolNameByID: inout [String: String]
  ) -> [ServeMessage.ToolCallItem] {
    parseRawToolCalls(rawCalls, toolNameByID: &toolNameByID).map {
      .init(id: $0.id, name: $0.name, canonicalArgumentsJSON: canonicalJSONString($0.arguments))
    }
  }

  fileprivate static func buildAssistantMessage(
    _ msg: [String: Any], toolNameByID: inout [String: String]
  ) -> LiteRTLM.Message? {
    let toolCalls = parseRawToolCalls(msg["tool_calls"] as? [[String: Any]], toolNameByID: &toolNameByID)
    let text = extractTextOnly(msg["content"])
    let contents: [LiteRTLM.Content] = text.isEmpty ? [] : [.text(text)]
    return (!contents.isEmpty || !toolCalls.isEmpty)
      ? LiteRTLM.Message(contents: contents, role: .model, toolCalls: toolCalls) : nil
  }

  fileprivate static func parseArgumentsDict(_ raw: Any?) -> [String: Any] {
    if let dict = raw as? [String: Any] { return (neutralizeJSONValue(dict) as? [String: Any]) ?? dict }
    if let str = raw as? String, let data = str.data(using: .utf8),
      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    {
      return (neutralizeJSONValue(dict) as? [String: Any]) ?? dict
    }
    return [:]
  }

  fileprivate static func canonicalJSONString(_ value: Any) -> String {
    if let str = value as? String { return str }
    if JSONSerialization.isValidJSONObject(value),
      let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
      let str = String(data: data, encoding: .utf8)
    {
      return str
    }
    return String(describing: value)
  }

  fileprivate static func makeToolResponseContent(_ msg: [String: Any], toolNameByID: [String: String]) -> LiteRTLM.Content {
    let callID = (msg["tool_call_id"] as? String) ?? "", explicit = (msg["name"] as? String) ?? ""
    let resolvedName = explicit.isEmpty ? (toolNameByID[callID] ?? "unknown") : explicit
    return .toolResponse(name: PromptText.neutralized(resolvedName), response: parseToolResponseValue(msg["content"]), id: callID)
  }

  fileprivate static func parseToolResponseValue(_ rawContent: Any?) -> Any {
    if let str = rawContent as? String {
      if let data = str.data(using: .utf8), let parsed = try? JSONSerialization.jsonObject(with: data) {
        return neutralizeJSONValue(parsed)
      }
      return PromptText.neutralized(str)
    }
    return (rawContent != nil && !(rawContent is NSNull)) ? neutralizeJSONValue(rawContent!) : ""
  }

  fileprivate static func neutralizeJSONValue(_ value: Any) -> Any {
    if let str = value as? String { return PromptText.neutralized(str) }
    if let dict = value as? [String: Any] {
      var out: [String: Any] = [:]
      out.reserveCapacity(dict.count)
      for (key, val) in dict { out[PromptText.neutralized(key)] = neutralizeJSONValue(val) }
      return out
    }
    if let arr = value as? [Any] { return arr.map(neutralizeJSONValue) }
    return value
  }

  fileprivate static func extractTextOnly(_ raw: Any?) -> String {
    if let s = raw as? String { return PromptText.neutralized(s) }
    return ((raw as? [[String: Any]]) ?? []).compactMap { part -> String? in
      guard (part["type"] as? String) == "text", let text = part["text"] as? String else { return nil }
      return PromptText.neutralized(text)
    }.joined(separator: "\n")
  }

  fileprivate static func extractParts(_ raw: Any?, visualTokenBudget: Int32) -> ([ServeMessage.Part], Int) {
    if let s = raw as? String { return ([.text(PromptText.neutralized(s))], 0) }
    guard let parts = raw as? [[String: Any]] else { return ([], 0) }
    var items: [ServeMessage.Part] = [], mediaEstimate = 0
    for part in parts {
      switch (part["type"] as? String ?? "").lowercased() {
      case "text":
        if let text = part["text"] as? String, !text.isEmpty { items.append(.text(PromptText.neutralized(text))) }
      case "image_url", "image":
        if let data = extractImageBytes(part) {
          items.append(.image(data))
          mediaEstimate += Int(visualTokenBudget)
        }
      case "input_audio", "audio":
        if let data = extractAudioBytes(part) {
          items.append(.audio(data))
          mediaEstimate += estimateAudioTokens(data)
        }
      default: break
      }
    }
    return (items, mediaEstimate)
  }

  fileprivate static func partsToContents(_ parts: [ServeMessage.Part]) -> [LiteRTLM.Content] {
    parts.map { part in
      switch part {
      case .text(let t): return .text(t)
      case .image(let d): return .imageData(d)
      case .audio(let d): return .audioData(d)
      }
    }
  }

  fileprivate static func extractMultimodalContents(_ raw: Any?, visualTokenBudget: Int32) -> ([LiteRTLM.Content], Int) {
    let (parts, estimate) = extractParts(raw, visualTokenBudget: visualTokenBudget)
    return (partsToContents(parts), estimate)
  }

  fileprivate static func extractImageBytes(_ part: [String: Any]) -> Data? {
    ((part["image_url"] as? [String: Any])?["url"] as? String ?? (part["image_url"] as? String) ?? (part["url"] as? String))
      .flatMap(decodeDataURIOrBase64)
  }

  fileprivate static func extractAudioBytes(_ part: [String: Any]) -> Data? {
    ((part["input_audio"] as? [String: Any])?["data"] as? String ?? (part["data"] as? String) ?? (part["blob"] as? String))
      .flatMap(decodeDataURIOrBase64)
  }

  fileprivate static func decodeDataURIOrBase64(_ value: String) -> Data? {
    let payload =
      (value.hasPrefix("data:") ? value.firstIndex(of: ",").map { String(value[value.index(after: $0)...]) } : nil)
      ?? value
    return Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
  }
}

// MARK: - OpenAI request parsing, 64-bit integer clamping & streaming stop filter

extension ServeProtocol {
  struct StreamingStopFilter: Sendable {
    let stopStrings: [String]
    private var pending = ""
    private(set) var matchedStop: String?

    init(stopStrings: [String]) { self.stopStrings = stopStrings.filter { !$0.isEmpty } }

    mutating func push(_ delta: String) -> (emitted: String, stopped: Bool) {
      guard !stopStrings.isEmpty else { return (delta, false) }
      if matchedStop != nil { return ("", true) }
      pending += delta
      let (trimmed, matched) = ServeProtocol.applyStopStrings(pending, stopStrings: stopStrings)
      if let matched {
        matchedStop = matched
        pending = ""
        return (trimmed, true)
      }
      let hold = longestPartialPrefixSuffixCount(in: pending)
      guard hold < pending.count else { return ("", false) }
      let split = pending.index(pending.endIndex, offsetBy: -hold)
      defer { pending = String(pending[split...]) }
      return (String(pending[..<split]), false)
    }

    mutating func flush() -> String {
      defer { pending = "" }
      return matchedStop == nil ? pending : ""
    }

    private func longestPartialPrefixSuffixCount(in text: String) -> Int {
      var best = 0
      for stop in stopStrings {
        let maxCheck = min(text.count, max(0, stop.count - 1))
        guard maxCheck > best else { continue }
        if let hit = stride(from: maxCheck, through: best + 1, by: -1).first(where: { stop.hasPrefix(text.suffix($0)) }) {
          best = hit
        }
      }
      return best
    }
  }

  static func makeSessionConfig(request: CompletionRequest, rawMessages: [[String: Any]]) -> ServeSessionConfig {
    ServeSessionConfig(
      systemPrompt: ServeMessages.canonicalSystemPrompt(rawMessages), toolsSignature: request.toolsSignature,
      enableThinking: request.enableThinking, useMTP: request.useMTP, hasResponseFormat: request.hasResponseFormat,
      topK: request.topK, seed: request.seed, topP: request.topP, temperature: request.temperature)
  }

  static func clampedInt(_ raw: Any?, min minValue: Int, max maxValue: Int) -> Int? {
    guard let num = raw as? NSNumber else { return nil }
    let cfNum = num as CFNumber
    if CFGetTypeID(cfNum) == CFBooleanGetTypeID() { return nil }
    if CFNumberIsFloatType(cfNum) {
      let d = num.doubleValue
      guard d.isFinite, d.rounded(.towardZero) == d else { return nil }
      return d >= Double(maxValue) ? maxValue : (d <= Double(minValue) ? minValue : Int(d))
    }
    var int64Val: Int64 = 0
    if CFNumberGetValue(cfNum, .sInt64Type, &int64Val) {
      return Int(Swift.min(Swift.max(int64Val, Int64(minValue)), Int64(maxValue)))
    }
    let d = num.doubleValue
    return d.isFinite ? (d >= Double(maxValue) ? maxValue : (d <= Double(minValue) ? minValue : Int(d))) : nil
  }

  static func parseRequest(body: [String: Any], prefix: [[String: Any]], options: Serve.Options) -> CompletionRequest {
    let enableThinking = resolveThinking(body: body, defaultValue: options.thinkByDefault)
    let temperature = clampedFloat(body["temperature"], defaultValue: 0.0, min: 0.0, max: 100.0)
    let topP = clampedFloat(body["top_p"], defaultValue: temperature <= 0 ? 1.0 : 0.95, min: 0.0, max: 1.0)
    let topK = clampedInt(body["top_k"], min: 1, max: maxClampedTopK) ?? (temperature <= 0 ? 1 : 64)
    let requestedMax =
      clampedInt(body["max_completion_tokens"], min: 1, max: maxClampedTokens)
      ?? clampedInt(body["max_tokens"], min: 1, max: maxClampedTokens) ?? 4_096
    let seed = clampedInt(body["seed"], min: Int(Int32.min), max: Int(Int32.max)) ?? 0
    let explicitThink =
      (body["chat_template_kwargs"] as? [String: Any]).flatMap { clampedInt($0["thinking_budget"], min: 0, max: maxClampedTokens) }
      ?? clampedInt(body["thinking_budget"], min: 0, max: maxClampedTokens)
    let resolvedThink =
      enableThinking ? (explicitThink ?? min(maxClampedTokens, max(min(options.thinkingBudget, maxClampedTokens), requestedMax))) : 0
    let toolsSignature = ServeMessages.canonicalToolsSignature(body["tools"] as? [[String: Any]])
    let prefixData = (try? JSONSerialization.data(withJSONObject: prefix)) ?? Data("[]".utf8)
    return CompletionRequest(
      requestedModel: (body["model"] as? String) ?? options.modelID, toolsSignature: toolsSignature,
      stream: (body["stream"] as? Bool) ?? false, enableThinking: enableThinking,
      useMTP: options.allowMTP && temperature <= 0,
      hasResponseFormat: ServeMessages.parseResponseFormat(body["response_format"] as? [String: Any]) != nil,
      isHelper: (body["agello_helper"] as? Bool) ?? false,
      thinkingBudget: resolvedThink, topK: topK, seed: seed, requestedMax: requestedMax,
      temperature: temperature, topP: topP, stopStrings: parseStopStrings(body["stop"]),
      rawToolsJSON: toolsSignature.isEmpty ? nil : toolsSignature, prefixData: prefixData)
  }

  private static func clampedFloat(_ raw: Any?, defaultValue: Double, min minVal: Double, max maxVal: Double) -> Float {
    guard let num = raw as? NSNumber, CFGetTypeID(num as CFNumber) != CFBooleanGetTypeID() else { return Float(defaultValue) }
    let d = num.doubleValue
    return Float(d.isFinite ? Swift.min(Swift.max(d, minVal), maxVal) : defaultValue)
  }

  private static func resolveThinking(body: [String: Any], defaultValue: Bool) -> Bool {
    if let flag = (body["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool { return flag }
    if let flag = body["enable_thinking"] as? Bool { return flag }
    if let effort = (body["reasoning_effort"] as? String)?.lowercased() { return effort != "none" && effort != "off" }
    return defaultValue
  }

  private static func parseStopStrings(_ raw: Any?) -> [String] {
    if let single = raw as? String, !single.isEmpty { return [single] }
    return ((raw as? [String]) ?? []).filter { !$0.isEmpty }
  }

  static func errorResponse(status: Int, message: String, type: String = "server_error") -> (Int, Data) {
    (status, (try? JSONSerialization.data(withJSONObject: ["error": ["message": message, "type": type]])) ?? Data("{}".utf8))
  }
}
