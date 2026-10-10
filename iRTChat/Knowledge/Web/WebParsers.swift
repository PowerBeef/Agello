import Foundation

/// One search result.
struct WebResult: Equatable, Sendable {
  var title: String
  var url: URL
  var snippet: String

  var domain: String {
    let host = url.host() ?? url.absoluteString
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }
}

/// Parsers for search providers' responses. Pure (fixture-tested).
enum SearchParsers {
  // MARK: DuckDuckGo (HTML results page, unofficial)

  static func duckDuckGo(html: String) -> [WebResult] {
    var results: [WebResult] = []
    // Each result is a "result" container; ads carry "result--ad".
    let blocks = html.components(separatedBy: "<div class=\"result ").dropFirst()
    for block in blocks {
      let head = block.prefix(200)
      if head.contains("result--ad") { continue }
      guard let anchor = HTMLText.firstMatch(#"class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, in: block),
        anchor.count == 2, let url = resolveDuckDuckGoLink(HTMLText.decodeEntities(anchor[0]))
      else { continue }
      let title = HTMLText.plain(anchor[1])
      let snippet = HTMLText.firstMatch(#"class="result__snippet"[^>]*>(.*?)</a>"#, in: block)
        .map { HTMLText.plain($0[0]) } ?? ""
      guard !title.isEmpty else { continue }
      results.append(WebResult(title: title, url: url, snippet: snippet))
    }
    return results
  }

  /// Result links are direct, or redirects like `//duckduckgo.com/l/?uddg=<url>`.
  static func resolveDuckDuckGoLink(_ href: String) -> URL? {
    var link = href
    if link.hasPrefix("//") { link = "https:" + link }
    guard let url = URL(string: link) else { return nil }
    if url.host()?.hasSuffix("duckduckgo.com") == true,
      let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?.first(where: { $0.name == "uddg" })?.value,
      let resolved = URL(string: target)
    {
      return resolved
    }
    guard url.host()?.hasSuffix("duckduckgo.com") != true, url.scheme?.hasPrefix("http") == true
    else { return nil }
    return url
  }

  /// DuckDuckGo shows a bot check instead of results when it rate-limits.
  static func isDuckDuckGoChallenge(_ html: String) -> Bool {
    html.contains("anomaly-modal") || html.contains("challenge-form")
      || (html.contains("Unfortunately, bots use DuckDuckGo") && !html.contains("result__a"))
  }

  // MARK: Wikipedia (MediaWiki search API, official)

  static func wikipedia(json: Data, language: String) -> [WebResult] {
    guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
      let query = object["query"] as? [String: Any],
      let search = query["search"] as? [[String: Any]]
    else { return [] }
    return search.compactMap { item in
      guard let title = item["title"] as? String,
        let url = URL(
          string: "https://\(language).wikipedia.org/wiki/"
            + (title.replacingOccurrences(of: " ", with: "_")
              .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""))
      else { return nil }
      return WebResult(
        title: title, url: url, snippet: HTMLText.plain(item["snippet"] as? String ?? ""))
    }
  }

  // MARK: SearXNG, Brave, Tavily (user-configured)

  static func searxng(json: Data) -> [WebResult] {
    results(json, path: ["results"], title: "title", url: "url", snippet: "content")
  }

  static func brave(json: Data) -> [WebResult] {
    results(json, path: ["web", "results"], title: "title", url: "url", snippet: "description")
  }

  static func tavily(json: Data) -> [WebResult] {
    results(json, path: ["results"], title: "title", url: "url", snippet: "content")
  }

  private static func results(
    _ json: Data, path: [String], title: String, url: String, snippet: String
  ) -> [WebResult] {
    guard var node = try? JSONSerialization.jsonObject(with: json) else { return [] }
    for key in path {
      guard let next = (node as? [String: Any])?[key] else { return [] }
      node = next
    }
    return (node as? [[String: Any]] ?? []).compactMap { item in
      guard let rawTitle = item[title] as? String, let link = item[url] as? String,
        let parsed = URL(string: link), parsed.scheme?.hasPrefix("http") == true
      else { return nil }
      return WebResult(
        title: HTMLText.plain(rawTitle), url: parsed,
        snippet: HTMLText.plain(item[snippet] as? String ?? ""))
    }
  }
}

// MARK: - HTML text helpers

enum HTMLText {
  /// Capture groups of the first match of `pattern` (dot matches newlines).
  static func firstMatch(_ pattern: String, in text: some StringProtocol) -> [String]? {
    let string = String(text)
    guard
      let regex = try? NSRegularExpression(
        pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
      let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string))
    else { return nil }
    return (1..<match.numberOfRanges).compactMap { index in
      Range(match.range(at: index), in: string).map { String(string[$0]) }
    }
  }

  /// Tags removed, entities decoded, whitespace collapsed.
  static func plain(_ html: String) -> String {
    let stripped = html.replacingOccurrences(
      of: "<[^>]+>", with: " ", options: .regularExpression)
    return decodeEntities(stripped)
      .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private static let named: [String: String] = [
    "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–",
    "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“",
    "laquo": "«", "raquo": "»", "copy": "©", "reg": "®", "eacute": "é", "egrave": "è",
    "agrave": "à", "ccedil": "ç", "euro": "€", "middot": "·", "times": "×", "deg": "°",
  ]

  static func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    var output = ""
    var rest = Substring(text)
    while let amp = rest.firstIndex(of: "&") {
      output += rest[..<amp]
      let after = rest[rest.index(after: amp)...]
      guard let semicolon = after.prefix(10).firstIndex(of: ";") else {
        output += "&"
        rest = after
        continue
      }
      let entity = String(after[..<semicolon])
      if let value = named[entity] {
        output += value
      } else if entity.hasPrefix("#x") || entity.hasPrefix("#X"),
        let code = UInt32(entity.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code)
      {
        output.unicodeScalars.append(scalar)
      } else if entity.hasPrefix("#"), let code = UInt32(entity.dropFirst()),
        let scalar = Unicode.Scalar(code)
      {
        output.unicodeScalars.append(scalar)
      } else {
        output += "&" + entity + ";"
      }
      rest = after[after.index(after: semicolon)...]
    }
    return output + rest
  }
}
