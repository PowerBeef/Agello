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
  /// A question or a request also names its topic (``SearchTopic``), which decides the sources.
  static let querySchema =
    #"{"anyOf":[{"type":"object","properties":{"kind":{"type":"string","enum":["chat","reaction","edit","creative","arithmetic","answered"]},"queries":{"type":"array","items":{"type":"string"},"maxItems":0}},"required":["kind","queries"]},"#
    + #"{"type":"object","properties":{"kind":{"type":"string","enum":["question","request"]},"topic":{"type":"string","enum":["general","travel","word","quote","weather","place","currency","research","health","news"]},"queries":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":3}},"required":["kind","topic","queries"]}]}"#
  static let queryMaxOutputTokens = 120

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
    var topic: SearchTopic = .general
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
      "\(turn.role == .user ? "User" : "Assistant"): \(historyLine(turn.text))"
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

      For a question or a request, give its topic, which decides where to look:
      \(SearchTopic.promptList)

      Then write 1 to 3 short search queries for what's needed to handle it well; for any other \
      kind, leave queries empty. The queries go to Wikipedia and the topic's own source, which \
      find articles by their subject: name the subjects as an encyclopedia's titles would \
      ("2026 Tour de France", "Transport Layer Security"), not as a question. \
      \(SearchTopic.queryStyles) For a question, search for the facts that answer it. For a \
      request, search for the specific techniques, APIs, specifications or facts needed to do it \
      well. Make each query self-contained: resolve names and \
      pronouns from the conversation, and give a follow-up the subject it's about (after a \
      question about the newest iPhone, "How much is it?" searches for that iPhone's price). A short \
      follow-up asks more about the user's previous question (after "Who won the election?", "By \
      how much?" searches for the winner's margin of victory). Use the language of the message.
      """
  }

  /// A past turn as the planner reads it: without citation markers and list markup, on one line,
  /// cut to 400 bytes. With them a cited reply was cut after its second name, and the follow-up
  /// was planned around that name (the runner-up of a race, 2026-11-10).
  static func historyLine(_ text: String) -> String {
    let plain = text.replacing(/\[\d+\]/, with: "").replacing(/\*+/, with: "")
    let collapsed = plain.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
      .joined(separator: " ")
      .replacing(" .", with: ".").replacing(" ,", with: ",")
    return ContextBudget.prefix(collapsed, maxBytes: 400)
  }

  static func parsePlan(_ json: Data) -> Plan {
    guard
      let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
      let queries = object["queries"] as? [String]
    else { return Plan(queries: [], isRequest: false) }
    let kind = object["kind"] as? String
    if let kind, !searchedKinds.contains(kind) { return Plan(queries: [], isRequest: false, needsSearch: false) }
    let topic = (object["topic"] as? String).flatMap(SearchTopic.init(rawValue:)) ?? .general
    var seen = Set<String>()
    let cleaned = queries.compactMap { raw -> String? in
      let query = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"")))
      guard query.count >= 2, seen.insert(query.lowercased()).inserted else { return nil }
      return String(query.prefix(200))
    }.prefix(3).map { $0 }
    return Plan(
      queries: cleaned, isRequest: kind == "request" || object["request"] as? Bool == true, topic: topic)
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

  /// Look `queries` up in the sources of `topic` (``SearchTopic``), read the best pages, and
  /// keep the passages most relevant to `rankingQueries` (default: `question`) within
  /// `budgetTokens`. A structured topic's answer (weather, places, a conversion) comes first and
  /// whole; without one, the reference sources answer. `language` is the user's message's:
  /// Wikipedia and its sister projects are searched in it, and in English for the first query.
  func research(
    queries: [String], question: String, rankingQueries: [String]? = nil, topic: SearchTopic = .general,
    language: String = "en", settings: WebSearchSettings, budgetTokens: Int,
    firstIndex: Int = 1, today: Date = .now, progress: @MainActor (String) -> Void
  ) async throws -> Findings {
    progress(String(localized: "Searching the web for “\(queries.first ?? question)”…"))
    let client = self.client
    var errors: [Error] = []

    // 1. A structured topic's own source: its answer, pinned.
    var pinned: [WebResult] = []
    if topic.isStructured, let query = queries.first {
      do {
        pinned = try await client.structured(topic, query: query)
      } catch let error as WebSearchError {
        throw error
      } catch {
        if (error as? URLError)?.code == .notConnectedToInternet { throw WebSearchError.offline }
        throw WebSearchError.unavailable(topic.sourceName)
      }
      try Task.checkCancellation()
      if pinned.isEmpty { throw WebSearchError.noResults }
    }

    // 2. The reference sources, every search at once. Pages to read come back by list (one per
    // query and source, the topic's own source first), papers with their abstracts as they are.
    var pageLists: [Int: [WebResult]] = [:]
    var papers: [WebResult] = []
    var usedProvider: SearchProvider?
    if pinned.isEmpty {
      let chain = settings.chain()
      let site: WikimediaSite? =
        switch topic {
        case .travel: .wikivoyage
        case .word: .wiktionary
        case .quote: .wikiquote
        default: nil
        }
      let editions = language == "en" ? ["en"] : [language, "en"]
      enum Outcome: Sendable {
        case pages(Int, [WebResult], SearchProvider?)
        case papers([WebResult])
        case failed(Error)
      }
      await withTaskGroup(of: Outcome.self) { group in
        for (index, query) in queries.enumerated() {
          // The other editions for the first query only: English is the most complete.
          let languages = index == 0 ? editions : [language]
          for (offset, edition) in languages.enumerated() {
            let slot = (index * 4 + offset) * 2
            if let site {
              group.addTask {
                do { return .pages(slot, try await client.searchWiki(query, site: site, language: edition), nil) } catch {
                  return .failed(error)
                }
              }
            }
            group.addTask {
              var lastError: Error?
              for provider in chain {
                do {
                  let found = try await client.search(query, with: provider, settings: settings, language: edition)
                  if !found.isEmpty { return .pages(slot + 1, found, provider) }
                } catch {
                  lastError = error
                  if case WebSearchError.offline = error { break }
                }
              }
              return lastError.map(Outcome.failed) ?? .pages(slot + 1, [], nil)
            }
          }
        }
        if let query = queries.first {
          switch topic {
          case .research:
            group.addTask { do { return .papers(try await client.crossref(query)) } catch { return .failed(error) } }
          case .health:
            group.addTask { do { return .papers(try await client.pubMed(query)) } catch { return .failed(error) } }
          case .news:
            for day in CurrentEvents.pages(today: today) {
              group.addTask {
                do { return .papers([try await client.currentEvents(day)].compactMap { $0 }) } catch { return .failed(error) }
              }
            }
          default:
            break
          }
        }
        for await outcome in group {
          switch outcome {
          case .pages(let slot, let found, let provider):
            pageLists[slot] = found
            if usedProvider == nil, let provider, !found.isEmpty { usedProvider = provider }
          case .papers(let found): papers += found
          case .failed(let error): errors.append(error)
          }
        }
      }
      try Task.checkCancellation()
      if let offline = errors.first(where: { if case WebSearchError.offline = $0 { true } else { false } }) {
        throw offline
      }
      // The facts of the first article found, for a general question.
      if topic == .general, let first = pageLists[1]?.first, first.url.host()?.hasSuffix("wikipedia.org") == true,
        let facts = try? await client.wikidataFacts(title: first.title, language: language)
      {
        papers.insert(facts, at: 0)
      }
    }
    let merged = Self.merge(pageLists.keys.sorted().compactMap { pageLists[$0] }.filter { !$0.isEmpty })
    guard !pinned.isEmpty || !merged.isEmpty || !papers.isEmpty else {
      throw errors.last ?? WebSearchError.noResults
    }

    // 3. Read the top pages in parallel (snippets stand in for failures); papers and facts are
    // read already.
    let pages = Array(merged.prefix(Self.pagesToRead))
    let candidates = papers + pages
    var texts: [Int: String] = [:]
    for (index, paper) in papers.enumerated() { texts[index] = paper.content }
    if !pages.isEmpty {
      progress(String(localized: "Reading \(pages.count) pages…"))
      let first = papers.count
      await withTaskGroup(of: (Int, ReadableText.Page?).self) { group in
        for (offset, result) in pages.enumerated() {
          group.addTask { (first + offset, await client.readPage(result.url)) }
        }
        for await (index, page) in group { texts[index] = page?.text }
      }
    }
    try Task.checkCancellation()

    // 4. Rank passages by relevance to the question.
    struct Candidate {
      var result: Int
      var text: String
    }
    var passages: [Candidate] = []
    for (index, result) in candidates.enumerated() {
      if let text = texts[index] {
        for chunk in Chunker.chunks(pages: [text], paged: false).prefix(40) {
          passages.append(Candidate(result: index, text: chunk.text))
        }
      }
      if !result.snippet.isEmpty, result.content == nil {
        passages.append(Candidate(result: index, text: result.snippet))
      }
    }
    var order: [Int] = []
    if !passages.isEmpty {
      progress(String(localized: "Picking the relevant parts…"))
      order = await rank(passages.map(\.text), against: rankingQueries ?? [question])
    }

    // 5. The pinned answers first and whole, then the best passages within budget; sources are
    // numbered by first use.
    var used = 0
    var sources: [WebContext.Source] = []
    for result in pinned {
      let text = result.content ?? result.snippet
      used += ContextBudget.estimateTokens(text) + 16
      sources.append(
        WebContext.Source(index: firstIndex + sources.count, title: result.title, url: result.url, passages: [text]))
    }
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
    for result in sourceOrder {
      sources.append(
        WebContext.Source(
          index: firstIndex + sources.count, title: candidates[result].title, url: candidates[result].url,
          passages: perSource[result] ?? []))
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
  /// Passages kept by meaning score at least this share of the best one's. Without a floor,
  /// every page read gave passages and became a source, a tennis player and an Ontario carnival in
  /// a Montreal trip included (2026-11-12).
  static let relevanceFloor: Float = 0.7

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
        // The shortlist by meaning, down to the relevance floor; the rest by keywords goes.
        let best = vectors.map { vector in queryVectors.map { VectorIndex.dot($0, vector) }.max() ?? 0 }
        let top = best.max() ?? 0
        return shortlist.indices.sorted { best[$0] > best[$1] }
          .filter { top <= 0 || best[$0] >= top * Self.relevanceFloor }.map { shortlist[$0] }
      }
    }
    return byKeywords
  }
}
