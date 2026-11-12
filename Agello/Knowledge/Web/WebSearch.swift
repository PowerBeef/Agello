import Foundation
import NaturalLanguage
import Synchronization

// MARK: - Settings

/// Where searches go. Only sources whose terms permit an app like this one, with no API key,
/// the user's or ours (the maintainer's choices, 2026-11-12; App Review 5.2.2 asks that the app
/// be "specifically permitted" by each service's terms). Gone that day: Brave Search and Tavily
/// (the user's own key) and DuckDuckGo (its HTML results page, read without permission). A saved
/// choice of any of them decodes as the default.
enum SearchProvider: String, Codable, CaseIterable, Sendable {
  case wikipedia, searxng

  var displayName: String {
    switch self {
    case .wikipedia: return "Wikipedia"
    case .searxng: return "SearXNG"
    }
  }
}

/// Web access settings. Search runs only when the user asks (the composer's
/// Search toggle) or, with Automatic on, when the model decides to.
struct WebSearchSettings: Codable, Equatable, Sendable {
  /// Master switch: off means no network access at all for answers.
  var allowed = true
  /// The model may search on its own when a question needs it.
  var automatic = false
  var provider: SearchProvider = .wikipedia
  /// Base URL of the user's SearXNG instance (JSON format enabled).
  var searxngURL = ""

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    allowed = try container.decodeIfPresent(Bool.self, forKey: .allowed) ?? true
    automatic = try container.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
    provider = (try? container.decodeIfPresent(SearchProvider.self, forKey: .provider)) ?? .wikipedia
    searxngURL = try container.decodeIfPresent(String.self, forKey: .searxngURL) ?? ""
  }

  /// Providers to try, in order: the user's SearXNG server when one is set, then Wikipedia
  /// (official API).
  func chain() -> [SearchProvider] {
    if provider == .searxng, URL(string: searxngURL)?.scheme?.hasPrefix("http") == true {
      return [.searxng, .wikipedia]
    }
    return [.wikipedia]
  }
}

// MARK: - Network

enum WebSearchError: LocalizedError, Equatable {
  case offline
  case blocked(String)
  case noResults
  /// A topic's own source failed (Apple Weather before WeatherKit is enabled, say): said plainly,
  /// not answered from unrelated pages.
  case unavailable(String)
  /// "Near me" without the user's location (refused, or no fix in time).
  case locationUnavailable

  var errorDescription: String? {
    switch self {
    case .offline: return "Web search needs an internet connection."
    case .blocked(let provider): return "\(provider) refused the search (rate limit)."
    case .noResults: return "The web search found nothing."
    case .unavailable(let source): return "\(source) isn't available right now."
    case .locationUnavailable:
      return "Agello doesn't have your location. Allow it in Settings → Agello → Location, or name a place."
    }
  }
}

/// HTTP for search and page reading: no cookies or cache, strict timeouts,
/// size caps. Only the queries and page requests leave the device.
struct WebClient: Sendable {
  /// Every request says it's Agello, with a way to reach the project (Wikimedia's User-Agent
  /// policy asks for one, and treats a browser's agent on automated requests as malicious). Until
  /// 2026-11-12 searches and page reads presented themselves as Safari.
  static let appAgent = "Agello/1.0 (on-device assistant; https://github.com/PowerBeef/Agello)"
  static let maxPageBytes = 3_000_000

  let session: URLSession

  init() {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 8
    config.timeoutIntervalForResource = 12
    config.httpCookieStorage = nil
    config.urlCache = nil
    config.waitsForConnectivity = false
    session = URLSession(configuration: config)
  }

  /// One query through `provider`; Wikipedia searches the edition of `language` (the user's
  /// message's, not the query's: "2026 Tour de France winner" reads as French, and French
  /// Wikipedia answered with footballers, 2026-11-12).
  func search(
    _ query: String, with provider: SearchProvider, settings: WebSearchSettings, language: String
  ) async throws -> [WebResult] {
    switch provider {
    case .wikipedia:
      return try await searchWiki(query, site: .wikipedia, language: language)
    case .searxng:
      guard var components = URLComponents(string: settings.searxngURL) else { return [] }
      components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + "search"
      components.queryItems = [.init(name: "q", value: query), .init(name: "format", value: "json")]
      return SearchParsers.searxng(json: try await get(components.url!, agent: Self.appAgent))
    }
  }

  // MARK: Reference sources (SearchTopic)

  /// A MediaWiki search on one of the Wikimedia projects, in `language`'s edition.
  func searchWiki(_ query: String, site: WikimediaSite, language: String) async throws -> [WebResult] {
    var components = URLComponents(string: "https://\(site.host(language: language))/w/api.php")!
    // A quotation is found by its exact words: searched as loose words, "The only thing we have
    // to fear is fear itself" found the Bene Gesserit (2026-11-12).
    let phrase = site == .wikiquote && !query.contains("\"") ? "\"\(query)\"" : query
    components.queryItems = [
      .init(name: "action", value: "query"), .init(name: "list", value: "search"),
      .init(name: "srsearch", value: phrase), .init(name: "format", value: "json"),
      .init(name: "srlimit", value: "5"), .init(name: "utf8", value: "1"),
    ]
    return SearchParsers.mediaWiki(
      json: try await get(components.url!, agent: Self.appAgent), site: site, language: language)
  }

  /// The answer of a structured topic's source (weather, places, exchange rates), pinned.
  func structured(_ topic: SearchTopic, query: String) async throws -> [WebResult] {
    switch topic {
    case .weather:
      guard let report = try await WeatherLookup.report(for: query) else { return [] }
      let attribution = await WeatherLookup.attribution()
      return [
        WebResult(
          title: "\(attribution.name) — \(report.place)", url: attribution.url, snippet: "",
          content: WeatherLookup.describe(report), pinned: true)
      ]
    case .place:
      let found = try await PlaceSearch.search(query)
      return PlaceSearch.results(found.places, area: found.area)
    case .currency:
      let xml = String(decoding: try await get(ExchangeRates.dataURL, agent: Self.appAgent), as: UTF8.self)
      guard let table = ExchangeRates.parse(xml: xml) else { return [] }
      return [
        WebResult(
          title: "Euro reference rates — European Central Bank", url: ExchangeRates.sourceURL, snippet: "",
          content: ExchangeRates.describe(table, request: ExchangeRates.request(query, known: Set(table.perEuro.keys))),
          pinned: true)
      ]
    default:
      return []
    }
  }

  /// Scientific papers with their abstracts, from Crossref.
  func crossref(_ query: String) async throws -> [WebResult] {
    guard let url = Crossref.searchURL(query) else { return [] }
    return Crossref.results(json: try await get(url, agent: Self.appAgent))
  }

  /// Medical papers with their abstracts, from PubMed (a search, then the abstracts).
  func pubMed(_ query: String) async throws -> [WebResult] {
    guard let reviewed = PubMed.searchURL(query) else { return [] }
    var ids = PubMed.ids(json: try await get(reviewed, agent: Self.appAgent))
    if ids.isEmpty, let any = PubMed.searchURL(query, reviewed: false) {
      ids = PubMed.ids(json: try await get(any, agent: Self.appAgent))
    }
    guard !ids.isEmpty, let fetch = PubMed.fetchURL(ids: ids) else { return [] }
    return PubMed.results(xml: String(decoding: try await get(fetch, agent: Self.appAgent), as: UTF8.self))
  }

  /// A day of Wikipedia's Current events, as text.
  func currentEvents(_ page: WebResult) async throws -> WebResult? {
    guard let url = CurrentEvents.sourceURL(of: page),
      let wikitext = CurrentEvents.wikitext(json: try await get(url, agent: Self.appAgent))
    else { return nil }
    let text = CurrentEvents.text(wikitext: wikitext)
    guard !text.isEmpty else { return nil }
    return WebResult(title: page.title, url: page.url, snippet: "", content: "\(page.title):\n\(text)")
  }

  /// Wikidata's facts about a Wikipedia article's subject: its item, its statements, then the
  /// labels of the items they name.
  func wikidataFacts(title: String, language: String) async throws -> WebResult? {
    var pageprops = URLComponents(string: "https://\(WikimediaSite.wikipedia.host(language: language))/w/api.php")!
    pageprops.queryItems = [
      .init(name: "action", value: "query"), .init(name: "prop", value: "pageprops"),
      .init(name: "ppprop", value: "wikibase_item"), .init(name: "titles", value: title),
      .init(name: "format", value: "json"),
    ]
    guard let id = WikidataFacts.itemID(pageprops: try await get(pageprops.url!, agent: Self.appAgent)) else {
      return nil
    }
    let languages = language == "en" ? "en" : "\(language)|en"
    func entities(_ ids: [String], props: String) -> URL {
      var components = URLComponents(string: "https://www.wikidata.org/w/api.php")!
      components.queryItems = [
        .init(name: "action", value: "wbgetentities"), .init(name: "ids", value: ids.joined(separator: "|")),
        .init(name: "props", value: props), .init(name: "languages", value: languages),
        .init(name: "format", value: "json"),
      ]
      return components.url!
    }
    guard
      let entity = WikidataFacts.entity(
        json: try await get(entities([id], props: "labels|descriptions|claims"), agent: Self.appAgent),
        id: id, language: language),
      !entity.facts.isEmpty
    else { return nil }
    let needed = Array(entity.itemsToLabel.prefix(50))
    let labels =
      needed.isEmpty
      ? [:] : WikidataFacts.labels(json: try await get(entities(needed, props: "labels"), agent: Self.appAgent), language: language)
    let text = WikidataFacts.describe(entity, labels: labels)
    guard let url = URL(string: "https://www.wikidata.org/wiki/\(id)") else { return nil }
    return WebResult(
      title: "\(entity.label ?? title) — Wikidata", url: url, snippet: entity.description ?? "", content: text)
  }

  /// The Wikipedia edition for `query`: its language when that's clear, else the device's.
  static func wikipediaLanguage(
    for query: String, preferred: [String] = Locale.preferredLanguages
  ) -> String {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(query)
    // A name or a single word says little about the language it's asked in.
    let words = query.split(whereSeparator: \.isWhitespace).count
    let dense = query.unicodeScalars.contains { Chunker.isDense($0) }
    if words >= 3 || dense, let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
      confidence >= 0.6
    {
      return wikipediaCode(language.rawValue)
    }
    return preferred.first.map(wikipediaCode) ?? "en"
  }

  /// "zh-Hans" and "zh-Hant-TW" are "zh"; Norwegian Bokmål is "no".
  private static func wikipediaCode(_ identifier: String) -> String {
    let code = String(identifier.prefix { $0 != "-" && $0 != "_" }).lowercased()
    return code == "nb" ? "no" : code
  }

  /// A page's readable text, or nil (not HTML, too large, failed, slow). The type and declared
  /// size are checked before the body is read, which stops at ``maxPageBytes``.
  func readPage(_ url: URL) async -> ReadableText.Page? {
    var request = URLRequest(url: url, timeoutInterval: 7)
    request.setValue(Self.appAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
    guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
      (http.value(forHTTPHeaderField: "Content-Type") ?? "text/html").contains("html"),
      http.expectedContentLength <= Int64(Self.maxPageBytes)
    else {
      bytes.task.cancel()
      return nil
    }
    var data = Data()
    data.reserveCapacity(Int(min(max(0, http.expectedContentLength), Int64(Self.maxPageBytes))))
    do {
      for try await byte in bytes {
        data.append(byte)
        if data.count > Self.maxPageBytes {
          bytes.task.cancel()
          return nil
        }
      }
    } catch {
      return nil
    }
    let html = TextDecoding.decode(
      data, declared: http.textEncodingName ?? TextDecoding.htmlCharset(in: data))
    let page = ReadableText.extract(html: html)
    return page.text.count >= 200 ? page : nil
  }

  private func get(_ url: URL, agent: String, headers: [String: String] = [:]) async throws -> Data {
    var request = URLRequest(url: url)
    request.setValue(agent, forHTTPHeaderField: "User-Agent")
    for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
    return try await send(request)
  }

  private func send(_ request: URLRequest) async throws -> Data {
    do {
      let (data, response) = try await session.data(for: request)
      if let http = response as? HTTPURLResponse {
        if http.statusCode == 429 || http.statusCode == 403 || http.statusCode == 202 {
          throw WebSearchError.blocked(request.url?.host() ?? "The search provider")
        }
        guard (200...299).contains(http.statusCode) else { throw WebSearchError.noResults }
      }
      return data
    } catch let error as URLError
      where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(error.code)
    {
      throw WebSearchError.offline
    }
  }
}

// MARK: - Sources recorded by the automatic web_search tool

/// Sources found by the `web_search` tool during the current reply (the
/// tool runs inside LiteRT-LM's stream; the app attaches these afterwards).
enum WebSourcesRecorder {
  private static let sources = Mutex<[SourceRecord]>([])

  static func reset() { sources.withLock { $0 = [] } }

  static var nextIndex: Int { sources.withLock { $0.count + 1 } }

  static func record(_ new: [SourceRecord]) { sources.withLock { $0 += new } }

  static func drain() -> [SourceRecord] {
    sources.withLock { all in
      defer { all = [] }
      return all
    }
  }
}
