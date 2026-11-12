import Foundation

/// One search result: a page to read, or a structured source's text (`content`).
struct WebResult: Equatable, Sendable {
  var title: String
  var url: URL
  var snippet: String
  /// What the model reads instead of the page (weather, exchange rates, a paper's abstract).
  var content: String?
  /// Read first and always kept: the answer itself (weather, a conversion, places), not one
  /// passage among many.
  var pinned = false

  init(title: String, url: URL, snippet: String, content: String? = nil, pinned: Bool = false) {
    self.title = title
    self.url = url
    self.snippet = snippet
    self.content = content
    self.pinned = pinned
  }

  var domain: String {
    let host = url.host() ?? url.absoluteString
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }
}

/// Parsers for search providers' responses. Pure (fixture-tested).
enum SearchParsers {
  // MARK: Wikimedia projects (MediaWiki search API, official)

  static func wikipedia(json: Data, language: String) -> [WebResult] {
    mediaWiki(json: json, site: .wikipedia, language: language)
  }

  /// A MediaWiki search's results on `site`; titles name the site when it isn't Wikipedia
  /// ("Montreal — Wikivoyage"), so the reply's sources say where each came from.
  static func mediaWiki(json: Data, site: WikimediaSite, language: String) -> [WebResult] {
    guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
      let query = object["query"] as? [String: Any],
      let search = query["search"] as? [[String: Any]]
    else { return [] }
    return search.compactMap { item in
      guard let title = item["title"] as? String, let url = site.pageURL(title: title, language: language)
      else { return nil }
      return WebResult(
        title: site == .wikipedia ? title : "\(title) — \(site.displayName)", url: url,
        snippet: HTMLText.plain(item["snippet"] as? String ?? ""))
    }
  }

  // MARK: SearXNG (the user's own server)

  static func searxng(json: Data) -> [WebResult] {
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
