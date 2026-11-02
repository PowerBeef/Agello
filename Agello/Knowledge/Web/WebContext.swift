import Foundation

/// What the model reads after a web search, query planning, and turning
/// "[1]" markers into links. Pure (unit-tested).
enum WebContext {
  /// Tokens for web results: the share of the window for material (``FileContext/budget``)
  /// less what the chat's files already take, and never under a quarter of it. A request (code,
  /// a plan) takes a third of the window instead of half, leaving more for the work itself.
  static func budget(
    window: Int, question: String, alongsideFileTokens fileTokens: Int = 0, forRequest: Bool = false
  ) -> Int {
    let share =
      forRequest
      ? max(512, window / 3 - ContextBudget.estimateTokens(question))
      : FileContext.budget(window: window, question: question)
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

  /// The sources are reference material for whatever the message asks: framed as a question to
  /// answer from them ("Use these sources to answer… Question:"), a request like "create a
  /// calculator app" came back as a summary of what the pages say (2026-11-02).
  static func instructions(today: Date = .now) -> String {
    let date = today.formatted(date: .complete, time: .omitted)
    return "You searched the web for the user's message (today is \(date)). The sources below are "
      + "reference material: do what the message asks, whether that's answering, writing, coding "
      + "or explaining, as fully as you would without them, and use them where they help. Cite "
      + "them with bracketed numbers like [1] or [2][3] right after the facts you take from them. "
      + "Prefer the most recent information. If the message asks for facts the sources don't "
      + "cover, say so. If the sources don't bear on the message at all, reply as you would "
      + "without them and don't mention them."
  }

  /// The prompt for an answer from web sources (and attached files, whose
  /// prompt is already built around the question).
  static func prompt(question: String, sources: [Source], filePrompt: String? = nil, today: Date = .now)
    -> String
  {
    let ask = filePrompt ?? "Message: \(question)"
    return [instructions(today: today), sourcesBlock(sources), ask].joined(separator: "\n\n")
  }

  // MARK: Query planning

  /// Questions and requests come with 1–3 queries, the other kinds with none: the grammar holds
  /// the model to it. With queries optional, the iPhone named "By how many minutes?" a question
  /// and wrote none, and the message searched as typed found minute calculators.
  static let querySchema =
    #"{"anyOf":[{"type":"object","properties":{"kind":{"type":"string","enum":["chat","reaction","edit","creative","arithmetic","answered"]},"queries":{"type":"array","items":{"type":"string"},"maxItems":0}},"required":["kind","queries"]},"#
    + #"{"type":"object","properties":{"kind":{"type":"string","enum":["question","request"]},"queries":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":3}},"required":["kind","queries"]}]}"#
  static let queryMaxOutputTokens = 100

  /// Kinds of message that search: the rest need nothing from the web. One word each: on our
  /// runtime a space inside an enum value fails the grammar ("Failed to commit token: ▁talk",
  /// the tokenizer's word-start marker read as its own bytes, 2026-11-02).
  static let searchedKinds: Set<String> = ["question", "request"]

  /// What a Search message needs: whether to search at all, the queries, and whether it asks for
  /// something to be made. Search on lets the model search when the message needs it; until
  /// 2026-11-02 every message was searched, and "Hello there" came back as a reasoned reply about
  /// pages on professional greetings. The decision rides the planning call every Search message
  /// already made, so skipping costs nothing and saves the reading and ranking. The planner names
  /// the kind of message and the code decides: asked whether to search, E4B skipped whatever it
  /// thought it could do alone, a SwiftUI request for current APIs and "How do I center a div with
  /// CSS grid?" included (`WebScenarioTests/test04`).
  struct Plan: Equatable, Sendable {
    var queries: [String]
    var isRequest: Bool
    var needsSearch = true
  }

  /// Prompt for the message's kind and 1–3 search queries for what it needs: the facts that
  /// answer a question, or the techniques, APIs and facts that make a request (code, a plan) well,
  /// with room for one complete example. Until 2026-11-02 a first message was searched as typed
  /// (for "create a calculator app": tutorials restating the task); planned for techniques only,
  /// the probe 24 calculators lost the complete examples they had relied on and came back broken.
  static func queryPrompt(
    question: String, history: [(role: ChatRole, text: String)], today: Date = .now
  ) -> String {
    let recent = history.suffix(4).map { turn in
      "\(turn.role == .user ? "User" : "Assistant"): \(ContextBudget.prefix(turn.text, maxBytes: 400))"
    }.joined(separator: "\n")
    let conversation = recent.isEmpty ? "" : "Conversation so far:\n\(recent)\n\n"
    return """
      Today is \(today.formatted(date: .complete, time: .omitted)).

      \(conversation)New message: \(question)

      Give the kind of the new message:
      - chat: a greeting, thanks or small talk
      - reaction: a reaction to the last reply
      - edit: rewriting, translating, summarizing or fixing text given in the conversation
      - creative: a poem or a story
      - arithmetic: a simple calculation
      - answered: a follow-up that the conversation so far already answers
      - question: any other question, of fact or how-to
      - request: a request to write code, build, plan or design something

      For a question or a request, write 1 to 3 short web search queries for what's needed to \
      handle it well; for any other kind, leave queries empty. For a question, search for the \
      facts that answer it. For a request, search for the specific techniques, APIs, \
      specifications or facts needed to do it well; one query may look for a complete, \
      well-regarded example of the whole thing. Make each query self-contained: resolve names and \
      pronouns from the conversation, and give a follow-up the subject it's about (after a \
      question about the newest iPhone, "How much is it?" searches for that iPhone's price). Use \
      the language of the message.
      """
  }

  static func parsePlan(_ json: Data) -> Plan {
    guard
      let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
      let queries = object["queries"] as? [String]
    else { return Plan(queries: [], isRequest: false) }
    let kind = object["kind"] as? String
    if let kind, !searchedKinds.contains(kind) { return Plan(queries: [], isRequest: false, needsSearch: false) }
    var seen = Set<String>()
    let cleaned = queries.compactMap { raw -> String? in
      let query = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
      guard query.count >= 2, seen.insert(query.lowercased()).inserted else { return nil }
      return String(query.prefix(200))
    }.prefix(3).map { $0 }
    return Plan(queries: cleaned, isRequest: kind == "request" || object["request"] as? Bool == true)
  }

  static func parseQueries(_ json: Data) -> [String] {
    parsePlan(json).queries
  }

  /// The search query when planning gave none: the message as typed, after the previous user
  /// message for a follow-up ("By how many minutes?" alone finds minute calculators).
  static func directQuery(_ question: String, history: [(role: ChatRole, text: String)] = []) -> String {
    func collapsed(_ text: String) -> String {
      text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
    let previous = history.last { $0.role == .user }.map { String(collapsed($0.text).prefix(120)) + " " } ?? ""
    return String((previous + collapsed(question)).prefix(200))
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
  /// the passages most relevant to `rankingQueries` (default: `question`) within `budgetTokens`.
  func research(
    queries: [String], question: String, rankingQueries: [String]? = nil,
    settings: WebSearchSettings, budgetTokens: Int,
    firstIndex: Int = 1, progress: @MainActor (String) -> Void
  ) async throws -> Findings {
    // 1. Search, every query at once (each through the provider chain), in query order.
    let chain = settings.chain { SearchKeys.key(for: $0) != nil }
    progress(String(localized: "Searching the web for “\(queries.first ?? question)”…"))
    let client = self.client
    var outcomes: [Int: (results: [WebResult], provider: SearchProvider?, error: Error?)] = [:]
    await withTaskGroup(of: (Int, [WebResult], SearchProvider?, Error?).self) { group in
      for (index, query) in queries.enumerated() {
        group.addTask {
          var lastError: Error?
          for provider in chain {
            do {
              let found = try await client.search(query, with: provider, settings: settings)
              if !found.isEmpty { return (index, found, provider, nil) }
            } catch {
              lastError = error
              if case WebSearchError.offline = error { break }
            }
          }
          return (index, [], nil, lastError)
        }
      }
      for await (index, found, provider, error) in group { outcomes[index] = (found, provider, error) }
    }
    try Task.checkCancellation()
    let errors = queries.indices.compactMap { outcomes[$0]?.error }
    if let offline = errors.first(where: { if case WebSearchError.offline = $0 { true } else { false } }) {
      throw offline
    }
    let results = queries.indices.compactMap { outcomes[$0]?.results }.filter { !$0.isEmpty }
    let usedProvider = queries.indices.lazy.compactMap { outcomes[$0]?.provider }.first
    let lastError: Error = errors.last ?? WebSearchError.noResults
    let merged = Self.merge(results)
    guard !merged.isEmpty else { throw lastError }

    // 2. Read the top pages in parallel (snippets stand in for failures).
    let candidates = Array(merged.prefix(Self.pagesToRead))
    progress(String(localized: "Reading \(candidates.count) pages…"))
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
    let order = await rank(passages.map(\.text), against: rankingQueries ?? [question])

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
  /// Passages embedded per search: the best by keywords. Embedding every passage of five pages
  /// (up to 200) took seconds of GPU time before the reply could start.
  static let passagesToEmbed = 40

  /// Each passage scores its best match among `queries`: a request's needs are several (the
  /// layout, the arithmetic, the viewport), each answered by different pages. One more query
  /// embedding per query; the shortlist embedded stays the same size.
  private func rank(_ passages: [String], against queries: [String]) async -> [Int] {
    guard !passages.isEmpty else { return [] }
    let scores = KeywordScorer.scores(query: queries.joined(separator: " "), documents: passages)
    let byKeywords = passages.indices.sorted {
      scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1
    }
    let shortlist = Array(byKeywords.prefix(Self.passagesToEmbed))
    if let embedder = knowledge.currentEmbedder() {
      var queryVectors: [[Float]] = []
      for query in queries {
        if let vector = try? await embedder.embed(query: query) { queryVectors.append(vector) }
      }
      if !queryVectors.isEmpty,
        let vectors = try? await embedder.embed(
          documents: shortlist.map { (title: "none", text: passages[$0]) }),
        vectors.count == shortlist.count
      {
        // The shortlist by meaning, then the rest by keywords.
        let best = vectors.map { vector in queryVectors.map { VectorIndex.dot($0, vector) }.max() ?? 0 }
        let byMeaning = shortlist.indices.sorted { best[$0] > best[$1] }.map { shortlist[$0] }
        return byMeaning + byKeywords.dropFirst(shortlist.count)
      }
    }
    return byKeywords
  }
}
