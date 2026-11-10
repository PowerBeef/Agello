import XCTest

@testable import Agello

final class WebTests: XCTestCase {
  private func fixture(_ name: String, _ ext: String) throws -> Data {
    #if SWIFT_PACKAGE
      // `swift test` on a Mac (docs/CLI.md): SwiftPM copies the folder into the package's bundle.
      let found = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
    #else
      let found = Bundle(for: WebTests.self).url(forResource: name, withExtension: ext)
    #endif
    let url = try XCTUnwrap(found, "Missing \(name).\(ext)")
    return try Data(contentsOf: url)
  }

  private func html(_ name: String) throws -> String {
    String(decoding: try fixture(name, "html"), as: UTF8.self)
  }

  // MARK: Providers

  func testDuckDuckGoResultsSkipAds() throws {
    let page = try html("ddg")
    let results = SearchParsers.duckDuckGo(html: page)
    XCTAssertEqual(results.count, 3)
    XCTAssertFalse(results.contains { $0.title.contains("Sponsored") })
    XCTAssertEqual(results.first?.domain, "procyclinguk.com")
    XCTAssertTrue(results.allSatisfy { !$0.snippet.isEmpty && $0.url.scheme == "https" })
    XCTAssertFalse(SearchParsers.isDuckDuckGoChallenge(page))
    XCTAssertTrue(SearchParsers.isDuckDuckGoChallenge(try html("ddg-challenge")))
  }

  func testDuckDuckGoRedirectLinksAreResolved() {
    XCTAssertEqual(
      SearchParsers.resolveDuckDuckGoLink(
        "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa%3Fb%3D1&rut=x")?.absoluteString,
      "https://example.com/a?b=1")
    XCTAssertNil(SearchParsers.resolveDuckDuckGoLink("https://duckduckgo.com/y.js?ad=1"))
  }

  func testWikipediaResults() throws {
    let results = SearchParsers.wikipedia(json: try fixture("wikipedia", "json"), language: "en")
    XCTAssertEqual(results.count, 2)
    XCTAssertEqual(results.first?.url.absoluteString, "https://en.wikipedia.org/wiki/2026_Tour_de_France")
    XCTAssertFalse(results.first?.snippet.contains("<span") ?? true)
  }

  func testKeyedAndSelfHostedProviders() {
    let searx = Data(#"{"results":[{"title":"A &amp; B","url":"https://a.example","content":"x"}]}"#.utf8)
    XCTAssertEqual(SearchParsers.searxng(json: searx).first?.title, "A & B")
    let brave = Data(#"{"web":{"results":[{"title":"T","url":"https://b.example","description":"<b>d</b>"}]}}"#.utf8)
    XCTAssertEqual(SearchParsers.brave(json: brave).first?.snippet, "d")
    let tavily = Data(#"{"results":[{"title":"T","url":"ftp://bad","content":"c"},{"title":"U","url":"https://c.example","content":"c"}]}"#.utf8)
    XCTAssertEqual(SearchParsers.tavily(json: tavily).map(\.title), ["U"])
  }

  func testProviderChain() {
    var settings = WebSearchSettings()
    XCTAssertEqual(settings.chain { _ in false }, [.duckDuckGo, .wikipedia])
    settings.provider = .brave
    XCTAssertEqual(settings.chain { _ in false }, [.duckDuckGo, .wikipedia], "No key: skipped")
    XCTAssertEqual(settings.chain { _ in true }, [.brave, .duckDuckGo, .wikipedia])
    settings.provider = .searxng
    settings.searxngURL = "https://searx.example.org"
    XCTAssertEqual(settings.chain { _ in false }, [.searxng, .duckDuckGo, .wikipedia])
    settings.provider = .wikipedia
    XCTAssertEqual(settings.chain { _ in false }, [.wikipedia, .duckDuckGo])
  }

  // MARK: Pages

  func testReadableTextKeepsTheArticleOnly() throws {
    let page = ReadableText.extract(html: try html("article"))
    XCTAssertEqual(page.title, "Council approves harbour renovation")
    XCTAssertTrue(page.text.contains("approved a 4.2 million dollar renovation"), page.text)
    XCTAssertTrue(page.text.contains("fishers & residents"))
    XCTAssertTrue(page.text.contains("“new pier”"))
    XCTAssertTrue(page.text.contains("Pier | 2.5 M$"), page.text)
    XCTAssertTrue(page.text.contains("• Votes in favour: 9 of 11"))
    for chrome in ["Sport", "Weather", "Podcasts", "tracking", "All rights reserved", "Ferry schedules"] {
      XCTAssertFalse(page.text.contains(chrome), "Kept '\(chrome)': \(page.text)")
    }
  }

  /// Scripts, styles and comments spanning lines are removed whole, not just their tags.
  func testMultiLineScriptsAndCommentsAreRemoved() {
    let html = """
      <html><body><script type="text/javascript">
        window.dataLayer = [];
        function track() { return "SECRET_TRACKER"; }
      </script><style>
        body { color: red; }
      </style><!--
        HIDDEN_COMMENT
      --><article><p>\(String(repeating: "Readable article sentence about the harbour. ", count: 8))</p></article>
      </body></html>
      """
    let page = ReadableText.extract(html: html)
    for leak in ["SECRET_TRACKER", "dataLayer", "color: red", "HIDDEN_COMMENT"] {
      XCTAssertFalse(page.text.contains(leak), "Kept '\(leak)': \(page.text)")
    }
    XCTAssertTrue(page.text.contains("Readable article sentence"))
  }

  /// Wikipedia answers in the question's language when it's clear, else the device's.
  func testWikipediaEditionFollowsTheQuestion() {
    let english = ["en-CA"]
    XCTAssertEqual(WebClient.wikipediaLanguage(for: "Quelle est la capitale de l'Australie ?", preferred: english), "fr")
    XCTAssertEqual(WebClient.wikipediaLanguage(for: "日本の首都はどこですか", preferred: english), "ja")
    XCTAssertEqual(WebClient.wikipediaLanguage(for: "中国的首都是哪里", preferred: english), "zh")
    XCTAssertEqual(WebClient.wikipediaLanguage(for: "Wie hoch ist der Mount Everest?", preferred: english), "de")
    XCTAssertEqual(WebClient.wikipediaLanguage(for: "Paris", preferred: english), "en")
    XCTAssertEqual(WebClient.wikipediaLanguage(for: "Paris", preferred: ["zh-Hans-CN"]), "zh")
    XCTAssertEqual(WebClient.wikipediaLanguage(for: "Oslo", preferred: ["nb-NO"]), "no")
  }

  /// Files and web results share the room for material: web gets what the files leave, and
  /// never under a quarter of it.
  func testWebBudgetSharesTheWindowWithFiles() {
    let alone = WebContext.budget(window: 8_192, question: "q")
    XCTAssertEqual(alone, FileContext.budget(window: 8_192, question: "q"))
    XCTAssertEqual(WebContext.budget(window: 8_192, question: "q", alongsideFileTokens: 1_000), alone - 1_000)
    XCTAssertEqual(WebContext.budget(window: 8_192, question: "q", alongsideFileTokens: 9_000), alone / 4)
  }

  func testEntities() {
    XCTAssertEqual(HTMLText.decodeEntities("a&amp;b &#233;t&#xE9; &unknown; &"), "a&b été &unknown; &")
  }

  // MARK: Context

  func testMergeInterleavesAndDeduplicates() {
    let a = WebResult(title: "A", url: URL(string: "https://a.example/x")!, snippet: "")
    let b = WebResult(title: "B", url: URL(string: "https://b.example/")!, snippet: "")
    let c = WebResult(title: "C", url: URL(string: "https://c.example/")!, snippet: "")
    let aAgain = WebResult(title: "A2", url: URL(string: "https://a.example/x")!, snippet: "")
    let merged = WebResearch.merge([[a, b], [aAgain, c]])
    XCTAssertEqual(merged.map(\.title), ["A", "B", "C"])
  }

  func testQueries() {
    let json = Data(#"{"queries":["Tour de France 2026 winner margin"," tour de france 2026 WINNER margin ","x"]}"#.utf8)
    XCTAssertEqual(WebContext.parseQueries(json), ["Tour de France 2026 winner margin"])
    XCTAssertEqual(WebContext.directQuery("  who won\n the tour?  "), "who won the tour?")
    let prompt = WebContext.queryPrompt(
      question: "By how much?", history: [(.user, "Who won the Tour?"), (.model, "Pogačar.")])
    XCTAssertTrue(prompt.contains("User: Who won the Tour?"))
    XCTAssertTrue(prompt.contains("New message: By how much?"))
  }

  func testCitationsBecomeLinks() {
    let sources = [
      SourceRecord(index: 1, title: "A", url: "https://a.example", snippet: nil),
      SourceRecord(index: 2, title: "B", url: "https://b.example", snippet: nil),
      SourceRecord(index: 3, title: "notes.md", url: nil, snippet: nil),
    ]
    let text = "Pogačar won [1][2]. See [3] and [9].\n`array[1]`\n```\nx[1]\n```"
    let linked = WebContext.linkCitations(text, sources: sources)
    XCTAssertTrue(linked.hasPrefix("Pogačar won [\\[1\\]](https://a.example)[\\[2\\]](https://b.example)."))
    XCTAssertTrue(linked.contains("See [3] and [9]."), "No URL / no source: unchanged")
    XCTAssertTrue(linked.contains("`array[1]`"))
    XCTAssertTrue(linked.contains("x[1]"))
    #if !SWIFT_PACKAGE
      // The markdown parser renders them as links (the parser is the interface's: not in the
      // Mac command line's build).
      guard case .paragraph(let first) = MarkdownDocument(parsing: linked).blocks.first else {
        return XCTFail("The linked text isn't a paragraph")
      }
      XCTAssertTrue(first.runs.contains { $0.link?.absoluteString == "https://a.example" })
    #endif
  }

  func testWebPromptLayout() {
    let source = WebContext.Source(
      index: 1, title: "Results", url: URL(string: "https://www.cyclingstage.com/x")!,
      passages: ["Pogačar won.", "By 6:26."])
    let prompt = WebContext.prompt(
      question: "Who won?", sources: [source], today: Date(timeIntervalSince1970: 1_791_600_000))
    XCTAssertTrue(prompt.contains("[1] Results — cyclingstage.com\nPogačar won.\n…\nBy 6:26."))
    XCTAssertTrue(prompt.hasSuffix("Message: Who won?"))
    // A request, not only a question: the sources are reference material for doing it.
    XCTAssertTrue(prompt.contains("do what the message asks"))
    XCTAssertEqual(source.record.url, "https://www.cyclingstage.com/x")
  }

  /// Every Search message is planned, a first one too: a request gets queries for what it needs
  /// (searched as typed, "create a calculator app" found tutorials restating the task).
  func testQueryPlanForAFirstMessageAndARequest() {
    let first = WebContext.queryPrompt(
      question: "Create a calculator app", history: [], today: Date(timeIntervalSince1970: 1_791_600_000))
    XCTAssertFalse(first.contains("Conversation so far"))
    XCTAssertTrue(first.contains("New message: Create a calculator app"))
    XCTAssertTrue(first.contains("techniques, APIs"))
    let followUp = WebContext.queryPrompt(
      question: "And on iPad?", history: [(.user, "Make a SwiftUI list"), (.model, "Here it is")])
    XCTAssertTrue(followUp.contains("Conversation so far:\nUser: Make a SwiftUI list"))
    let plan = WebContext.parsePlan(
      Data(#"{"queries":["css grid keypad","safe eval javascript"],"request":true}"#.utf8))
    XCTAssertEqual(plan, WebContext.Plan(queries: ["css grid keypad", "safe eval javascript"], isRequest: true))
    XCTAssertFalse(WebContext.parsePlan(Data(#"{"queries":["tour de france 2026"]}"#.utf8)).isRequest)
  }

  /// A cited reply reaches the planner without its markers, so 400 bytes hold what it said: cut
  /// after "2nd: Remco Evenepoel (Red", it had the follow-up searched for the runner-up's time.
  func testPlannerHistoryDropsCitationMarkers() {
    let reply =
      "Tadej Pogačar won [1][2][3].\n\nThe podium:\n*   **1st:** Tadej Pogačar [1][2]\n*   **2nd:** Remco Evenepoel [1]"
    XCTAssertEqual(
      WebContext.historyLine(reply), "Tadej Pogačar won. The podium: 1st: Tadej Pogačar 2nd: Remco Evenepoel")
    XCTAssertEqual(WebContext.historyLine(String(repeating: "é", count: 300)).utf8.count, 400)
    let prompt = WebContext.queryPrompt(question: "By how many minutes?", history: [(.model, reply)])
    XCTAssertTrue(prompt.contains("Assistant: Tadej Pogačar won. The podium:"))
    XCTAssertFalse(prompt.contains("[1]"))
  }

  /// Search when needed: "Hello there" came back as a reply about pages on professional greetings
  /// (2026-11-02). The planner names the message's kind; questions and requests search, and an
  /// answer without a kind still searches.
  func testSearchOnlyWhenNeeded() {
    let prompt = WebContext.queryPrompt(question: "Hello there", history: [])
    XCTAssertTrue(prompt.contains("- chat: a greeting") && prompt.contains("- request: a request to write code"))
    let skip = WebContext.parsePlan(Data(#"{"kind":"chat","queries":["greetings"]}"#.utf8))
    XCTAssertEqual(skip, WebContext.Plan(queries: [], isRequest: false, needsSearch: false))
    let question = WebContext.parsePlan(Data(#"{"kind":"question","queries":["swift 6.3"]}"#.utf8))
    XCTAssertEqual(question, WebContext.Plan(queries: ["swift 6.3"], isRequest: false))
    let request = WebContext.parsePlan(Data(#"{"kind":"request","queries":["css grid keypad"]}"#.utf8))
    XCTAssertEqual(request, WebContext.Plan(queries: ["css grid keypad"], isRequest: true))
    XCTAssertTrue(WebContext.parsePlan(Data(#"{"queries":["swift 6.3"]}"#.utf8)).needsSearch)
    XCTAssertTrue(WebContext.parsePlan(Data("not json".utf8)).needsSearch)
    XCTAssertTrue(WebContext.instructions().contains("don't bear on the message"))
    // The grammar asks queries of questions and requests only.
    XCTAssertTrue(WebContext.querySchema.contains(#""enum":["question","request"]},"queries":{"type":"array","items":{"type":"string"},"minItems":1"#))
    // A follow-up planned without queries searches after the previous user message.
    XCTAssertEqual(
      WebContext.directQuery(
        "By how many minutes?", history: [(.user, "Who won the 2026 Tour de France?"), (.model, "Pogačar.")]),
      "Who won the 2026 Tour de France? By how many minutes?")
    XCTAssertEqual(WebContext.directQuery("  Swift   6.2 "), "Swift 6.2")
  }

  /// A request's sources take a third of the window instead of half: more room for the work.
  func testRequestsLeaveMoreRoomForTheWork() {
    let question = WebContext.budget(window: 16_384, question: "Who won?")
    let request = WebContext.budget(window: 16_384, question: "Make a calculator", forRequest: true)
    XCTAssertLessThan(request, question)
    XCTAssertEqual(request, 16_384 / 3 - ContextBudget.estimateTokens("Make a calculator"))
  }

  /// Code samples keep their lines, indentation and language, figures that hold them included.
  func testPageCodeKeepsItsLines() {
    let html = """
      <html><body><article><h1>Adding</h1><p>A function that adds two numbers, explained at length \
      for the reader, so that this article has more than enough text to be picked as the main \
      content of the page by the extractor, which wants a couple of hundred characters at least.</p>
      <figure class="highlight"><pre><code class="language-js"><span class="k">function</span> add(a, b) {
        <span class="k">return</span> a &amp;&amp; b ? a + b : 0;
      }</code></pre></figure>
      <figure><img src="x.png"><figcaption>A diagram</figcaption></figure>
      <p>That's all.</p></article></body></html>
      """
    let text = ReadableText.extract(html: html).text
    XCTAssertTrue(text.contains("```js\nfunction add(a, b) {\n  return a && b ? a + b : 0;\n}\n```"), text)
    XCTAssertFalse(text.contains("A diagram"))
  }

  func testSettingsDecodeTolerantly() throws {
    let decoded = try JSONDecoder().decode(
      WebSearchSettings.self, from: Data(#"{"automatic":true,"provider":"bing"}"#.utf8))
    XCTAssertTrue(decoded.allowed)
    XCTAssertTrue(decoded.automatic)
    XCTAssertEqual(decoded.provider, .duckDuckGo)
  }
}
