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
      followUp.text.range(of: #"\b6\s*(minutes?|min\b|:|′|')"#, options: .regularExpression) != nil,
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
        "Tadej Pogačar won the 2026 Tour de France [1][2][3][4][5].\n\nHe finished with a total time of 73 hours, 56 minutes, and 26 seconds [1][2][3]. Pogačar's victory marked his fifth Tour de France title, equalling the all-time record [2][3][4].\n\nThe final podium finishers were:\n*   **1st:** Tadej Pogačar (UAE Team Emirates XRG) [1][2][3][4][5]\n*   **2nd:** Remco Evenepoel (Red Bull–Bora–Hansgrohe) [1][2][3][4][5]\n*   **3rd:** Isaac del Toro (UAE Team Emirates XRG) [1][2][3][4][5]"
      ),
    ]
    let gapWords = ["margin", "gap", "difference", "standings", "classification", "ahead", "behind"]
    let cases: [(message: String, history: [(role: ChatRole, text: String)], search: Bool)] = [
      ("Hello there", [], false),
      ("Thanks, that's perfect!", race, false),
      ("Translate into Spanish: \"See you tomorrow at the station.\"", [], false),
      ("Write a short poem about autumn leaves.", [], false),
      ("What changed in Swift 6.2?", [], true),
      ("Create a beautiful calculator app for mobile in a single self contained html file", [], true),
      ("Write a SwiftUI view for iOS that lists notes with swipe to delete, pull to refresh, and a search field. Use the current APIs.", [], true),
      ("Plan a 3-day winter trip to Montreal with mostly indoor activities and a budget table.", [], true),
      ("How do I center a div with CSS grid?", [], true),
      ("By how many minutes?", race, true),
      ("By how many minutes?", raceWithTimes, true),
      ("Who came third?", race, false),
    ]
    var rows: [[String: Any]] = []
    var wrong: [String] = []
    for item in cases {
      let started = Date()
      var row: [String: Any] = ["message": item.message, "expected": item.search]
      do {
        let data = try await appState.engine.helperJSON(
          prompt: WebContext.queryPrompt(question: item.message, history: item.history),
          schemaJSON: WebContext.querySchema, maxOutputTokens: WebContext.queryMaxOutputTokens)
        let plan = WebContext.parsePlan(data)
        row["output"] = String(decoding: data, as: UTF8.self)
        row["search"] = plan.needsSearch
        row["queries"] = plan.queries
        row["request"] = plan.isRequest
        if plan.needsSearch != item.search { wrong.append(item.message) }
        // A follow-up's queries carry the conversation's subject (the race).
        if plan.needsSearch, !item.history.isEmpty,
          !plan.queries.contains(where: { $0.localizedCaseInsensitiveContains("tour") })
        {
          wrong.append("\(item.message) (queries without the subject)")
        }
        // The margin is asked for itself, not worked out from one rider's time.
        if item.message.hasPrefix("By how many"),
          !plan.queries.contains(where: { query in gapWords.contains { query.localizedCaseInsensitiveContains($0) } })
        {
          wrong.append("\(item.message) (no query for the margin: \(plan.queries))")
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
}
