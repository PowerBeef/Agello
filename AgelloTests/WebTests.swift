import XCTest

@testable import Agello

final class WebTests: XCTestCase {
  private func fixture(_ name: String, _ ext: String) throws -> Data {
    let url = try XCTUnwrap(
      Bundle(for: WebTests.self).url(forResource: name, withExtension: ext), "Missing \(name).\(ext)")
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
    XCTAssertTrue(prompt.contains("New question: By how much?"))
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
    // The markdown parser renders them as links.
    guard case .paragraph(let first) = MarkdownDocument(parsing: linked).blocks.first else {
      return XCTFail()
    }
    XCTAssertTrue(first.runs.contains { $0.link?.absoluteString == "https://a.example" })
  }

  func testWebPromptLayout() {
    let source = WebContext.Source(
      index: 1, title: "Results", url: URL(string: "https://www.cyclingstage.com/x")!,
      passages: ["Pogačar won.", "By 6:26."])
    let prompt = WebContext.prompt(
      question: "Who won?", sources: [source], today: Date(timeIntervalSince1970: 1_791_600_000))
    XCTAssertTrue(prompt.contains("[1] Results — cyclingstage.com\nPogačar won.\n…\nBy 6:26."))
    XCTAssertTrue(prompt.hasSuffix("Question: Who won?"))
    XCTAssertEqual(source.record.url, "https://www.cyclingstage.com/x")
  }

  func testSettingsDecodeTolerantly() throws {
    let decoded = try JSONDecoder().decode(
      WebSearchSettings.self, from: Data(#"{"automatic":true,"provider":"bing"}"#.utf8))
    XCTAssertTrue(decoded.allowed)
    XCTAssertTrue(decoded.automatic)
    XCTAssertEqual(decoded.provider, .duckDuckGo)
  }
}
