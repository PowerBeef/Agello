import Foundation

/// The readable text of a web page: its main content without scripts,
/// styles, navigation, headers, footers, sidebars, or forms. Pure
/// (fixture-tested); works on server-rendered pages.
enum ReadableText {
  struct Page: Equatable, Sendable {
    var title: String?
    var text: String
  }

  /// Upper bound on extracted text (a long article is ~40K characters).
  static let maxCharacters = 60_000

  static func extract(html: String, maxCharacters: Int = maxCharacters) -> Page {
    let html = HTMLText.emptyingAttributesWithAngles(html)
    let title = HTMLText.firstMatch(
      #"<meta[^>]+property="og:title"[^>]+content="([^"]*)""#, in: html
    )?.first.map(HTMLText.plain)
      ?? HTMLText.firstMatch(#"<title[^>]*>(.*?)</title>"#, in: html)?.first.map(HTMLText.plain)

    // Code samples keep their lines and indentation: set aside before the page is flattened.
    var code: [String] = []
    var body = setAsideCode(in: html, into: &code)
    body = remove(
      ["script", "style", "noscript", "svg", "nav", "header", "footer", "aside", "form", "button",
        "iframe", "template", "select"],
      from: body)
    // A page's own footnote markers ("[16]", "[a]", "[citation needed]"): the model copied them
    // as if they were the sources' numbers (2026-11-15: a reply cited [42] and [74] with eight
    // sources). Superscripts without brackets, such as exponents, stay.
    let superscripts = body as NSString
    body = HTMLScan.replacing(HTMLScan.elements("sup", in: superscripts), in: superscripts) { sup in
      guard let content = sup.content else { return nil }
      let text = HTMLText.plain(superscripts.substring(with: content)).trimmingCharacters(in: .whitespaces)
      return text.count <= 40 && text.hasPrefix("[") && text.hasSuffix("]") ? "" : nil
    }
    // Figures are illustrations and captions, unless they hold code (many sites wrap it in one).
    let figures = body as NSString
    body = HTMLScan.replacing(HTMLScan.elements("figure", in: figures), in: figures) { figure in
      guard let content = figure.content, figures.range(of: codeMarker, range: content).location == NSNotFound
      else { return nil }
      return " "
    }
    let comments = body as NSString
    body = HTMLScan.replacing(HTMLScan.spans(open: "<!--", close: "-->", in: comments), in: comments) { _ in "" }
    let region = largest("article", in: body) ?? largest("main", in: body)
      ?? HTMLText.firstMatch(#"<body[^>]*>(.*)</body>"#, in: body)?.first ?? body
    let text = restoreCode(toText(region), code)
    return Page(
      title: title?.isEmpty == false ? title : nil, text: String(text.prefix(maxCharacters)))
  }

  private static let codeMarker = "AGELLOCODEBLOCK"

  /// `<pre>` blocks, highlighting spans and all, as fenced code (`language-…` classes become the
  /// fence's language), each replaced by a marker paragraph until the page is text again. Flattened
  /// with the rest, code lost its line breaks and indentation (2026-11-02).
  static func setAsideCode(in html: String, into blocks: inout [String]) -> String {
    let page = html as NSString
    var found: [String] = []
    let output = HTMLScan.replacing(HTMLScan.elements("pre", in: page), in: page) { pre in
      guard let content = pre.content else { return nil }  // unclosed: left to the text pass
      let inner = page.substring(with: content)
      let language =
        HTMLText.firstMatch(
          #"language-([A-Za-z0-9+#-]+)"#, in: page.substring(with: pre.attributes) + String(inner.prefix(300))
        )?.first?.lowercased() ?? ""
      let code = HTMLText.decodeEntities(
        inner
          .replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
          .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
      ).replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .newlines)
      guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
      found.append("```\(language)\n\(code)\n```")
      return "\n\n<p>\(codeMarker)\(blocks.count + found.count - 1)\(codeMarker)</p>\n\n"
    }
    blocks += found
    return output
  }

  static func restoreCode(_ text: String, _ blocks: [String]) -> String {
    var text = text
    for (index, block) in blocks.enumerated() {
      text = text.replacingOccurrences(of: "\(codeMarker)\(index)\(codeMarker)", with: block)
    }
    return text
  }

  /// Remove whole elements (with content, across lines) by tag name; an unclosed or
  /// self-closing tag goes alone.
  private static func remove(_ tags: [String], from html: String) -> String {
    var output = html
    for tag in tags {
      let page = output as NSString
      output = HTMLScan.replacing(HTMLScan.elements(tag, in: page), in: page) { _ in " " }
    }
    return output
  }

  /// The content of the `tag` element with the most text (each measured once).
  private static func largest(_ tag: String, in html: String) -> String? {
    let page = html as NSString
    let best = HTMLScan.elements(tag, in: page).compactMap(\.content)
      .map { (content: page.substring(with: $0), length: HTMLText.plain(page.substring(with: $0)).count) }
      .max { $0.length < $1.length }
    guard let best, best.length >= 200 else { return nil }
    return best.content
  }

  /// Block structure to line breaks, list items to bullets, table cells to
  /// "a | b"; then tags stripped and whitespace tidied.
  static func toText(_ html: String) -> String {
    var text = html
    let replacements: [(String, String)] = [
      ("<br\\s*/?>", "\n"),
      ("</(p|div|section|h[1-6]|li|tr|table|ul|ol|blockquote|pre|dd|dt)>", "\n"),
      ("<li\\b[^>]*>", "\n• "),
      ("<h[1-6]\\b[^>]*>", "\n\n"),
      ("<p\\b[^>]*>", "\n\n"),
      ("</t[dh]>", " | "),
    ]
    for (pattern, replacement) in replacements {
      text = text.replacingOccurrences(
        of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
    }
    text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    text = HTMLText.decodeEntities(text)
    var lines: [String] = []
    for raw in text.components(separatedBy: "\n") {
      var line = raw.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
      while line.hasSuffix(" |") { line.removeLast(2) }
      line = line.trimmingCharacters(in: .whitespaces)
      if line.isEmpty || line == "•" || line == "|" {
        if lines.last?.isEmpty == false { lines.append("") }
        continue
      }
      lines.append(line)
    }
    return dropLinkLists(lines).joined(separator: "\n")
      .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Runs of 6+ very short lines without numbers (menus, tag clouds) are
  /// navigation leftovers; short lines with numbers are usually table data.
  private static func dropLinkLists(_ lines: [String]) -> [String] {
    var output: [String] = []
    var run: [String] = []
    func flush() {
      let numeric = run.filter { $0.contains(where: \.isNumber) }.count
      let isMenu = run.count >= 6 && Double(numeric) < Double(run.count) * 0.3
      if !isMenu { output += run }
      run = []
    }
    for line in lines {
      let words = line.split(separator: " ").count
      if !line.isEmpty, words <= 3, !line.hasSuffix("."), !line.contains("|") {
        run.append(line)
      } else {
        flush()
        output.append(line)
      }
    }
    flush()
    return output
  }
}

/// Elements found in one forward pass. Lazy `<tag…>.*?</tag>` regexes rescanned the rest of the
/// page from every unclosed tag: quadratic on a hostile page (an external review, 2026-11-16).
/// Here every search starts where the last one ended, and a closing tag missing once is missing
/// for the rest of the page.
enum HTMLScan {
  struct Element {
    /// The whole element, or the opening tag alone when it isn't closed.
    var range: NSRange
    /// Between the tag name and `>`.
    var attributes: NSRange
    /// Between the opening and the closing tag; nil when it isn't closed.
    var content: NSRange?
  }

  /// `tag` elements, each from its opening tag to the first closing tag after it (attribute
  /// values holding `>` must be emptied first: ``HTMLText/emptyingAttributesWithAngles(_:)``).
  static func elements(_ tag: String, in html: NSString) -> [Element] {
    var found: [Element] = []
    let open = "<" + tag
    let close = "</" + tag + ">"
    let length = html.length
    var cursor = 0
    var closesLeft = true
    while cursor < length {
      let start = html.range(of: open, options: .caseInsensitive, range: NSRange(location: cursor, length: length - cursor))
      guard start.location != NSNotFound else { break }
      let afterName = start.location + start.length
      // A whole tag name: "<pre" but not "<preview".
      if afterName < length, let next = UnicodeScalar(html.character(at: afterName)),
        next != ">", next != "/", !CharacterSet.whitespacesAndNewlines.contains(next)
      {
        cursor = afterName
        continue
      }
      let end = html.range(of: ">", range: NSRange(location: afterName, length: length - afterName))
      guard end.location != NSNotFound else { break }
      let contentStart = end.location + 1
      let attributes = NSRange(location: afterName, length: end.location - afterName)
      var closing = NSRange(location: NSNotFound, length: 0)
      if closesLeft {
        closing = html.range(
          of: close, options: .caseInsensitive, range: NSRange(location: contentStart, length: length - contentStart))
        closesLeft = closing.location != NSNotFound
      }
      if closing.location != NSNotFound {
        found.append(
          Element(
            range: NSRange(location: start.location, length: closing.location + closing.length - start.location),
            attributes: attributes,
            content: NSRange(location: contentStart, length: closing.location - contentStart)))
        cursor = closing.location + closing.length
      } else {
        found.append(
          Element(
            range: NSRange(location: start.location, length: contentStart - start.location), attributes: attributes,
            content: nil))
        cursor = contentStart
      }
    }
    return found
  }

  /// Spans from `open` to the first `close` after it (comments), in one pass. An unclosed one is
  /// left alone (a stray `<!--` mustn't take the rest of the article with it).
  static func spans(open: String, close: String, in html: NSString) -> [Element] {
    var found: [Element] = []
    let length = html.length
    var cursor = 0
    while cursor < length {
      let start = html.range(of: open, range: NSRange(location: cursor, length: length - cursor))
      guard start.location != NSNotFound else { break }
      let from = start.location + start.length
      let end = html.range(of: close, range: NSRange(location: from, length: length - from))
      guard end.location != NSNotFound else { break }
      let stop = end.location + end.length
      found.append(
        Element(
          range: NSRange(location: start.location, length: stop - start.location),
          attributes: NSRange(location: from, length: 0), content: nil))
      cursor = stop
    }
    return found
  }

  /// `html` with each element replaced by what `replacement` returns (nil keeps it).
  static func replacing(_ elements: [Element], in html: NSString, with replacement: (Element) -> String?) -> String {
    guard !elements.isEmpty else { return html as String }
    var output = ""
    output.reserveCapacity(html.length)
    var last = 0
    for element in elements {
      guard let text = replacement(element) else { continue }
      output += html.substring(with: NSRange(location: last, length: element.range.location - last))
      output += text
      last = element.range.location + element.range.length
    }
    output += html.substring(from: last)
    return output
  }
}
