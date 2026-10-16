import Foundation

/// What the model reads after a web search, query planning, and turning
/// "[1]" markers into links. Pure (unit-tested).
enum WebContext {
  /// Tokens for web results: the share of the window for material (``FileContext/budget``)
  /// less what the chat's files already take, and never under a quarter of it.
  static func budget(window: Int, question: String, alongsideFileTokens fileTokens: Int = 0) -> Int {
    let share = FileContext.budget(window: window, question: question)
    return max(share / 4, share - fileTokens)
  }

  struct Source: Equatable, Sendable {
    var index: Int
    var title: String
    var url: URL
    var passages: [String]

    var domain: String {
      let host = url.host() ?? url.absoluteString
      return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var record: SourceRecord {
      SourceRecord(
        index: index, title: title, url: url.absoluteString,
        snippet: passages.first.map { String($0.prefix(240)) })
    }
  }

  /// The sources block (also the `web_search` tool's result).
  static func sourcesBlock(_ sources: [Source]) -> String {
    let body = sources.map { source in
      "[\(source.index)] \(source.title) — \(source.domain)\n"
        + source.passages.joined(separator: "\n…\n")
    }.joined(separator: "\n\n")
    return "<sources>\n\(body)\n</sources>"
  }

  static func instructions(today: Date = .now) -> String {
    let date = today.formatted(date: .complete, time: .omitted)
    return "You searched the web for the user's question (today is \(date)). Use these sources "
      + "to answer, and cite them with bracketed numbers like [1] or [2][3] right after the facts "
      + "they support. Prefer the most recent information. If the sources don't answer the "
      + "question, say so."
  }

  /// The prompt for an answer from web sources (and attached files, whose
  /// prompt is already built around the question).
  static func prompt(question: String, sources: [Source], filePrompt: String? = nil, today: Date = .now)
    -> String
  {
    let ask = filePrompt ?? "Question: \(question)"
    return [instructions(today: today), sourcesBlock(sources), ask].joined(separator: "\n\n")
  }

  // MARK: Query planning

  static let querySchema =
    #"{"type":"object","properties":{"queries":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":3}},"required":["queries"]}"#
  static let queryMaxOutputTokens = 80

  /// Prompt for 1–3 search queries that resolve a follow-up question.
  static func queryPrompt(
    question: String, history: [(role: ChatRole, text: String)], today: Date = .now
  ) -> String {
    let recent = history.suffix(4).map { turn in
      "\(turn.role == .user ? "User" : "Assistant"): \(ContextBudget.prefix(turn.text, maxBytes: 400))"
    }.joined(separator: "\n")
    return """
      Today is \(today.formatted(date: .complete, time: .omitted)).

      Conversation so far:
      \(recent)

      New question: \(question)

      Write 1 to 3 short web search queries that would find the answer to the new question. \
      Make each query self-contained (resolve names and pronouns from the conversation). Use the \
      language of the question.
      """
  }

  static func parseQueries(_ json: Data) -> [String] {
    guard
      let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
      let queries = object["queries"] as? [String]
    else { return [] }
    var seen = Set<String>()
    return queries.compactMap { raw in
      let query = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
      guard query.count >= 2, seen.insert(query.lowercased()).inserted else { return nil }
      return String(query.prefix(200))
    }.prefix(3).map { $0 }
  }

  /// The search query for a first question (no planning needed).
  static func directQuery(_ question: String) -> String {
    let collapsed = question.components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }.joined(separator: " ")
    return String(collapsed.prefix(200))
  }

  // MARK: Citations

  /// "[1]" markers turned into markdown links to their sources (outside
  /// code); markers without a matching source are left alone.
  static func linkCitations(_ text: String, sources: [SourceRecord]) -> String {
    let urls = Dictionary(
      sources.compactMap { source in source.url.map { (source.index, $0) } },
      uniquingKeysWith: { first, _ in first })
    guard !urls.isEmpty, text.contains("[") else { return text }
    var output = ""
    var inFence = false
    for (lineIndex, line) in text.components(separatedBy: "\n").enumerated() {
      if lineIndex > 0 { output += "\n" }
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
        inFence.toggle()
        output += line
        continue
      }
      if inFence {
        output += line
        continue
      }
      // Leave inline code spans untouched.
      let parts = line.components(separatedBy: "`")
      output += parts.enumerated().map { index, part in
        index.isMultiple(of: 2) ? linkMarkers(part, urls: urls) : part
      }.joined(separator: "`")
    }
    return output
  }

  private static func linkMarkers(_ text: String, urls: [Int: String]) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"\[(\d{1,2})\](?!\()"#) else { return text }
    var output = ""
    var last = text.startIndex
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      guard let range = Range(match.range, in: text), let numberRange = Range(match.range(at: 1), in: text),
        let number = Int(text[numberRange]), let url = urls[number]
      else { continue }
      output += text[last..<range.lowerBound]
      output += "[\\[\(number)\\]](\(url))"
      last = range.upperBound
    }
    return output + text[last...]
  }
}

// MARK: - Research pipeline

/// Search → read pages → rank passages → numbered sources.
@MainActor
final class WebResearch {
  struct Findings: Sendable {
    var sources: [WebContext.Source]
    var queries: [String]
    var provider: SearchProvider?
  }

  /// Pages read per search.
  static let pagesToRead = 5
  /// Passages kept per source.
  static let passagesPerSource = 3

  private let client = WebClient()
  private let knowledge: KnowledgeBase

  init(knowledge: KnowledgeBase) {
    self.knowledge = knowledge
  }

  /// Run `queries` through the provider chain, read the best pages, and keep
  /// the passages most relevant to `question` within `budgetTokens`.
  func research(
    queries: [String], question: String, settings: WebSearchSettings, budgetTokens: Int,
    firstIndex: Int = 1, progress: @MainActor (String) -> Void
  ) async throws -> Findings {
    // 1. Search.
    var results: [[WebResult]] = []
    var usedProvider: SearchProvider?
    var lastError: Error = WebSearchError.noResults
    let chain = settings.chain { SearchKeys.key(for: $0) != nil }
    for query in queries {
      progress(String(localized: "Searching the web for “\(query)”…"))
      for provider in chain {
        do {
          let found = try await client.search(query, with: provider, settings: settings)
          if !found.isEmpty {
            results.append(found)
            usedProvider = usedProvider ?? provider
            break
          }
        } catch {
          lastError = error
          if case WebSearchError.offline = error { throw error }
        }
      }
      try Task.checkCancellation()
    }
    let merged = Self.merge(results)
    guard !merged.isEmpty else { throw lastError }

    // 2. Read the top pages in parallel (snippets stand in for failures).
    let candidates = Array(merged.prefix(Self.pagesToRead))
    progress(String(localized: "Reading \(candidates.count) pages…"))
    let client = self.client
    var pages: [Int: ReadableText.Page] = [:]
    await withTaskGroup(of: (Int, ReadableText.Page?).self) { group in
      for (index, result) in candidates.enumerated() {
        group.addTask { (index, await client.readPage(result.url)) }
      }
      for await (index, page) in group { pages[index] = page }
    }
    try Task.checkCancellation()

    // 3. Rank passages by relevance to the question.
    struct Candidate {
      var result: Int
      var text: String
    }
    var passages: [Candidate] = []
    for (index, result) in candidates.enumerated() {
      if let page = pages[index] {
        for chunk in Chunker.chunks(pages: [page.text], paged: false).prefix(40) {
          passages.append(Candidate(result: index, text: chunk.text))
        }
      }
      if !result.snippet.isEmpty {
        passages.append(Candidate(result: index, text: result.snippet))
      }
    }
    progress(String(localized: "Picking the relevant parts…"))
    let order = await rank(passages.map(\.text), question: question)

    // 4. Keep the best passages within budget; number sources by first use.
    var used = 0
    var perSource: [Int: [String]] = [:]
    var sourceOrder: [Int] = []
    for position in order {
      let passage = passages[position]
      let cost = ContextBudget.estimateTokens(passage.text) + 16
      guard used + cost <= budgetTokens || used == 0 else { continue }
      guard perSource[passage.result, default: []].count < Self.passagesPerSource else { continue }
      if perSource[passage.result] == nil { sourceOrder.append(passage.result) }
      perSource[passage.result, default: []].append(passage.text)
      used += cost
    }
    let sources = sourceOrder.enumerated().map { offset, result in
      WebContext.Source(
        index: firstIndex + offset, title: candidates[result].title, url: candidates[result].url,
        passages: perSource[result] ?? [])
    }
    return Findings(sources: sources, queries: queries, provider: usedProvider)
  }

  /// Results interleaved across queries (best of each first), deduplicated.
  nonisolated static func merge(_ lists: [[WebResult]]) -> [WebResult] {
    var merged: [WebResult] = []
    var seen = Set<String>()
    let longest = lists.map(\.count).max() ?? 0
    for rank in 0..<longest {
      for list in lists where rank < list.count {
        let result = list[rank]
        let key = (result.url.host() ?? "") + result.url.path()
        if seen.insert(key).inserted { merged.append(result) }
      }
    }
    return merged
  }

  /// Indices of `passages`, most relevant first (by meaning when the
  /// embedding model is available, else by keywords).
  private func rank(_ passages: [String], question: String) async -> [Int] {
    guard !passages.isEmpty else { return [] }
    if let embedder = knowledge.currentEmbedder(),
      let query = try? await embedder.embed(query: question),
      let vectors = try? await embedder.embed(documents: passages.map { (title: "none", text: $0) }),
      vectors.count == passages.count
    {
      return VectorIndex.top(passages.count, query: query, candidates: Array(zip(passages.indices, vectors)))
        .map(\.item)
    }
    let scores = KeywordScorer.scores(query: question, documents: passages)
    return passages.indices.sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
  }
}
