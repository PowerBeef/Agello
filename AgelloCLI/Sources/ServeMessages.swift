import Foundation
import LiteRTLM

/// OpenAI chat message, tool-call/tool-response, multimodal media, and `response_format`
/// translation helpers used by `ServeProtocol`.
enum ServeMessages {
  /// Splits raw OpenAI messages into `(prefixMessages, finalMessageBatch, toolNameByID)`.
  /// Consecutive trailing `role == "tool"` messages are grouped into a single final batch.
  static func splitMessages(
    _ rawMessages: [[String: Any]]
  ) -> ([[String: Any]], [[String: Any]], [String: String]) {
    let toolNameByID = indexToolNames(rawMessages)
    guard let last = rawMessages.last else { return ([], [], toolNameByID) }
    if (last["role"] as? String ?? "user").lowercased() == "tool" {
      var idx = rawMessages.count - 1
      while idx > 0 && (rawMessages[idx - 1]["role"] as? String ?? "").lowercased() == "tool" {
        idx -= 1
      }
      return (Array(rawMessages[..<idx]), Array(rawMessages[idx...]), toolNameByID)
    }
    return (Array(rawMessages.dropLast()), [last], toolNameByID)
  }

  static func buildFinalMessage(
    _ batch: [[String: Any]], toolNameByID: [String: String], visualTokenBudget: Int32
  ) -> (LiteRTLM.Message, Int) {
    if (batch.first?["role"] as? String ?? "").lowercased() == "tool" {
      let items = batch.map { makeToolResponseContent($0, toolNameByID: toolNameByID) }
      return (LiteRTLM.Message(contents: items, role: .tool), 0)
    }
    let (contents, estimate) = extractMultimodalContents(
      batch[0]["content"], visualTokenBudget: visualTokenBudget)
    let safeContents: [LiteRTLM.Content] = contents.isEmpty ? [.text("")] : contents
    return (LiteRTLM.Message(contents: safeContents, role: .user), estimate)
  }

  static func translatePrefix(
    _ rawMessages: [[String: Any]], visualTokenBudget: Int32
  ) -> (LiteRTLM.Message?, [LiteRTLM.Message]) {
    let (systemMessage, nonSystem) = splitSystemPrefix(rawMessages)
    var toolNameByID: [String: String] = [:]
    var converted: [LiteRTLM.Message] = []
    var pendingTools: [LiteRTLM.Content] = []

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
        if let modelMsg = buildAssistantMessage(msg, toolNameByID: &toolNameByID) {
          converted.append(modelMsg)
        }
      } else {
        let (contents, _) = extractMultimodalContents(
          msg["content"], visualTokenBudget: visualTokenBudget)
        converted.append(
          LiteRTLM.Message(contents: contents.isEmpty ? [.text("")] : contents, role: .user))
      }
    }
    flushTools()
    return (systemMessage, converted)
  }

  static func estimateMediaTokens(
    _ messages: [[String: Any]], visualTokenBudget: Int32
  ) -> Int {
    messages.reduce(0) { total, msg in
      total + extractMultimodalContents(msg["content"], visualTokenBudget: visualTokenBudget).1
    }
  }

  static func parseResponseFormat(_ dict: [String: Any]?) -> ResponseFormat? {
    guard let dict, let type = (dict["type"] as? String)?.lowercased() else { return nil }
    if type == "json_schema",
      let wrapper = dict["json_schema"] as? [String: Any],
      let schema = wrapper["schema"] as? [String: Any]
    {
      return try? ResponseFormat.json(schema: schema)
    }
    if type == "json_object" {
      return try? ResponseFormat.json(schema: "{\"type\":\"object\"}")
    }
    return nil
  }

  // MARK: - Private helpers

  private static func indexToolNames(_ messages: [[String: Any]]) -> [String: String] {
    var map: [String: String] = [:]
    for msg in messages {
      guard let rawCalls = msg["tool_calls"] as? [[String: Any]] else { continue }
      for tc in rawCalls {
        if let id = tc["id"] as? String, !id.isEmpty,
          let fn = tc["function"] as? [String: Any],
          let name = fn["name"] as? String
        {
          map[id] = name
        }
      }
    }
    return map
  }

  private static func splitSystemPrefix(
    _ rawMessages: [[String: Any]]
  ) -> (LiteRTLM.Message?, [[String: Any]]) {
    var systemParts: [String] = []
    var rest: [[String: Any]] = []
    for msg in rawMessages {
      let role = (msg["role"] as? String ?? "user").lowercased()
      if (role == "system" || role == "developer") && rest.isEmpty {
        let text = extractTextOnly(msg["content"])
        if !text.isEmpty { systemParts.append(text) }
      } else {
        rest.append(msg)
      }
    }
    let systemMsg =
      systemParts.isEmpty
      ? nil : LiteRTLM.Message(systemParts.joined(separator: "\n\n"), role: .system)
    return (systemMsg, rest)
  }

  private static func buildAssistantMessage(
    _ msg: [String: Any], toolNameByID: inout [String: String]
  ) -> LiteRTLM.Message? {
    var toolCalls: [LiteRTLM.ToolCall] = []
    if let rawCalls = msg["tool_calls"] as? [[String: Any]] {
      for tc in rawCalls {
        guard let fn = tc["function"] as? [String: Any], let name = fn["name"] as? String else {
          continue
        }
        let safeName = PromptText.neutralized(name)
        let id = (tc["id"] as? String) ?? ""
        if !id.isEmpty { toolNameByID[id] = safeName }
        toolCalls.append(
          LiteRTLM.ToolCall(name: safeName, id: id, arguments: parseArgumentsDict(fn["arguments"])))
      }
    }
    let text = extractTextOnly(msg["content"])
    let contents: [LiteRTLM.Content] = text.isEmpty ? [] : [.text(text)]
    guard !contents.isEmpty || !toolCalls.isEmpty else { return nil }
    return LiteRTLM.Message(contents: contents, role: .model, toolCalls: toolCalls)
  }

  private static func parseArgumentsDict(_ raw: Any?) -> [String: Any] {
    if let dict = raw as? [String: Any] {
      return (neutralizeJSONValue(dict) as? [String: Any]) ?? dict
    }
    if let str = raw as? String,
      let data = str.data(using: .utf8),
      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    {
      return (neutralizeJSONValue(dict) as? [String: Any]) ?? dict
    }
    return [:]
  }

  private static func makeToolResponseContent(
    _ msg: [String: Any], toolNameByID: [String: String]
  ) -> LiteRTLM.Content {
    let callID = (msg["tool_call_id"] as? String) ?? ""
    let explicitName = (msg["name"] as? String) ?? ""
    let resolvedName = explicitName.isEmpty ? (toolNameByID[callID] ?? "unknown") : explicitName
    return .toolResponse(
      name: PromptText.neutralized(resolvedName),
      response: parseToolResponseValue(msg["content"]),
      id: callID)
  }

  private static func parseToolResponseValue(_ rawContent: Any?) -> Any {
    if let str = rawContent as? String {
      if let data = str.data(using: .utf8),
        let parsed = try? JSONSerialization.jsonObject(with: data)
      {
        return neutralizeJSONValue(parsed)
      }
      return PromptText.neutralized(str)
    }
    if let rawContent, !(rawContent is NSNull) { return neutralizeJSONValue(rawContent) }
    return ""
  }

  private static func neutralizeJSONValue(_ value: Any) -> Any {
    if let str = value as? String { return PromptText.neutralized(str) }
    if let dict = value as? [String: Any] {
      var out: [String: Any] = [:]
      out.reserveCapacity(dict.count)
      for (key, val) in dict {
        out[PromptText.neutralized(key)] = neutralizeJSONValue(val)
      }
      return out
    }
    if let arr = value as? [Any] {
      return arr.map(neutralizeJSONValue)
    }
    return value
  }

  private static func extractTextOnly(_ raw: Any?) -> String {
    if let s = raw as? String { return PromptText.neutralized(s) }
    guard let parts = raw as? [[String: Any]] else { return "" }
    return parts.compactMap { part -> String? in
      guard (part["type"] as? String) == "text", let text = part["text"] as? String else {
        return nil
      }
      return PromptText.neutralized(text)
    }.joined(separator: "\n")
  }

  private static func extractMultimodalContents(
    _ raw: Any?, visualTokenBudget: Int32
  ) -> ([LiteRTLM.Content], Int) {
    if let s = raw as? String { return ([.text(PromptText.neutralized(s))], 0) }
    guard let parts = raw as? [[String: Any]] else { return ([], 0) }

    var items: [LiteRTLM.Content] = []
    var mediaEstimate = 0
    for part in parts {
      switch (part["type"] as? String ?? "").lowercased() {
      case "text":
        if let text = part["text"] as? String, !text.isEmpty {
          items.append(.text(PromptText.neutralized(text)))
        }
      case "image_url", "image":
        if let data = extractImageBytes(part) {
          items.append(.imageData(data))
          mediaEstimate += Int(visualTokenBudget)
        }
      case "input_audio", "audio":
        if let data = extractAudioBytes(part) {
          items.append(.audioData(data))
          mediaEstimate += max(32, data.count / 1280)
        }
      default:
        break
      }
    }
    // Preserve exact caller part ordering (matches OpenAI / Gemma 4 jinja `for item in content`).
    return (items, mediaEstimate)
  }

  private static func extractImageBytes(_ part: [String: Any]) -> Data? {
    let urlStr: String?
    if let obj = part["image_url"] as? [String: Any] {
      urlStr = obj["url"] as? String
    } else {
      urlStr = (part["image_url"] as? String) ?? (part["url"] as? String)
    }
    return urlStr.flatMap(decodeDataURIOrBase64)
  }

  private static func extractAudioBytes(_ part: [String: Any]) -> Data? {
    let b64: String?
    if let obj = part["input_audio"] as? [String: Any] {
      b64 = obj["data"] as? String
    } else {
      b64 = (part["data"] as? String) ?? (part["blob"] as? String)
    }
    return b64.flatMap(decodeDataURIOrBase64)
  }

  private static func decodeDataURIOrBase64(_ value: String) -> Data? {
    let payload: String
    if let comma = value.firstIndex(of: ","), value.hasPrefix("data:") {
      payload = String(value[value.index(after: comma)...])
    } else {
      payload = value
    }
    return Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
  }
}
