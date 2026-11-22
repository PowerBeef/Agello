import Darwin
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
    let address = searxngURL.trimmingCharacters(in: .whitespaces)
    if provider == .searxng, !address.isEmpty, Self.searxngProblem(address) == nil {
      return [.searxng, .wikipedia]
    }
    return [.wikipedia]
  }

  /// Why a SearXNG address can't work, for Settings; nil when it can. An instance reached by IP
  /// address or a local name failed silently (iOS blocks those connections for apps since iOS 17)
  /// and every search went to Wikipedia (2026-11-16).
  static func searxngProblem(_ address: String) -> String? {
    let trimmed = address.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
      let host = url.host, !host.isEmpty
    else { return String(localized: "Enter an address that starts with https://.") }
    guard WebHost.isPublic(host) else {
      return String(
        localized: "iOS doesn't let apps reach a server by IP address or local name. Use its domain name, like https://searx.example.org.")
    }
    return nil
  }
}

/// Hosts the open web serves. Pages are read only from those: a search result or a shared link
/// can't point the app at the user's own network (an external review, 2026-11-16).
enum WebHost {
  enum DNSVerdict: Equatable, Sendable {
    case publicOnly
    case privateOrLoopback
    case unresolved
  }

  static func isPublic(_ host: String) -> Bool {
    var name = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while name.hasSuffix(".") { name.removeLast() }
    guard !name.isEmpty, name != "localhost", !name.contains(":") else { return false }
    // Reject all IPv4 literal forms (decimal, hex-dotted `0x7f.0.0.1`, octal, shorthand `127.1`, integer).
    var v4 = in_addr()
    if inet_aton(name, &v4) != 0 { return false }
    // Reject IPv6 literals even if bracketed.
    var v6 = in6_addr()
    let stripped = name.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if inet_pton(AF_INET6, stripped, &v6) == 1 { return false }
    let labels = name.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, !labels.contains(where: \.isEmpty) else { return false }
    // Require a valid public-looking alphabetic (or punycode `xn--`) TLD of length >= 2.
    guard let tld = labels.last, tld.count >= 2,
      tld.allSatisfy({ $0.isASCII && $0.isLetter }) || tld.hasPrefix("xn--")
    else { return false }
    let local: Set<String> = [
      "localhost", "local", "localdomain", "internal", "lan", "home", "intranet", "corp", "arpa",
    ]
    return !local.contains(String(tld))
  }

  /// An http(s) URL on a public host, without credentials.
  static func isPublicPage(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
      url.user == nil, url.password == nil, let host = url.host
    else { return false }
    return isPublic(host)
  }

  /// True if a host-byte-order IPv4 address is globally routable (not loopback, RFC1918, link-local,
  /// CGNAT, multicast, or reserved).
  static func isPublicIPv4(_ hostOrder: UInt32) -> Bool {
    let a = (hostOrder >> 24) & 0xFF
    let b = (hostOrder >> 16) & 0xFF
    let c = (hostOrder >> 8) & 0xFF
    if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
    if a == 100 && (b >= 64 && b <= 127) { return false }  // CGNAT 100.64.0.0/10
    if a == 169 && b == 254 { return false }  // link-local
    if a == 172 && (b >= 16 && b <= 31) { return false }  // RFC1918
    if a == 192 && b == 168 { return false }  // RFC1918
    if a == 192 && b == 0 && (c == 0 || c == 2) { return false }
    if a == 198 && (b == 18 || b == 19) { return false }
    if a == 198 && b == 51 && c == 100 { return false }
    if a == 203 && b == 0 && c == 113 { return false }
    return true
  }

  /// True if an IPv6 address (16 raw network-order bytes) is globally routable.
  static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
    guard bytes.count == 16 else { return false }
    if bytes.allSatisfy({ $0 == 0 }) { return false }  // ::
    if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return false }  // ::1
    if (bytes[0] & 0xFE) == 0xFC { return false }  // fc00::/7 ULA
    if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return false }  // fe80::/10 link-local
    if bytes[0] == 0xFF { return false }  // ff00::/8 multicast
    // IPv4-mapped ::ffff:0:0/96 or NAT64 64:ff9b::/96.
    let isV4Mapped = bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF
    let isNAT64 = bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xFF && bytes[3] == 0x9B
      && bytes[4..<12].allSatisfy({ $0 == 0 })
    if isV4Mapped || isNAT64 {
      let ipv4 =
        (UInt32(bytes[12]) << 24) | (UInt32(bytes[13]) << 16)
        | (UInt32(bytes[14]) << 8) | UInt32(bytes[15])
      return isPublicIPv4(ipv4)
    }
    return true
  }

  /// Resolves `host` via `getaddrinfo` off-thread and verifies every returned IP is public.
  static func verifyResolvedAddresses(_ host: String) async -> DNSVerdict {
    await Task.detached(priority: .utility) {
      var hints = addrinfo()
      hints.ai_family = AF_UNSPEC
      hints.ai_socktype = SOCK_STREAM
      var result: UnsafeMutablePointer<addrinfo>?
      guard getaddrinfo(host, nil, &hints, &result) == 0, let head = result else {
        return DNSVerdict.unresolved
      }
      defer { freeaddrinfo(head) }
      var sawAddress = false
      var cursor: UnsafeMutablePointer<addrinfo>? = head
      while let current = cursor {
        let info = current.pointee
        if info.ai_family == AF_INET, let sa = info.ai_addr {
          sawAddress = true
          let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
          if !isPublicIPv4(UInt32(bigEndian: addr.s_addr)) { return .privateOrLoopback }
        } else if info.ai_family == AF_INET6, let sa = info.ai_addr {
          sawAddress = true
          var addr6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
            $0.pointee.sin6_addr
          }
          let bytes = withUnsafeBytes(of: &addr6) { Array($0) }
          if !isPublicIPv6(bytes) { return .privateOrLoopback }
        }
        cursor = info.ai_next
      }
      return sawAddress ? .publicOnly : .unresolved
    }.value
  }
}

/// Follows a redirect only to a public page (``WebHost``) resolving exclusively to public IPs.
final class PublicRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  static let shared = PublicRedirects()

  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest
  ) async -> URLRequest? {
    guard let url = request.url, WebHost.isPublicPage(url), let host = url.host else { return nil }
    guard await WebHost.verifyResolvedAddresses(host) == .publicOnly else { return nil }
    return request
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
      return SearchParsers.searxng(json: try await get(Self.url(components), agent: Self.appAgent))
    }
  }

  // MARK: Reference sources (SearchTopic)

  /// A MediaWiki search on one of the Wikimedia projects, in `language`'s edition.
  func searchWiki(_ query: String, site: WikimediaSite, language: String) async throws -> [WebResult] {
    guard var components = URLComponents(string: "https://\(site.host(language: language))/w/api.php") else {
      throw URLError(.badURL)
    }
    // A quotation is found by its exact words: searched as loose words, "The only thing we have
    // to fear is fear itself" found the Bene Gesserit (2026-11-12).
    let phrase = site == .wikiquote && !query.contains("\"") ? "\"\(query)\"" : query
    components.queryItems = [
      .init(name: "action", value: "query"), .init(name: "list", value: "search"),
      .init(name: "srsearch", value: phrase), .init(name: "format", value: "json"),
      .init(name: "srlimit", value: "5"), .init(name: "utf8", value: "1"),
    ]
    return SearchParsers.mediaWiki(
      json: try await get(Self.url(components), agent: Self.appAgent), site: site, language: language)
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
    guard var pageprops = URLComponents(string: "https://\(WikimediaSite.wikipedia.host(language: language))/w/api.php")
    else { throw URLError(.badURL) }
    pageprops.queryItems = [
      .init(name: "action", value: "query"), .init(name: "prop", value: "pageprops"),
      .init(name: "ppprop", value: "wikibase_item"), .init(name: "titles", value: title),
      .init(name: "format", value: "json"),
    ]
    guard let id = WikidataFacts.itemID(pageprops: try await get(Self.url(pageprops), agent: Self.appAgent)) else {
      return nil
    }
    let languages = language == "en" ? "en" : "\(language)|en"
    func entities(_ ids: [String], props: String) throws -> URL {
      var components = URLComponents()
      components.scheme = "https"
      components.host = "www.wikidata.org"
      components.path = "/w/api.php"
      components.queryItems = [
        .init(name: "action", value: "wbgetentities"), .init(name: "ids", value: ids.joined(separator: "|")),
        .init(name: "props", value: props), .init(name: "languages", value: languages),
        .init(name: "format", value: "json"),
      ]
      return try Self.url(components)
    }
    guard
      let entity = WikidataFacts.entity(
        json: try await get(try entities([id], props: "labels|descriptions|claims"), agent: Self.appAgent),
        id: id, language: language),
      !entity.facts.isEmpty
    else { return nil }
    let needed = Array(entity.itemsToLabel.prefix(50))
    let labels =
      needed.isEmpty
      ? [:] : WikidataFacts.labels(json: try await get(try entities(needed, props: "labels"), agent: Self.appAgent), language: language)
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

  /// A built request's URL, or a thrown error instead of a crash.
  private static func url(_ components: URLComponents) throws -> URL {
    guard let url = components.url else { throw URLError(.badURL) }
    return url
  }

  /// A page's readable text, or nil (not HTML, too large, failed, slow). The type and declared
  /// size are checked before the body is read, which stops at ``maxPageBytes``.
  func readPage(_ url: URL) async -> ReadableText.Page? {
    guard WebHost.isPublicPage(url), let host = url.host,
      await WebHost.verifyResolvedAddresses(host) == .publicOnly
    else { return nil }
    var request = URLRequest(url: url, timeoutInterval: 7)
    request.setValue(Self.appAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
    // A refused redirect returns the 3xx itself, which is turned away below.
    guard let (bytes, response) = try? await session.bytes(for: request, delegate: PublicRedirects.shared)
    else { return nil }
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
      (http.value(forHTTPHeaderField: "Content-Type") ?? "text/html").lowercased().contains("html"),
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
    guard let url = request.url, WebHost.isPublicPage(url), let host = url.host else {
      throw WebSearchError.noResults
    }
    if await WebHost.verifyResolvedAddresses(host) == .privateOrLoopback {
      throw WebSearchError.noResults
    }
    do {
      let (bytes, response) = try await session.bytes(for: request, delegate: PublicRedirects.shared)
      if let http = response as? HTTPURLResponse {
        if http.statusCode == 429 || http.statusCode == 403 || http.statusCode == 202 {
          bytes.task.cancel()
          throw WebSearchError.blocked(request.url?.host() ?? "The search provider")
        }
        guard (200...299).contains(http.statusCode),
          http.expectedContentLength <= Int64(Self.maxPageBytes)
        else {
          bytes.task.cancel()
          throw WebSearchError.noResults
        }
      }
      var data = Data()
      let expected = (response as? HTTPURLResponse)?.expectedContentLength ?? 0
      data.reserveCapacity(Int(min(max(0, expected), Int64(Self.maxPageBytes))))
      for try await byte in bytes {
        data.append(byte)
        if data.count > Self.maxPageBytes {
          bytes.task.cancel()
          throw WebSearchError.noResults
        }
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
