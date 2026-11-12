import Foundation

// Parsers and formatters for the reference sources behind Search (``SearchTopic``). Pure
// (fixture-tested): the requests are in ``WebClient``. Each source's terms were read on
// 2026-11-12 (ROADMAP, "Current status"): free, no API key, an app like this one permitted. A
// structured source's text is what the model reads, and its link what the reply cites.

// MARK: - Wikimedia sites

/// The Wikimedia projects searched through the MediaWiki API: one API, one set of terms (CC BY-SA
/// or CC0, commercial use allowed, credit by link) and one honest User-Agent.
enum WikimediaSite: String, Sendable {
  case wikipedia, wikivoyage, wiktionary, wikiquote

  func host(language: String) -> String { "\(edition(for: language)).\(rawValue).org" }

  /// The name a source's title ends with ("Montreal — Wikivoyage").
  var displayName: String {
    switch self {
    case .wikipedia: return "Wikipedia"
    case .wikivoyage: return "Wikivoyage"
    case .wiktionary: return "Wiktionary"
    case .wikiquote: return "Wikiquote"
    }
  }

  /// The edition searched for a language: Wikivoyage has fewer, and the rest search English.
  func edition(for language: String) -> String {
    guard self == .wikivoyage else { return language }
    let editions: Set = [
      "en", "de", "fr", "it", "es", "nl", "pt", "ru", "pl", "sv", "zh", "ja", "fi", "he", "uk", "vi",
      "tr", "fa", "el", "ro",
    ]
    return editions.contains(language) ? language : "en"
  }

  /// A page's address on this site ("Portal:Current_events", the colon kept as Wikipedia writes it).
  func pageURL(title: String, language: String) -> URL? {
    var allowed = CharacterSet.urlPathAllowed
    allowed.insert(":")
    let path = title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    return URL(string: "https://\(host(language: language))/wiki/\(path)")
  }

  /// The MediaWiki API on this site.
  func apiURL(language: String, _ items: [URLQueryItem]) -> URL? {
    var components = URLComponents(string: "https://\(host(language: language))/w/api.php")
    components?.queryItems = items + [.init(name: "format", value: "json"), .init(name: "formatversion", value: "2")]
    return components?.url
  }
}

/// Wikipedia's Current events portal: one page a day, in English, read as its wiki source (the
/// rendered page's text came back as markup, 2026-11-12).
enum CurrentEvents {
  private static let months = [
    "January", "February", "March", "April", "May", "June", "July", "August", "September",
    "October", "November", "December",
  ]

  /// The daily pages of the last `days` days up to `today` (UTC), newest first.
  static func pages(today: Date = .now, days: Int = 3) -> [WebResult] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return (0..<days).compactMap { offset in
      guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
      let parts = calendar.dateComponents([.year, .month, .day], from: day)
      guard let year = parts.year, let month = parts.month, let date = parts.day,
        let url = WikimediaSite.wikipedia.pageURL(
          title: "Portal:Current events/\(year) \(months[month - 1]) \(date)", language: "en")
      else { return nil }
      return WebResult(title: "Current events, \(date) \(months[month - 1]) \(year)", url: url, snippet: "")
    }
  }

  /// The API request for a day's wiki source.
  static func sourceURL(of page: WebResult) -> URL? {
    let path = page.url.path()
    guard path.hasPrefix("/wiki/") else { return nil }
    let name = String(path.dropFirst(6))
    return WikimediaSite.wikipedia.apiURL(
      language: "en",
      [.init(name: "action", value: "parse"), .init(name: "page", value: name.removingPercentEncoding ?? name),
        .init(name: "prop", value: "wikitext")])
  }

  /// The wikitext of `action=parse&prop=wikitext`.
  static func wikitext(json: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
    return (object["parse"] as? [String: Any])?["wikitext"] as? String
  }

  /// A day's events as plain text: headings, then indented bullets, link markup dropped, the
  /// news outlets kept in parentheses.
  static func text(wikitext: String) -> String {
    var text = wikitext.replacingOccurrences(of: "(?s)<!--.*?-->", with: "", options: .regularExpression)
    // Templates, innermost first.
    while let range = text.range(of: #"\{\{[^{}]*\}\}"#, options: .regularExpression) { text.removeSubrange(range) }
    text = text.replacingOccurrences(of: #"\[\[[^\]|]*\|([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\[\[([^\]]*)\]\]"#, with: "$1", options: .regularExpression)
    text = text.replacingOccurrences(of: #"\[https?://[^\s\]]+\s+([^\]]*)\]"#, with: "$1", options: .regularExpression)
    text = text.replacingOccurrences(of: "'''", with: "").replacingOccurrences(of: "''", with: "")
    let lines = text.components(separatedBy: "\n").compactMap { raw -> String? in
      let line = raw.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { return nil }
      let depth = line.prefix { $0 == "*" }.count
      guard depth > 0 else { return line }
      let body = line.dropFirst(depth).trimmingCharacters(in: .whitespaces)
      return String(repeating: "  ", count: depth - 1) + "- " + body
    }
    return lines.joined(separator: "\n")
  }
}

// MARK: - Exchange rates (European Central Bank)

/// The ECB's euro reference rates: one small daily file, free to reuse with the ECB cited as the
/// source, "for information purposes only".
enum ExchangeRates {
  static let sourceURL = URL(
    string: "https://www.ecb.europa.eu/stats/policy_and_exchange_rates/euro_reference_exchange_rates/html/index.en.html")!
  static let dataURL = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!

  struct Table: Equatable, Sendable {
    /// The day the rates were set (yyyy-MM-dd).
    var date: String
    /// Units of each currency per euro, the euro included.
    var perEuro: [String: Double]
  }

  static func parse(xml: String) -> Table? {
    guard let date = HTMLText.firstMatch(#"time=['"](\d{4}-\d{2}-\d{2})['"]"#, in: xml)?.first,
      let regex = try? NSRegularExpression(pattern: #"currency=['"]([A-Z]{3})['"]\s+rate=['"]([0-9.]+)['"]"#)
    else { return nil }
    var rates = ["EUR": 1.0]
    for match in regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
      guard let code = Range(match.range(at: 1), in: xml), let rate = Range(match.range(at: 2), in: xml),
        let value = Double(xml[rate]), value > 0
      else { continue }
      rates[String(xml[code])] = value
    }
    return rates.count > 1 ? Table(date: date, perEuro: rates) : nil
  }

  struct Request: Equatable, Sendable {
    var amount: Double
    var from: String
    var to: [String]
  }

  /// Currency names the planner may write instead of codes.
  private static let names: [String: String] = [
    "euro": "EUR", "euros": "EUR", "dollar": "USD", "dollars": "USD", "pound": "GBP", "pounds": "GBP",
    "sterling": "GBP", "yen": "JPY", "franc": "CHF", "francs": "CHF", "yuan": "CNY", "renminbi": "CNY",
    "rupee": "INR", "rupees": "INR", "won": "KRW", "real": "BRL", "reais": "BRL", "peso": "MXN",
    "pesos": "MXN", "krona": "SEK", "kronor": "SEK", "zloty": "PLN", "lira": "TRY",
  ]

  /// "100 USD to EUR", "convert 250 euros to yen and CAD": an amount (1 when none) and the
  /// currencies in order, codes the ECB publishes. Nil without two currencies.
  static func request(_ text: String, known: Set<String>) -> Request? {
    let words = text.replacingOccurrences(of: ",", with: "").split { !$0.isLetter && !$0.isNumber && $0 != "." }
    var amount: Double?
    var codes: [String] = []
    for word in words {
      if amount == nil, let number = Double(word) {
        amount = number
        continue
      }
      let upper = word.uppercased()
      let code = known.contains(upper) && word.count == 3 ? upper : names[word.lowercased()]
      if let code, !codes.contains(code) { codes.append(code) }
    }
    guard codes.count >= 2 else { return nil }
    return Request(amount: amount ?? 1, from: codes[0], to: Array(codes.dropFirst()))
  }

  /// The source's text: the conversion asked for, with both rates, or the main rates.
  static func describe(_ table: Table, request: Request?) -> String {
    var lines = [
      "Euro foreign exchange reference rates of the European Central Bank for \(table.date), set around 16:00 CET on working days, for information only."
    ]
    if let request, let from = table.perEuro[request.from] {
      for code in request.to {
        guard let to = table.perEuro[code] else {
          lines.append("The ECB publishes no rate for \(code).")
          continue
        }
        let rate = to / from
        lines.append("\(number(request.amount)) \(request.from) = \(number(request.amount * rate)) \(code)")
        lines.append("1 \(request.from) = \(number(rate, digits: 4)) \(code); 1 \(code) = \(number(1 / rate, digits: 4)) \(request.from)")
      }
    } else {
      for code in ["USD", "GBP", "JPY", "CHF", "CAD", "AUD", "CNY"] {
        if let rate = table.perEuro[code] { lines.append("1 EUR = \(number(rate, digits: 4)) \(code)") }
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func number(_ value: Double, digits: Int = 2) -> String {
    value.formatted(.number.precision(.fractionLength(0...digits)).locale(Locale(identifier: "en_US")))
  }
}

// MARK: - Research papers (Crossref)

/// Crossref's REST API: scholarly metadata, no sign-up, any use permitted; requests go to the
/// public pool (no address of ours pools every phone's requests).
enum Crossref {
  static func searchURL(_ query: String) -> URL? {
    var components = URLComponents(string: "https://api.crossref.org/works")
    components?.queryItems = [
      .init(name: "query", value: query), .init(name: "rows", value: "5"),
      .init(name: "filter", value: "has-abstract:true"),
      .init(name: "select", value: "DOI,title,author,issued,container-title,abstract"),
    ]
    return components?.url
  }

  static func results(json: Data) -> [WebResult] {
    guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
      let message = object["message"] as? [String: Any],
      let items = message["items"] as? [[String: Any]]
    else { return [] }
    return items.compactMap { item in
      guard let title = (item["title"] as? [String])?.first.map(HTMLText.plain), !title.isEmpty,
        let doi = item["DOI"] as? String,
        let url = URL(string: "https://doi.org/\(doi)")
      else { return nil }
      let year = ((item["issued"] as? [String: Any])?["date-parts"] as? [[Int]])?.first?.first
      let journal = (item["container-title"] as? [String])?.first
      let authors = (item["author"] as? [[String: Any]] ?? []).compactMap { author -> String? in
        let name = [author["given"] as? String, author["family"] as? String].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? nil : name
      }
      let abstract = HTMLText.plain((item["abstract"] as? String ?? "")
        .replacingOccurrences(of: "<jats:title>Abstract</jats:title>", with: ""))
      let credit = [journal, year.map(String.init)].compactMap { $0 }.joined(separator: ", ")
      let byline = authors.isEmpty ? "" : "\nBy " + authors.prefix(3).joined(separator: ", ") + (authors.count > 3 ? " et al." : "")
      let content = "\(title)\(credit.isEmpty ? "" : " (\(credit))")\(byline)\n\(abstract)"
      return WebResult(title: title, url: url, snippet: String(abstract.prefix(240)), content: content)
    }
  }
}

// MARK: - Medicine (PubMed)

/// NCBI's E-utilities for PubMed: no key (3 requests a second), the tool named on each request.
/// NLM claims no copyright on abstracts; each is cited with its PubMed page.
enum PubMed {
  static let tool = "Agello"

  /// Reviews and systematic reviews with an abstract first (`reviewed`); "metformin side
  /// effects" by best match alone led with a paper on another drug (2026-11-12).
  static func searchURL(_ query: String, reviewed: Bool = true) -> URL? {
    var components = URLComponents(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi")
    let term = reviewed ? "(\(query)) AND hasabstract AND (review[pt] OR systematic[sb])" : query
    components?.queryItems = [
      .init(name: "db", value: "pubmed"), .init(name: "term", value: term), .init(name: "retmax", value: "5"),
      .init(name: "retmode", value: "json"), .init(name: "sort", value: "relevance"), .init(name: "tool", value: tool),
    ]
    return components?.url
  }

  static func fetchURL(ids: [String]) -> URL? {
    var components = URLComponents(string: "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi")
    components?.queryItems = [
      .init(name: "db", value: "pubmed"), .init(name: "id", value: ids.joined(separator: ",")),
      .init(name: "retmode", value: "xml"), .init(name: "tool", value: tool),
    ]
    return components?.url
  }

  static func ids(json: Data) -> [String] {
    guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
      let result = object["esearchresult"] as? [String: Any]
    else { return [] }
    return result["idlist"] as? [String] ?? []
  }

  static func results(xml: String) -> [WebResult] {
    xml.components(separatedBy: "<PubmedArticle>").dropFirst().compactMap { article in
      guard let pmid = HTMLText.firstMatch(#"<PMID[^>]*>(\d+)</PMID>"#, in: article)?.first,
        let rawTitle = HTMLText.firstMatch(#"<ArticleTitle[^>]*>(.*?)</ArticleTitle>"#, in: article)?.first,
        let url = URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/")
      else { return nil }
      let title = HTMLText.plain(rawTitle)
      let journal = HTMLText.firstMatch(#"<Journal>.*?<Title>(.*?)</Title>"#, in: article).map { HTMLText.plain($0[0]) }
      let year = HTMLText.firstMatch(#"<PubDate>.*?<Year>(\d{4})</Year>"#, in: article)?.first
      var sections: [String] = []
      if let regex = try? NSRegularExpression(
        pattern: #"<AbstractText(?:[^>]*Label="([^"]*)")?[^>]*>(.*?)</AbstractText>"#, options: .dotMatchesLineSeparators)
      {
        for match in regex.matches(in: article, range: NSRange(article.startIndex..., in: article)) {
          let label = Range(match.range(at: 1), in: article).map { String(article[$0]) }
          guard let body = Range(match.range(at: 2), in: article) else { continue }
          let text = HTMLText.plain(String(article[body]))
          sections.append(label.map { "\($0.capitalized): \(text)" } ?? text)
        }
      }
      let abstract = sections.joined(separator: "\n")
      let credit = [journal, year].compactMap { $0 }.joined(separator: ", ")
      let content = "\(title)\(credit.isEmpty ? "" : " (\(credit))")\n\(abstract)"
      return WebResult(title: title, url: url, snippet: String(abstract.prefix(240)), content: content)
    }
  }
}

// MARK: - Facts (Wikidata)

/// Wikidata's facts about the subject of the first Wikipedia article found: CC0, read with the
/// MediaWiki API. The facts a reader asks most, which an article's text often leaves to its
/// infobox (dropped with the page's tables).
enum WikidataFacts {
  /// Properties shown, in order: the label the model reads for each.
  static let properties: [(id: String, label: String)] = [
    ("P31", "instance of"), ("P17", "country"), ("P131", "located in"), ("P36", "capital"),
    ("P1082", "population"), ("P2046", "area"), ("P2044", "elevation"), ("P571", "founded"),
    ("P569", "born"), ("P19", "place of birth"), ("P570", "died"), ("P20", "place of death"),
    ("P27", "citizenship"), ("P106", "occupation"), ("P39", "position held"), ("P35", "head of state"),
    ("P6", "head of government"), ("P112", "founded by"), ("P169", "chief executive"),
    ("P159", "headquarters"), ("P1128", "employees"), ("P2139", "revenue"), ("P38", "currency"),
    ("P37", "official language"), ("P50", "author"), ("P57", "director"), ("P175", "performer"),
    ("P577", "published"), ("P136", "genre"), ("P348", "latest version"), ("P2048", "height"),
    ("P856", "website"),
  ]

  /// The Wikidata item of a Wikipedia page, from `prop=pageprops`.
  static func itemID(pageprops json: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
      let pages = (object["query"] as? [String: Any])?["pages"] as? [String: Any]
    else { return nil }
    for case let page as [String: Any] in pages.values {
      if let id = (page["pageprops"] as? [String: Any])?["wikibase_item"] as? String { return id }
    }
    return nil
  }

  enum Value: Equatable, Sendable {
    case item(String)
    case text(String)
    /// An amount, with its unit's item when it has one.
    case quantity(String, unit: String?)
  }

  struct Fact: Equatable, Sendable {
    var label: String
    var values: [Value]
    /// When the value held (a population's census), as text.
    var asOf: String?
  }

  struct Entity: Equatable, Sendable {
    var label: String?
    var description: String?
    var facts: [Fact]

    /// Items whose labels the facts need.
    var itemsToLabel: [String] {
      var ids: [String] = []
      for fact in facts {
        for value in fact.values {
          switch value {
          case .item(let id): ids.append(id)
          case .quantity(_, let unit?): ids.append(unit)
          default: break
          }
        }
      }
      return Array(NSOrderedSet(array: ids)) as? [String] ?? ids
    }
  }

  static func entity(json: Data, id: String, language: String) -> Entity? {
    guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
      let entity = (object["entities"] as? [String: Any])?[id] as? [String: Any]
    else { return nil }
    func text(_ key: String) -> String? {
      let values = entity[key] as? [String: Any]
      return ((values?[language] ?? values?["en"]) as? [String: Any])?["value"] as? String
    }
    let claims = entity["claims"] as? [String: Any] ?? [:]
    var facts: [Fact] = []
    for (property, label) in properties {
      guard let statements = claims[property] as? [[String: Any]] else { continue }
      let usable = statements.filter { ($0["rank"] as? String) != "deprecated" }
      let preferred = usable.filter { ($0["rank"] as? String) == "preferred" }
      var chosen = preferred.isEmpty ? usable : preferred
      // A figure that changes over time: the latest one.
      if ["P1082", "P1128", "P2139", "P348"].contains(property) {
        chosen = [chosen.max { pointInTime($0) < pointInTime($1) }].compactMap { $0 }
      }
      let values = chosen.prefix(3).compactMap(value)
      guard !values.isEmpty else { continue }
      let asOf = chosen.count == 1 ? year(pointInTime(chosen[0])) : nil
      facts.append(Fact(label: label, values: values, asOf: asOf))
    }
    return Entity(label: text("labels"), description: text("descriptions"), facts: facts)
  }

  /// Labels of items, from `wbgetentities&props=labels`.
  static func labels(json: Data, language: String) -> [String: String] {
    guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
      let entities = object["entities"] as? [String: Any]
    else { return [:] }
    var labels: [String: String] = [:]
    for (id, entity) in entities {
      let all = (entity as? [String: Any])?["labels"] as? [String: Any]
      if let label = ((all?[language] ?? all?["en"]) as? [String: Any])?["value"] as? String { labels[id] = label }
    }
    return labels
  }

  /// The source's text: one fact a line.
  static func describe(_ entity: Entity, labels: [String: String]) -> String {
    var lines: [String] = []
    if let label = entity.label {
      lines.append(label + (entity.description.map { ": \($0)" } ?? ""))
    }
    for fact in entity.facts {
      let values = fact.values.compactMap { value -> String? in
        switch value {
        case .item(let id): return labels[id]
        case .text(let text): return text
        case .quantity(let amount, let unit): return amount + (unit.flatMap { labels[$0] }.map { " \($0)" } ?? "")
        }
      }
      guard !values.isEmpty else { continue }
      lines.append("\(fact.label): \(values.joined(separator: ", "))\(fact.asOf.map { " (\($0))" } ?? "")")
    }
    return lines.joined(separator: "\n")
  }

  private static func value(_ statement: [String: Any]) -> Value? {
    guard let snak = statement["mainsnak"] as? [String: Any], (snak["snaktype"] as? String) == "value",
      let data = snak["datavalue"] as? [String: Any]
    else { return nil }
    let value = data["value"]
    switch data["type"] as? String {
    case "wikibase-entityid":
      return ((value as? [String: Any])?["id"] as? String).map(Value.item)
    case "string":
      return (value as? String).map(Value.text)
    case "monolingualtext":
      return ((value as? [String: Any])?["text"] as? String).map(Value.text)
    case "time":
      guard let time = value as? [String: Any], let stamp = time["time"] as? String else { return nil }
      return date(stamp, precision: time["precision"] as? Int ?? 11).map(Value.text)
    case "quantity":
      guard let quantity = value as? [String: Any], let raw = quantity["amount"] as? String,
        let amount = Double(raw)
      else { return nil }
      let unit = (quantity["unit"] as? String).flatMap { $0 == "1" ? nil : $0.components(separatedBy: "/").last }
      let formatted = amount.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US")))
      return .quantity(formatted, unit: unit)
    default:
      return nil
    }
  }

  /// "+2021-05-11T00:00:00Z" as "11 May 2021", "May 2021" or "2021" by its precision.
  static func date(_ stamp: String, precision: Int) -> String? {
    guard let match = HTMLText.firstMatch(#"([+-])(\d{1,})-(\d{2})-(\d{2})"#, in: stamp),
      let year = Int(match[1]), let month = Int(match[2]), let day = Int(match[3])
    else { return nil }
    let era = match[0] == "-" ? " BC" : ""
    let months = [
      "January", "February", "March", "April", "May", "June", "July", "August", "September",
      "October", "November", "December",
    ]
    if precision >= 11, (1...12).contains(month), day > 0 { return "\(day) \(months[month - 1]) \(year)\(era)" }
    if precision == 10, (1...12).contains(month) { return "\(months[month - 1]) \(year)\(era)" }
    return "\(year)\(era)"
  }

  private static func pointInTime(_ statement: [String: Any]) -> String {
    let qualifiers = statement["qualifiers"] as? [String: Any]
    let snak = (qualifiers?["P585"] as? [[String: Any]])?.first
    let value = ((snak?["datavalue"] as? [String: Any])?["value"] as? [String: Any])?["time"] as? String
    return value ?? ""
  }

  private static func year(_ stamp: String) -> String? {
    HTMLText.firstMatch(#"[+-](\d{4})-"#, in: stamp)?.first
  }
}
