import Foundation

/// Small structured jobs run on the chat model between replies (titles now;
/// memory and other helpers later). Pure prompt building and parsing, so it
/// is unit-tested; the engine runs them via
/// ``ChatEngineProtocol/helperJSON(prompt:schemaJSON:maxOutputTokens:)``.
///
/// LiteRT-LM keeps one live conversation per engine: a helper run wipes the
/// main conversation, which the app then rebuilds from history.
enum HelperTasks {
  // MARK: Scheduling

  /// How long a chat must be quiet before its title and memory helpers run. On Google's
  /// LiteRT-LM each helper empties the chat's conversation, so the next message re-reads the
  /// whole chat: wait for a real pause. Ours keeps the conversation, so they can run soon.
  static func idleDelay(keepsConversation: Bool) -> Duration {
    keepsConversation ? .seconds(3) : .seconds(60)
  }

  // MARK: Title

  static let titleSchema =
    #"{"type":"object","properties":{"title":{"type":"string"}},"required":["title"]}"#
  static let titleMaxOutputTokens = 32
  static let maxTitleLength = 48

  static func titlePrompt(user: String, reply: String) -> String {
    """
    Conversation:
    User: \(ContextBudget.prefix(user, maxBytes: 600))
    Assistant: \(ContextBudget.prefix(reply, maxBytes: 600))

    Write a short, specific title (2 to 6 words) for this conversation, in the same language as the conversation. No quotes, no trailing punctuation.
    """
  }

  /// The cleaned title from the model's JSON, or nil if unusable.
  static func parseTitle(_ json: Data) -> String? {
    guard
      let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
      let raw = object["title"] as? String
    else { return nil }
    return cleanTitle(raw)
  }

  static func cleanTitle(_ raw: String) -> String? {
    var title = raw.components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    let wrappers = CharacterSet(charactersIn: "\"'“”‘’«»*#`")
    title = title.trimmingCharacters(in: wrappers.union(.whitespaces))
    while let last = title.last, ".:;!,".contains(last) { title.removeLast() }
    if title.lowercased().hasPrefix("title ") { title = String(title.dropFirst(6)) }
    guard !title.isEmpty else { return nil }
    if title.count > maxTitleLength {
      let cut = title.prefix(maxTitleLength)
      title = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
    }
    return title
  }

  // MARK: Memory

  static let memorySchema =
    #"{"type":"object","properties":{"memories":{"type":"array","items":{"type":"string"},"maxItems":3}},"required":["memories"]}"#
  static let memoryMaxOutputTokens = 96
  static let maxMemoryLength = 120

  /// Only messages about the user can hold facts worth remembering; skips
  /// the helper (and the conversation rebuild it causes) for the rest.
  static func shouldLookForMemories(_ message: String) -> Bool {
    let text = " " + message.lowercased().folding(options: .diacriticInsensitive, locale: nil) + " "
    let cues = [
      " i ", " i'm ", " im ", " i've ", " i'd ", " i'll ", " my ", " me ", " mine ", " myself ",
      "remember", " je ", " j'", " mon ", " ma ", " mes ", " moi ", "souviens", "rappelle",
    ]
    return cues.contains { text.contains($0) }
  }

  /// Instructions first, with examples: measured on device, Gemma otherwise
  /// tends to return an empty list for messages full of facts.
  static func memoryPrompt(user: String, existing: [String]) -> String {
    let known = existing.isEmpty ? "(none)" : existing.prefix(25).map { "- \($0)" }.joined(separator: "\n")
    return """
      You keep a short memory about the user for future conversations.

      Extract lasting facts about the user from their message below: preferences, diet, where \
      they live, work, family, pets, ongoing projects, and anything they ask you to remember. \
      Write each fact as a short phrase, for example "Is vegetarian", "Lives in Montreal", \
      "Has a daughter, Léa (6)". Don't include the request or question itself, or anything \
      temporary. Return an empty list only when the message says nothing lasting about the user.

      Already remembered (don't repeat):
      \(known)

      User's message: "\(ContextBudget.prefix(user, maxBytes: 1_200))"
      """
  }

  /// Cleaned facts from the model's JSON.
  static func parseMemories(_ json: Data) -> [String] {
    guard
      let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
      let raw = object["memories"] as? [String]
    else { return [] }
    return raw.compactMap { item in
      var text = item.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        .joined(separator: " ")
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”-•* ").union(.whitespaces))
      while let last = text.last, ".;,".contains(last) { text.removeLast() }
      guard text.count >= 3 else { return nil }
      return String(text.prefix(maxMemoryLength))
    }
  }

  /// Candidates that aren't (near-)duplicates of existing memories or of
  /// each other: same words, ignoring case, accents and filler words.
  static func newMemories(_ candidates: [String], existing: [String]) -> [String] {
    var kept: [String] = []
    var seenTexts = Set(existing.map { $0.lowercased() })
    var seenTerms = existing.map { Set(KeywordScorer.terms($0)) }.filter { !$0.isEmpty }
    for candidate in candidates {
      guard !seenTexts.contains(candidate.lowercased()) else { continue }
      let terms = Set(KeywordScorer.terms(candidate))
      // Near-identical, or already covered by a more specific memory.
      let duplicate = !terms.isEmpty && seenTerms.contains { other in
        terms.isSubset(of: other)
          || Double(terms.intersection(other).count) / Double(terms.union(other).count) >= 0.75
      }
      guard !duplicate else { continue }
      kept.append(candidate)
      seenTexts.insert(candidate.lowercased())
      if !terms.isEmpty { seenTerms.append(terms) }
    }
    return kept
  }
}
