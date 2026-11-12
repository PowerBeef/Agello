import Foundation
import NaturalLanguage
import Synchronization

// MARK: - Settings

/// Where searches go. Nothing here needs an API key, the user's or ours (the maintainer's
/// choice, 2026-11-12): Brave Search and Tavily, which took the user's own key, are gone, and a
/// saved choice of either decodes as the default.
enum SearchProvider: String, Codable, CaseIterable, Sendable {
  case duckDuckGo, wikipedia, searxng

  var displayName: String {
    switch self {
    case .duckDuckGo: return "DuckDuckGo"
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
  var provider: SearchProvider = .duckDuckGo
  /// Base URL of the user's SearXNG instance (JSON format enabled).
  var searxngURL = ""

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    allowed = try container.decodeIfPresent(Bool.self, forKey: .allowed) ?? true
    automatic = try container.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
    provider = (try? container.decodeIfPresent(SearchProvider.self, forKey: .provider)) ?? .duckDuckGo
    searxngURL = try container.decodeIfPresent(String.self, forKey: .searxngURL) ?? ""
  }

  /// Providers to try, in order: the chosen one, then DuckDuckGo, then
  /// Wikipedia (official API, rarely blocked).
  func chain() -> [SearchProvider] {
    var chain: [SearchProvider] = []
    if provider == .searxng, URL(string: searxngURL)?.scheme?.hasPrefix("http") == true {
      chain.append(.searxng)
    }
    for fallback in [SearchProvider.duckDuckGo, .wikipedia] where !chain.contains(fallback) {
      chain.append(fallback)
    }
    if provider == .wikipedia { chain = [.wikipedia, .duckDuckGo] }
    return chain
  }
}

// MARK: - Network

enum WebSearchError: LocalizedError, Equatable {
  case offline
  case blocked(String)
  case noResults

  var errorDescription: String? {
    switch self {
    case .offline: return "Web search needs an internet connection."
    case .blocked(let provider): return "\(provider) refused the search (rate limit)."
    case .noResults: return "The web search found nothing."
    }
  }
}

/// HTTP for search and page reading: no cookies or cache, strict timeouts,
/// size caps. Only the queries and page requests leave the device.
struct WebClient: Sendable {
  static let browserAgent =
    "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1"
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

  func search(_ query: String, with provider: SearchProvider, settings: WebSearchSettings)
    async throws -> [WebResult]
  {
    switch provider {
    case .duckDuckGo:
      var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
      components.queryItems = [URLQueryItem(name: "q", value: query)]
      let html = String(decoding: try await get(components.url!, agent: Self.browserAgent), as: UTF8.self)
      if SearchParsers.isDuckDuckGoChallenge(html) { throw WebSearchError.blocked("DuckDuckGo") }
      return SearchParsers.duckDuckGo(html: html)
    case .wikipedia:
      let language = Self.wikipediaLanguage(for: query)
      var components = URLComponents(string: "https://\(language).wikipedia.org/w/api.php")!
      components.queryItems = [
        .init(name: "action", value: "query"), .init(name: "list", value: "search"),
        .init(name: "srsearch", value: query), .init(name: "format", value: "json"),
        .init(name: "srlimit", value: "5"), .init(name: "utf8", value: "1"),
      ]
      return SearchParsers.wikipedia(
        json: try await get(components.url!, agent: Self.appAgent), language: language)
    case .searxng:
      guard var components = URLComponents(string: settings.searxngURL) else { return [] }
      components.path = (components.path.hasSuffix("/") ? components.path : components.path + "/") + "search"
      components.queryItems = [.init(name: "q", value: query), .init(name: "format", value: "json")]
      return SearchParsers.searxng(json: try await get(components.url!, agent: Self.appAgent))
    }
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
      confidence >= 0.8
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
    request.setValue(Self.browserAgent, forHTTPHeaderField: "User-Agent")
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
