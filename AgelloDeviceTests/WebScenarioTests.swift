import XCTest

@testable import Agello

/// Live web search with the real model (needs internet): a cited answer to
/// a current-events question, a follow-up that needs planned queries, and
/// automatic mode; and Search's decision to search at all (test04, offline).
final class WebScenarioTests: DeviceTestCase {

  func test01_SearchAndCite() async throws {
    try await requireLoadedModel()
    _ = try await harness.ensureDownloaded(ModelCatalog.embeddingGemma, timeout: 900)
    let thread = harness.newThread()
    let answer = await harness.ask(
      "Who won the 2026 Tour de France?", in: thread, webSearch: true)
    let sources = answer.reply?.parts.sources ?? []
    let followUp = await harness.ask("By how many minutes?", in: thread, webSearch: true)
    let followSources = followUp.reply?.parts.sources ?? []
    // The follow-up's plan again, from the history it was planned with (an empty plan searches
    // the message as typed). Last in this chat: a helper may leave its conversation empty.
    var followUpPlan: String
    do {
      let data = try await appState.engine.helperJSON(
        prompt: WebContext.queryPrompt(
          question: "By how many minutes?", history: Array(thread.textHistory.dropLast(2))),
        schemaJSON: WebContext.querySchema, maxOutputTokens: WebContext.queryMaxOutputTokens)
      followUpPlan = String(decoding: data, as: UTF8.self)
    } catch {
      followUpPlan = "error: \(error)"
    }
    harness.record(
      "web01_searchAndCite",
      [
        "seconds": answer.seconds, "reply": answer.text,
        "sources": sources.map { "\($0.index) \($0.title) \($0.url ?? "")" },
        "notice": appState.generationError ?? "",
        "followUpSeconds": followUp.seconds, "followUpReply": followUp.text,
        "followUpSources": followSources.map(\.title), "followUpSearched": !followSources.isEmpty,
        "followUpPlan": followUpPlan,
        "stats": DeviceHarness.stats(answer.reply?.stats),
      ], in: self)
    XCTAssertFalse(answer.text.hasPrefix(ChatTurn.errorPrefix), answer.text)
    XCTAssertFalse(sources.isEmpty, "No sources: \(appState.generationError ?? "")")
    XCTAssertTrue(sources.allSatisfy { $0.url?.hasPrefix("https://") == true })
    XCTAssertTrue(
      answer.text.range(of: "Poga[cč]ar", options: .regularExpression) != nil, answer.text)
    XCTAssertTrue(answer.text.contains("[1]") || answer.text.contains("[2]"), "No citation: \(answer.text)")
    XCTAssertTrue(answer.reply?.parts.sources.isEmpty == false)
    XCTAssertTrue(thread.orderedTurns.first?.parts.webSearch == true)
    XCTAssertFalse(followUp.text.hasPrefix(ChatTurn.errorPrefix), followUp.text)
    // Searched again or answered from the conversation (Search when needed, 2026-11-02), the
    // follow-up gives the margin: 6 min 26 s. Searched as "minutes calculator", it asked for times.
    XCTAssertTrue(
      followUp.text.range(of: #"\b(6|six)(\s|-)*(and a half\s*)?(minutes?|min\b|:|′|')"#, options: [.regularExpression, .caseInsensitive]) != nil,
      "Margin missing: \(followUp.text)")
  }

  /// Search on for a request, not a question: the reply does what was asked, with the sources as
  /// reference. Framed as a question to answer from the sources, this exact message (from the
  /// iPhone, 2026-11-02) came back as "it is possible…" and a summary of five pages.
  func test01b_SearchStillDoesTheTask() async throws {
    try await requireLoadedModel()
    _ = try await harness.ensureDownloaded(ModelCatalog.embeddingGemma, timeout: 900)
    let reply = await harness.ask(
      "Create a beautiful calculator app for mobile in a single self contained html file",
      in: harness.newThread(), webSearch: true)
    let text = reply.text.lowercased()
    let built = text.contains("<html") || text.contains("<!doctype") || text.contains("```html")
    harness.record(
      "web01b_searchStillDoesTheTask",
      [
        "seconds": reply.seconds, "built": built, "replyPrefix": String(reply.text.prefix(300)),
        "sources": reply.reply?.parts.sources.count ?? 0,
        "outputTokens": reply.reply?.stats?.outputTokens ?? -1,
        "reachedLimit": reply.reply?.stats?.reachedLimit ?? false,
      ], in: self)
    XCTAssertTrue(reply.accepted, appState.generationError ?? "rejected")
    XCTAssertTrue(built, "No HTML in the reply: \(reply.text.prefix(400))")
  }

  /// A greeting with Search on is answered as a greeting: no search, no sources (2026-11-02, it
  /// came back as a reply about pages on professional greetings).
  func test01c_GreetingSkipsSearch() async throws {
    try await requireLoadedModel()
    let reply = await harness.ask("Hello there", in: harness.newThread(), webSearch: true)
    let sources = reply.reply?.parts.sources ?? []
    harness.record(
      "web01c_greetingSkipsSearch",
      ["seconds": reply.seconds, "reply": reply.text, "sources": sources.map(\.title)], in: self)
    XCTAssertTrue(reply.accepted, appState.generationError ?? "rejected")
    XCTAssertTrue(sources.isEmpty, "Searched for a greeting: \(sources.map(\.title))")
    XCTAssertFalse(reply.text.lowercased().contains("source"), reply.text)
  }

  /// Work on text already in the message needs nothing from the web.
  func test01d_TranslationSkipsSearch() async throws {
    try await requireLoadedModel()
    let reply = await harness.ask(
      "Translate into French: \"Good morning, my friend. The train leaves at noon.\"",
      in: harness.newThread(), webSearch: true)
    let sources = reply.reply?.parts.sources ?? []
    harness.record(
      "web01d_translationSkipsSearch",
      ["seconds": reply.seconds, "reply": reply.text, "sources": sources.map(\.title)], in: self)
    XCTAssertTrue(reply.accepted, appState.generationError ?? "rejected")
    XCTAssertTrue(sources.isEmpty, "Searched for a translation: \(sources.map(\.title))")
    XCTAssertTrue(reply.text.lowercased().contains("bonjour"), reply.text)
  }

  func test02_AutomaticSearch() async throws {
    try await requireLoadedModel()
    appState.webSettings.automatic = true
    defer { appState.webSettings.automatic = false }
    await appState.applyCurrentOptions()
    let reply = await harness.ask(
      "Search the web: what is the latest stable version of Swift?", in: harness.newThread())
    let tools = reply.reply?.parts.toolActivity.map(\.summary) ?? []
    let sources = reply.reply?.parts.sources ?? []
    harness.record(
      "web02_automatic",
      ["reply": reply.text, "tools": tools, "sources": sources.map(\.title), "seconds": reply.seconds],
      in: self)
    XCTAssertFalse(reply.text.hasPrefix(ChatTurn.errorPrefix), reply.text)
    XCTAssertTrue(tools.contains { $0.contains("Searched the web") }, "web_search not called: \(tools)")
    XCTAssertFalse(sources.isEmpty)
  }

  /// Automatic web search has its own switch: it must work with the
  /// on-device tools (date, calculator) turned off. tearDown restores tools.
  func test03_AutomaticSearchWithToolsOff() async throws {
    try await requireLoadedModel()
    appState.enableTools = false
    appState.webSettings.automatic = true
    defer { appState.webSettings.automatic = false }
    await appState.applyCurrentOptions()
    let reply = await harness.ask(
      "Search the web: what is the latest stable version of Swift?", in: harness.newThread())
    let tools = reply.reply?.parts.toolActivity.map(\.summary) ?? []
    let sources = reply.reply?.parts.sources ?? []
    harness.record(
      "web03_automaticToolsOff",
      ["reply": reply.text, "tools": tools, "sources": sources.map(\.title), "seconds": reply.seconds],
      in: self)
    XCTAssertFalse(reply.text.hasPrefix(ChatTurn.errorPrefix), reply.text)
    XCTAssertTrue(tools.contains { $0.contains("Searched the web") }, "web_search not called: \(tools)")
    XCTAssertFalse(sources.isEmpty)
  }

  /// Search when needed (2026-11-02): the planner's decision for messages it must search and
  /// messages it must not, without the web. Told to search "facts you may not know well", it
  /// skipped a SwiftUI request for current APIs, a calculator and a trip plan.
  func test04_SearchDecisions() async throws {
    try await requireLoadedModel()
    let race: [(role: ChatRole, text: String)] = [
      (.user, "Who won the 2026 Tour de France?"),
      (.model, "Tadej Pogačar won the 2026 Tour de France, his fifth title [1][2]. Remco Evenepoel was second and Isaac del Toro third [1]."),
    ]
    // The reply the iPhone gave at 32K (2026-11-10), with the winner's time and the podium: from
    // it the follow-up was planned as "Remco Evenepoel 2026 Tour de France time", and the reply
    // gave a stage's 28 seconds.
    let raceWithTimes: [(role: ChatRole, text: String)] = [
      (.user, "Who won the 2026 Tour de France?"),
      (
        .model,
        "Tadej Pogačar won the 2026 Tour de France [1][2][3][4][5].\n\n"
          + "He finished with a total time of 73 hours, 56 minutes, and 26 seconds [1][2][3]. Pogačar's victory marked his fifth Tour de France title, equalling the all-time record [2][3][4].\n\n"
          + "The final podium finishers were:\n"
          + "*   **1st:** Tadej Pogačar (UAE Team Emirates XRG) [1][2][3][4][5]\n"
          + "*   **2nd:** Remco Evenepoel (Red Bull–Bora–Hansgrohe) [1][2][3][4][5]\n"
          + "*   **3rd:** Isaac del Toro (UAE Team Emirates XRG) [1][2][3][4][5]"
      ),
    ]
    // The topic decides the sources (`SearchTopic`, 2026-11-12); nil: not searched, or either.
    let cases: [(message: String, history: [(role: ChatRole, text: String)], search: Bool, topics: Set<SearchTopic>)] = [
      ("Hello there", [], false, []),
      ("Thanks, that's perfect!", race, false, []),
      ("Translate into Spanish: \"See you tomorrow at the station.\"", [], false, []),
      ("Write a short poem about autumn leaves.", [], false, []),
      ("What changed in Swift 6.2?", [], true, [.general, .news]),
      ("Create a beautiful calculator app for mobile in a single self contained html file", [], true, [.general]),
      ("Write a SwiftUI view for iOS that lists notes with swipe to delete, pull to refresh, and a search field. Use the current APIs.", [], true, [.general]),
      ("Plan a 3-day winter trip to Montreal with mostly indoor activities and a budget table.", [], true, [.travel]),
      ("How do I center a div with CSS grid?", [], true, [.general]),
      ("By how many minutes?", race, true, []),
      ("By how many minutes?", raceWithTimes, true, []),
      ("Who came third?", race, false, []),
      ("Will it rain in Montreal tomorrow?", [], true, [.weather]),
      ("How much is 250 US dollars in euros?", [], true, [.currency]),
      ("Is there a pharmacy open near Place des Arts in Montreal?", [], true, [.place]),
      ("What does \"serendipity\" mean?", [], true, [.word]),
      ("Who said \"The only thing we have to fear is fear itself\"?", [], true, [.quote]),
      ("What do studies say about intermittent fasting for weight loss?", [], true, [.research, .health]),
      ("What are the common side effects of metformin?", [], true, [.health]),
      ("What happened in the world yesterday?", [], true, [.news]),
      ("What is the population of Montreal?", [], true, [.general]),
    ]
    var rows: [[String: Any]] = []
    var wrong: [String] = []
    for item in cases {
      let started = Date()
      var row: [String: Any] = ["message": item.message, "expected": item.search, "expectedTopics": item.topics.map(\.rawValue).sorted()]
      do {
        let data = try await appState.engine.helperJSON(
          prompt: WebContext.queryPrompt(question: item.message, history: item.history),
          schemaJSON: WebContext.querySchema, maxOutputTokens: WebContext.queryMaxOutputTokens)
        let plan = WebContext.parsePlan(data)
        row["output"] = String(decoding: data, as: UTF8.self)
        row["search"] = plan.needsSearch
        row["queries"] = plan.queries
        row["request"] = plan.isRequest
        row["topic"] = plan.topic.rawValue
        if plan.needsSearch != item.search { wrong.append(item.message) }
        if plan.needsSearch, !item.topics.isEmpty, !item.topics.contains(plan.topic) {
          wrong.append("\(item.message) (topic \(plan.topic.rawValue), not \(item.topics.map(\.rawValue).sorted()))")
        }
        // A follow-up's queries carry the conversation's subject (the race).
        if plan.needsSearch, !item.history.isEmpty,
          !plan.queries.contains(where: { $0.localizedCaseInsensitiveContains("tour") })
        {
          wrong.append("\(item.message) (queries without the subject)")
        }
      } catch {
        // A failed plan searches the message as typed.
        row["error"] = String(describing: error).prefix(300)
        if !item.search { wrong.append(item.message) }
      }
      row["seconds"] = Date().timeIntervalSince(started)
      rows.append(row)
    }
    harness.record("web04_searchDecisions", ["rows": rows, "wrong": wrong], in: self)
    XCTAssertTrue(wrong.isEmpty, "Wrong search decisions: \(wrong)")
  }

  /// Every reference source answers on the device, through the app's own requests: the free,
  /// keyless sources Search uses since 2026-11-12. One row each, so a failing source doesn't hide
  /// the rest. Weather needs WeatherKit enabled for the App ID (Capabilities and App Services).
  func test05_ReferenceSources() async throws {
    let client = WebClient()
    let checks: [(name: String, run: @Sendable () async throws -> [WebResult])] = [
      ("wikipedia", { try await client.searchWiki("2026 Tour de France", site: .wikipedia, language: "en") }),
      ("wikivoyage", { try await client.searchWiki("Montreal", site: .wikivoyage, language: "en") }),
      ("wiktionary", { try await client.searchWiki("serendipity", site: .wiktionary, language: "en") }),
      ("wikiquote", { try await client.searchWiki("Franklin D. Roosevelt", site: .wikiquote, language: "en") }),
      ("wikidata", { [try await client.wikidataFacts(title: "Montreal", language: "en")].compactMap { $0 } }),
      ("currency", { try await client.structured(.currency, query: "100 USD to EUR") }),
      ("places", { try await client.structured(.place, query: "pharmacy near Place des Arts, Montreal") }),
      ("weather", { try await client.structured(.weather, query: "Montreal") }),
      ("weather place", {
        let found = try await client.structured(.weather, query: "Montreal")
        return found.filter { $0.title.localizedCaseInsensitiveContains("Montr") }
      }),
      ("crossref", { try await client.crossref("intermittent fasting weight loss") }),
      ("pubmed", { try await client.pubMed("metformin side effects") }),
      ("current events", { [try await client.currentEvents(CurrentEvents.pages()[1])].compactMap { $0 } }),
    ]
    var rows: [[String: Any]] = []
    var failed: [String] = []
    for check in checks {
      let started = Date()
      var row: [String: Any] = ["source": check.name]
      do {
        let results = try await check.run()
        row["count"] = results.count
        row["first"] = results.first.map { "\($0.title) \($0.url.absoluteString)" } ?? ""
        row["content"] = String((results.first?.content ?? results.first?.snippet ?? "").prefix(600))
        if results.isEmpty { failed.append("\(check.name): nothing") }
      } catch {
        row["error"] = String(describing: error).prefix(300)
        failed.append("\(check.name): \(error.localizedDescription)")
      }
      row["seconds"] = Date().timeIntervalSince(started)
      rows.append(row)
    }
    harness.record("web05_referenceSources", ["rows": rows, "failed": failed], in: self)
    XCTAssertTrue(failed.isEmpty, "Sources that failed: \(failed)")
  }

  /// Answers from the free sources, end to end (Search on): one row per topic, each with what a
  /// right answer must show (a fact in the reply, or the source it must come from). The table
  /// Search's quality is tuned against (2026-11-12, the maintainer: "optimising research quality,
  /// accuracy and efficiency using only the free complying sources").
  func test06_AnswersFromSources() async throws {
    try await requireLoadedModel()
    _ = try await harness.ensureDownloaded(ModelCatalog.embeddingGemma, timeout: 900)
    struct Case {
      var message: String
      /// In the reply, as a regular expression (case-insensitive).
      var reply: String?
      /// In one of the sources' title or address, as a regular expression (case-insensitive).
      var source: String?
      /// Needs the user's location: without it, the notice must say so.
      var nearMe = false
    }
    let cases = [
      Case(message: "Who won the 2026 Tour de France?", reply: "Poga[cč]ar", source: "wikipedia.org"),
      Case(message: "What is the population of Montreal?", reply: #"1[ ,.]?7\d\d[ ,.]?\d{3}|1\.[67]\d* million"#, source: nil),
      Case(message: "How much is 100 US dollars in euros?", reply: #"\d+[.,]\d{2} ?(€|EUR|euros?)|€ ?\d+"#, source: "European Central Bank"),
      Case(message: "What does \"serendipity\" mean?", reply: "chance|fortunate|accident|luck", source: "wiktionary"),
      Case(message: "Who said \"The only thing we have to fear is fear itself\"?", reply: "Roosevelt", source: nil),
      Case(message: "Will it rain in Montreal tomorrow?", reply: nil, source: "Weather"),
      Case(message: "Is there a pharmacy near Place des Arts in Montreal?", reply: "Sainte-Catherine|Saint-Laurent|Jeanne-Mance|Bleury|Maisonneuve|Ste-Catherine|St-Laurent|Complexe Desjardins|Saint-Urbain|H2X|H3B|H2Z|H3A|H2W", source: "Apple Maps"),
      Case(message: "What do studies say about intermittent fasting for weight loss?", reply: nil, source: "doi.org|pubmed"),
      Case(message: "What are the common side effects of metformin?", reply: "diarrh|nausea|gastro", source: nil),
      Case(message: "Plan a 3-day winter trip to Montreal with mostly indoor activities.", reply: nil, source: "wikivoyage"),
      Case(message: "What happened in the world yesterday?", reply: nil, source: "Current events"),
      // The maintainer's examples (2026-11-12): around the user; MapKit shares no opening hours, so
      // the reply points to the place in Apple Maps.
      Case(message: "Where is the nearest gas station?", reply: nil, source: "Apple Maps", nearMe: true),
      Case(message: "At what time does Walmart close tonight?", reply: "Apple Maps", source: "Walmart", nearMe: true),
    ]
    var rows: [[String: Any]] = []
    var wrong: [String] = []
    for item in cases {
      let answer = await harness.ask(item.message, in: harness.newThread(), webSearch: true)
      let sources = answer.reply?.parts.sources ?? []
      let described = sources.map { "\($0.index) \($0.title) \($0.url ?? "")" }
      let notice = appState.generationError ?? ""
      rows.append([
        "message": item.message, "seconds": answer.seconds, "reply": answer.text, "sources": described,
        "notice": notice, "topic": appState.lastWebPlan?.topic.rawValue ?? "",
        "queries": appState.lastWebPlan?.queries ?? [],
      ])
      // Without the location (refused, or the permission prompt unanswered), the reply must say so.
      if item.nearMe, notice.localizedCaseInsensitiveContains("location") { continue }
      if !answer.accepted || answer.text.hasPrefix(ChatTurn.errorPrefix) {
        wrong.append("\(item.message): \(answer.text.prefix(120))")
        continue
      }
      if let pattern = item.reply,
        answer.text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil
      {
        wrong.append("\(item.message): reply without /\(pattern)/: \(answer.text.prefix(160))")
      }
      if let source = item.source,
        !described.contains(where: { $0.range(of: source, options: [.regularExpression, .caseInsensitive]) != nil })
      {
        wrong.append("\(item.message): no \(source) source in \(described)")
      }
    }
    harness.record("web06_answersFromSources", ["rows": rows, "wrong": wrong], in: self)
    XCTAssertTrue(wrong.isEmpty, "Answers that missed: \(wrong)")
  }
}
