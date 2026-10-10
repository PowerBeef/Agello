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

  static func extract(html: String) -> Page {
    let title = HTMLText.firstMatch(
      #"<meta[^>]+property="og:title"[^>]+content="([^"]*)""#, in: html
    )?.first.map(HTMLText.plain)
      ?? HTMLText.firstMatch(#"<title[^>]*>(.*?)</title>"#, in: html)?.first.map(HTMLText.plain)

    var body = remove(
      ["script", "style", "noscript", "svg", "nav", "header", "footer", "aside", "form", "button",
        "iframe", "template", "select", "figure"],
      from: html)
    body = body.replacingOccurrences(of: "<!--.*?-->", with: "", options: .regularExpression)
    let region = largest("article", in: body) ?? largest("main", in: body)
      ?? HTMLText.firstMatch(#"<body[^>]*>(.*)</body>"#, in: body)?.first ?? body
    let text = toText(region)
    return Page(
      title: title?.isEmpty == false ? title : nil, text: String(text.prefix(maxCharacters)))
  }

  /// Remove whole elements (with content) by tag name.
  private static func remove(_ tags: [String], from html: String) -> String {
    var output = html
    for tag in tags {
      output = output.replacingOccurrences(
        of: "<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ",
        options: [.regularExpression, .caseInsensitive])
      // Self-closing or unclosed leftovers.
      output = output.replacingOccurrences(
        of: "<\(tag)\\b[^>]*/?>", with: " ", options: [.regularExpression, .caseInsensitive])
    }
    return output
  }

  /// The content of the `tag` element with the most text.
  private static func largest(_ tag: String, in html: String) -> String? {
    guard
      let regex = try? NSRegularExpression(
        pattern: "<\(tag)\\b[^>]*>(.*?)</\(tag)>",
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    else { return nil }
    let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
    let contents = matches.compactMap { Range($0.range(at: 1), in: html).map { String(html[$0]) } }
    let best = contents.max { HTMLText.plain($0).count < HTMLText.plain($1).count }
    guard let best, HTMLText.plain(best).count >= 200 else { return nil }
    return best
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
