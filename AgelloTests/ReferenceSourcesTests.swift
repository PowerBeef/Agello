import MapKit
import XCTest

@testable import Agello

/// The reference sources behind Search (`SearchTopic`): parsers on real responses saved on
/// 2026-11-12, the planner's topics, and the structured sources' text.
final class ReferenceSourcesTests: XCTestCase {
  private func fixture(_ name: String, _ ext: String) throws -> Data {
    #if SWIFT_PACKAGE
      let found = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
    #else
      let found = Bundle(for: ReferenceSourcesTests.self).url(forResource: name, withExtension: ext)
    #endif
    return try Data(contentsOf: try XCTUnwrap(found, "Missing \(name).\(ext)"))
  }

  // MARK: Planning

  func testThePlanNamesItsTopic() {
    let plan = WebContext.parsePlan(Data(#"{"kind":"question","topic":"weather","queries":["Montreal"]}"#.utf8))
    XCTAssertEqual(plan.topic, .weather)
    XCTAssertEqual(plan.queries, ["Montreal"])
    let unknown = WebContext.parsePlan(Data(#"{"kind":"question","topic":"sports","queries":["x y"]}"#.utf8))
    XCTAssertEqual(unknown.topic, .general)
    let none = WebContext.parsePlan(Data(#"{"kind":"chat","queries":[]}"#.utf8))
    XCTAssertFalse(none.needsSearch)
  }

  /// The grammar offers exactly the topics the app handles, one word each.
  func testTheSchemaOffersEveryTopic() throws {
    let schema = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(WebContext.querySchema.utf8)) as? [String: Any])
    let searched = try XCTUnwrap((schema["anyOf"] as? [[String: Any]])?.last)
    let topic = try XCTUnwrap((searched["properties"] as? [String: Any])?["topic"] as? [String: Any])
    XCTAssertEqual(topic["enum"] as? [String], SearchTopic.allCases.map(\.rawValue))
    XCTAssertTrue(SearchTopic.allCases.allSatisfy { !$0.rawValue.contains(" ") })
    let prompt = WebContext.queryPrompt(question: "Will it rain in Montreal tomorrow?", history: [])
    for topic in SearchTopic.allCases { XCTAssertTrue(prompt.contains("- \(topic.rawValue): "), topic.rawValue) }
    XCTAssertTrue(prompt.contains("100 USD to EUR"))
  }

  // MARK: Wikimedia

  /// The message's language decides the edition: English scored 0.77 for this one, under the
  /// 0.8 once required, and French Wikipedia answered with footballers (2026-11-12).
  func testTheMessageLanguagePicksTheEdition() {
    XCTAssertEqual(WebClient.wikipediaLanguage(for: "Who won the 2026 Tour de France?", preferred: ["fr-CA"]), "en")
    XCTAssertEqual(WebClient.wikipediaLanguage(for: "Qui a gagné le Tour de France 2026?", preferred: ["en-US"]), "fr")
    XCTAssertEqual(WebSearchError.unavailable("Apple Weather").errorDescription, "Apple Weather isn't available right now.")
  }

  func testSisterProjectsSearch() throws {
    let results = SearchParsers.mediaWiki(
      json: try fixture("wikivoyage-search", "json"), site: .wikivoyage, language: "en")
    XCTAssertEqual(results.first?.title, "Montreal — Wikivoyage")
    XCTAssertEqual(results.first?.url.absoluteString, "https://en.wikivoyage.org/wiki/Montreal")
    XCTAssertEqual(WikimediaSite.wikivoyage.host(language: "ko"), "en.wikivoyage.org", "No Korean edition")
    XCTAssertEqual(WikimediaSite.wiktionary.host(language: "fr"), "fr.wiktionary.org")
  }

  func testCurrentEventsPages() throws {
    let today = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-12T03:00:00Z"))
    let pages = CurrentEvents.pages(today: today)
    XCTAssertEqual(
      pages.map(\.url.absoluteString),
      [
        "https://en.wikipedia.org/wiki/Portal:Current_events/2026_November_12",
        "https://en.wikipedia.org/wiki/Portal:Current_events/2026_November_11",
        "https://en.wikipedia.org/wiki/Portal:Current_events/2026_November_10",
      ])
    XCTAssertEqual(pages.first?.title, "Current events, 12 November 2026")
    XCTAssertEqual(
      CurrentEvents.sourceURL(of: pages[1])?.absoluteString,
      "https://en.wikipedia.org/w/api.php?action=parse&page=Portal:Current_events/2026_November_11&prop=wikitext&format=json&formatversion=2")
  }

  /// A day's events as plain text: no link or bold markup, bullets indented, outlets kept.
  func testCurrentEventsText() throws {
    let wikitext = try XCTUnwrap(CurrentEvents.wikitext(json: try fixture("current-events", "json")))
    let text = CurrentEvents.text(wikitext: wikitext)
    XCTAssertTrue(text.hasPrefix("Armed conflicts and attacks\n- 2026 Iran war\n  - 2026 Iranian strikes on Oman"), String(text.prefix(300)))
    XCTAssertTrue(text.contains("Iran attacks ship navigation systems on Didamar Island, Oman."), text)
    XCTAssertTrue(text.contains("(Reuters)"))
    for markup in ["[[", "]]", "'''", "{{", "https://"] { XCTAssertFalse(text.contains(markup), markup) }
  }

  func testWikidataFacts() throws {
    XCTAssertEqual(WikidataFacts.itemID(pageprops: try fixture("wikipedia-pageprops", "json")), "Q340")
    let entity = try XCTUnwrap(
      WikidataFacts.entity(json: try fixture("wikidata-entity", "json"), id: "Q340", language: "en"))
    XCTAssertEqual(entity.label, "Montreal")
    // The preferred figure, with its year.
    let population = try XCTUnwrap(entity.facts.first { $0.label == "population" })
    XCTAssertEqual(population.values, [.quantity("1,762,949", unit: nil)])
    XCTAssertEqual(population.asOf, "2021")
    XCTAssertTrue(entity.itemsToLabel.contains("Q16"))
    let text = WikidataFacts.describe(entity, labels: ["Q16": "Canada"])
    XCTAssertTrue(text.contains("country: Canada"), text)
    XCTAssertTrue(text.contains("population: 1,762,949 (2021)"), text)
  }

  func testWikidataDates() {
    XCTAssertEqual(WikidataFacts.date("+2021-05-11T00:00:00Z", precision: 11), "11 May 2021")
    XCTAssertEqual(WikidataFacts.date("+1642-05-17T00:00:00Z", precision: 10), "May 1642")
    XCTAssertEqual(WikidataFacts.date("+1642-00-00T00:00:00Z", precision: 9), "1642")
    XCTAssertEqual(WikidataFacts.date("-0044-03-15T00:00:00Z", precision: 11), "15 March 44 BC")
  }

  // MARK: Exchange rates

  func testExchangeRates() throws {
    let table = try XCTUnwrap(
      ExchangeRates.parse(xml: String(decoding: try fixture("ecb-rates", "xml"), as: UTF8.self)))
    XCTAssertEqual(table.date, "2026-11-12")
    XCTAssertEqual(table.perEuro["USD"], 1.1081)
    XCTAssertEqual(table.perEuro["EUR"], 1)
    let known = Set(table.perEuro.keys)
    let request = try XCTUnwrap(ExchangeRates.request("100 USD to EUR", known: known))
    XCTAssertEqual(request, ExchangeRates.Request(amount: 100, from: "USD", to: ["EUR"]))
    let text = ExchangeRates.describe(table, request: request)
    XCTAssertTrue(text.contains("100 USD = 90.24 EUR"), text)
    XCTAssertTrue(text.contains("1 EUR = 1.1081 USD"), text)
    XCTAssertEqual(
      ExchangeRates.request("convert 1,250.5 euros to yen and CAD", known: known),
      ExchangeRates.Request(amount: 1250.5, from: "EUR", to: ["JPY", "CAD"]))
    XCTAssertNil(ExchangeRates.request("how much is the euro worth", known: known))
    XCTAssertTrue(ExchangeRates.describe(table, request: nil).contains("1 EUR = 1.1081 USD"))
  }

  // MARK: Papers

  func testCrossrefPapers() throws {
    let papers = Crossref.results(json: try fixture("crossref-works", "json"))
    XCTAssertEqual(papers.count, 3)
    let first = try XCTUnwrap(papers.first)
    XCTAssertEqual(first.url.host(), "doi.org")
    let content = try XCTUnwrap(first.content)
    XCTAssertTrue(content.hasPrefix("Effects of Intermittent Fasting on Weight Loss and Cardiometabolic Health"), content)
    XCTAssertFalse(content.contains("<jats:"), content)
    XCTAssertFalse(first.pinned)
  }

  func testPubMedAbstracts() throws {
    XCTAssertEqual(PubMed.ids(json: try fixture("pubmed-search", "json")), ["34379793", "38568487", "29671521"])
    let articles = PubMed.results(xml: String(decoding: try fixture("pubmed-fetch", "xml"), as: UTF8.self))
    XCTAssertEqual(articles.map(\.url.absoluteString).prefix(2), [
      "https://pubmed.ncbi.nlm.nih.gov/34379793/", "https://pubmed.ncbi.nlm.nih.gov/38568487/",
    ])
    let content = try XCTUnwrap(articles.first?.content)
    XCTAssertGreaterThan(content.count, 200, content)
    XCTAssertFalse(content.contains("<AbstractText"), content)
  }

  // MARK: Apple's sources

  func testPlaces() {
    let places = PlaceSearch.results([
      .init(
        name: "Pharmaprix", address: "1500 Avenue du Mont-Royal Est, Montréal QC H2J 1Z2, Canada",
        phone: "+1 514-555-0100", website: URL(string: "https://www.pharmaprix.ca"), category: "pharmacy",
        latitude: 45.5267, longitude: -73.5795)
    ], area: "Place des Arts, Montreal")
    let place = try? XCTUnwrap(places.first)
    XCTAssertEqual(place?.title, "Pharmaprix — Apple Maps")
    XCTAssertTrue(place?.pinned == true)
    XCTAssertEqual(place?.url.host(), "maps.apple.com")
    XCTAssertTrue(place?.url.absoluteString.contains("ll=45.52670,-73.57950") == true)
    XCTAssertTrue(place?.content?.contains("Phone: +1 514-555-0100") == true)
    XCTAssertTrue(place?.content?.contains("Within about 1 km of Place des Arts, Montreal") == true)
    XCTAssertEqual(PlaceSearch.split("pharmacy near Place des Arts, Montreal").what, "pharmacy")
    XCTAssertEqual(PlaceSearch.split("pharmacy near Place des Arts, Montreal").place, "Place des Arts, Montreal")
    XCTAssertNil(PlaceSearch.split("Pharmaprix Montreal").place)
    XCTAssertEqual(PlaceSearch.categoryName(.pharmacy), "pharmacy")
    XCTAssertEqual(PlaceSearch.categoryName(.publicTransport), "public transport")
  }

  func testWeatherText() throws {
    let zone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
    let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-12T19:00:00Z"))
    let report = WeatherLookup.Report(
      place: "Montreal, QC, Canada", timeZone: zone,
      now: .init(
        date: start, temperature: .init(value: 3, unit: .celsius), feelsLike: .init(value: -1, unit: .celsius),
        condition: "Cloudy", windSpeed: .init(value: 15, unit: .kilometersPerHour), humidity: 0.7),
      hours: (1...6).map {
        .init(
          date: start.addingTimeInterval(Double($0) * 3600), temperature: .init(value: 2, unit: .celsius),
          condition: "Rain", precipitationChance: 0.6)
      },
      days: [
        .init(
          date: start.addingTimeInterval(86_400), high: .init(value: 5, unit: .celsius),
          low: .init(value: -1, unit: .celsius), condition: "Snow", precipitationChance: 0.4)
      ])
    // Formatters put narrow no-break spaces before units and "PM".
    let text = WeatherLookup.describe(report, locale: Locale(identifier: "en_CA"))
      .replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    XCTAssertTrue(text.hasPrefix("Weather for Montreal, QC, Canada (local time):"), text)
    XCTAssertTrue(text.contains("Now (2:00"), text)
    XCTAssertTrue(text.contains("3°C") || text.contains("3 °C"), text)
    XCTAssertTrue(text.contains("60 % chance of precipitation"), text)
    XCTAssertTrue(text.contains("snow, high 5"), text)
  }
}
