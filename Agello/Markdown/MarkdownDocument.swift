import Foundation
import Markdown

/// A rendered-ready model of a markdown reply: typed blocks with inline runs
/// as `AttributedString`. Pure (no views), so parsing is unit-tested and the
/// result can be cached while a reply streams.
struct MarkdownDocument: Equatable, Sendable {
  enum Block: Equatable, Sendable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case list(ordered: Bool, start: Int, items: [ListItem])
    case code(language: String?, code: String)
    case quote([Block])
    case table(header: [AttributedString], rows: [[AttributedString]], alignments: [Alignment])
    case math(latex: String)
    case rule
  }

  struct ListItem: Equatable, Sendable {
    /// nil = no checkbox; true/false = task list item.
    var checked: Bool?
    var blocks: [Block]
  }

  enum Alignment: Equatable, Sendable { case leading, center, trailing }

  var blocks: [Block]

  init(blocks: [Block]) { self.blocks = blocks }

  /// Parse `source` (possibly a partial, still-streaming reply).
  init(parsing source: String) {
    var blocks: [Block] = []
    for segment in MathSplitter.split(source) {
      switch segment {
      case .markdown(let text):
        let document = Document(parsing: InlineMath.convert(text))
        blocks += document.children.compactMap(Self.block)
      case .displayMath(let latex):
        blocks.append(.math(latex: latex))
      }
    }
    self.blocks = blocks
  }

  /// Readable text without markdown syntax (for reading aloud). Code
  /// blocks are skipped: spoken source code isn't useful.
  var plainText: String {
    Self.plain(blocks).joined(separator: "\n")
  }

  private static func plain(_ blocks: [Block]) -> [String] {
    blocks.flatMap { block -> [String] in
      switch block {
      case .heading(_, let text), .paragraph(let text):
        return [String(text.characters)]
      case .list(_, _, let items):
        return items.flatMap { plain($0.blocks) }
      case .quote(let inner):
        return plain(inner)
      case .table(let header, let rows, _):
        return ([header] + rows).map { $0.map { String($0.characters) }.joined(separator: ", ") }
      case .math(let latex):
        return [LaTeXText.unicode(latex)]
      case .code, .rule:
        return []
      }
    }
  }

  // MARK: Blocks

  private static func block(_ markup: Markup) -> Block? {
    switch markup {
    case let heading as Heading:
      return .heading(level: heading.level, text: inlines(heading.children))
    case let paragraph as Paragraph:
      return .paragraph(inlines(paragraph.children))
    case let list as UnorderedList:
      return .list(ordered: false, start: 1, items: list.listItems.map(item))
    case let list as OrderedList:
      return .list(ordered: true, start: Int(list.startIndex), items: list.listItems.map(item))
    case let code as CodeBlock:
      var text = code.code
      if text.hasSuffix("\n") { text.removeLast() }
      let language = code.language.flatMap { $0.isEmpty ? nil : $0.lowercased() }
      return .code(language: language, code: text)
    case let quote as BlockQuote:
      return .quote(quote.children.compactMap(block))
    case let table as Table:
      let header = table.head.cells.map { inlines($0.children) }
      let rows = table.body.rows.map { row in Array(row.cells.map { inlines($0.children) }) }
      let alignments = table.columnAlignments.map { alignment -> Alignment in
        switch alignment {
        case .center: return .center
        case .right: return .trailing
        default: return .leading
        }
      }
      return .table(header: Array(header), rows: Array(rows), alignments: alignments)
    case is ThematicBreak:
      return .rule
    case let html as HTMLBlock:
      return .paragraph(AttributedString(html.rawHTML.trimmingCharacters(in: .whitespacesAndNewlines)))
    default:
      let text = markup.format().trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : .paragraph(AttributedString(text))
    }
  }

  private static func item(_ item: Markdown.ListItem) -> ListItem {
    let checked: Bool? = item.checkbox.map { $0 == .checked }
    return ListItem(checked: checked, blocks: item.children.compactMap(block))
  }

  // MARK: Inlines

  private struct Style {
    var intent: InlinePresentationIntent = []
    var link: URL?
  }

  private static func inlines(_ children: some Sequence<Markup>) -> AttributedString {
    var result = AttributedString()
    for child in children { result += inline(child, Style()) }
    return result
  }

  private static func inline(_ markup: Markup, _ style: Style) -> AttributedString {
    func run(_ string: String, _ style: Style) -> AttributedString {
      var text = AttributedString(string)
      if !style.intent.isEmpty { text.inlinePresentationIntent = style.intent }
      if let link = style.link { text.link = link }
      return text
    }
    func children(_ markup: Markup, _ style: Style) -> AttributedString {
      markup.children.reduce(into: AttributedString()) { $0 += inline($1, style) }
    }
    var next = style
    switch markup {
    case let text as Markdown.Text:
      return run(text.string, style)
    case is Emphasis:
      next.intent.insert(.emphasized)
      return children(markup, next)
    case is Strong:
      next.intent.insert(.stronglyEmphasized)
      return children(markup, next)
    case is Strikethrough:
      next.intent.insert(.strikethrough)
      return children(markup, next)
    case let code as InlineCode:
      next.intent.insert(.code)
      return run(code.code, next)
    case let link as Markdown.Link:
      next.link = link.destination.flatMap(URL.init(string:))
      let label = children(link, next)
      return label.characters.isEmpty ? run(link.destination ?? "", next) : label
    case let image as Markdown.Image:
      return run(image.plainText.isEmpty ? (image.source ?? "") : image.plainText, style)
    case is SoftBreak:
      return run(" ", style)
    case is LineBreak:
      return run("\n", style)
    case let html as InlineHTML:
      return run(html.rawHTML, style)
    default:
      return children(markup, style)
    }
  }
}

// MARK: - Display math

/// Splits display math (`$$…$$`, `\[…\]`) out of markdown, outside code.
enum MathSplitter {
  enum Segment: Equatable { case markdown(String), displayMath(String) }

  static func split(_ source: String) -> [Segment] {
    var segments: [Segment] = []
    var markdown = ""
    var math: (closer: String, body: String)?
    var inFence = false

    func flushMarkdown() {
      if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        segments.append(.markdown(markdown))
      }
      markdown = ""
    }

    for line in source.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if var open = math {
        if let range = trimmed.range(of: open.closer) {
          open.body += (open.body.isEmpty ? "" : "\n") + trimmed[..<range.lowerBound]
          segments.append(.displayMath(open.body.trimmingCharacters(in: .whitespacesAndNewlines)))
          math = nil
        } else {
          open.body += (open.body.isEmpty ? "" : "\n") + line
          math = open
        }
        continue
      }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
      if !inFence, let (opener, closer) = displayDelimiters(trimmed) {
        let rest = String(trimmed.dropFirst(opener.count))
        flushMarkdown()
        if let range = rest.range(of: closer) {
          // Single-line display math.
          segments.append(
            .displayMath(String(rest[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)))
        } else {
          math = (closer, rest)
        }
        continue
      }
      markdown += markdown.isEmpty ? line : "\n" + line
    }
    if let open = math {
      // Still streaming: show the unfinished formula as text until it closes.
      let opener = open.closer == "$$" ? "$$" : "\\["
      markdown += (markdown.isEmpty ? "" : "\n") + opener + open.body
    }
    flushMarkdown()
    return segments
  }

  private static func displayDelimiters(_ line: String) -> (String, String)? {
    if line.hasPrefix("$$") { return ("$$", "$$") }
    if line.hasPrefix("\\[") { return ("\\[", "\\]") }
    return nil
  }
}

// MARK: - Inline math

/// Converts inline LaTeX (`$…$`, `\(…\)`) to readable Unicode text, outside
/// code spans and fences. Currency like "$5 and $10" is left alone.
enum InlineMath {
  static func convert(_ markdown: String) -> String {
    var output = ""
    var inFence = false
    for (index, line) in markdown.components(separatedBy: "\n").enumerated() {
      if index > 0 { output += "\n" }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        inFence.toggle()
        output += line
        continue
      }
      output += inFence ? line : convertLine(line)
    }
    return output
  }

  private static func convertLine(_ line: String) -> String {
    // Leave inline code spans untouched.
    let parts = line.components(separatedBy: "`")
    return parts.enumerated().map { index, part in
      index.isMultiple(of: 2) ? convertText(part) : part
    }.joined(separator: "`")
  }

  private static func convertText(_ text: String) -> String {
    var result = replace(text, open: "\\(", close: "\\)")
    result = replaceDollars(result)
    return result
  }

  private static func replace(_ text: String, open: String, close: String) -> String {
    var output = ""
    var rest = Substring(text)
    while let start = rest.range(of: open), let end = rest[start.upperBound...].range(of: close) {
      output += rest[..<start.lowerBound]
      output += LaTeXText.unicode(String(rest[start.upperBound..<end.lowerBound]))
      rest = rest[end.upperBound...]
    }
    return output + rest
  }

  /// `$x$` counts as math when the content hugs the delimiters (no space
  /// after the opener or before the closer) and the closer isn't followed by
  /// a digit — the usual rule that keeps "$5 and $10" as currency.
  private static func replaceDollars(_ text: String) -> String {
    let characters = Array(text)
    var output = ""
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "$", index + 1 < characters.count, characters[index + 1] != " ",
        characters[index + 1] != "$",
        let close = closingDollar(characters, from: index + 1)
      {
        output += LaTeXText.unicode(String(characters[(index + 1)..<close]))
        index = close + 1
        continue
      }
      output.append(character)
      index += 1
    }
    return output
  }

  private static func closingDollar(_ characters: [Character], from start: Int) -> Int? {
    var index = start
    while index < characters.count {
      if characters[index] == "$", characters[index - 1] != " ", characters[index - 1] != "\\" {
        let next = index + 1 < characters.count ? characters[index + 1] : " "
        return next.isNumber ? nil : index
      }
      index += 1
    }
    return nil
  }
}

/// A small LaTeX → Unicode transliteration for inline formulas.
enum LaTeXText {
  static func unicode(_ latex: String) -> String {
    var text = latex
    for (command, symbol) in commands {
      text = text.replacingOccurrences(of: command, with: symbol)
    }
    text = replaceGroups(text, command: "\\frac", arity: 2) { "\($0[0])/\($0[1])" }
    text = replaceGroups(text, command: "\\sqrt", arity: 1) { "√(\($0[0]))" }
    for wrapper in ["\\text", "\\mathrm", "\\mathbf", "\\mathit", "\\operatorname", "\\boxed"] {
      text = replaceGroups(text, command: wrapper, arity: 1) { $0[0] }
    }
    text = scripts(text, marker: "^", map: superscripts)
    text = scripts(text, marker: "_", map: subscripts)
    text = text.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
    text = text.replacingOccurrences(of: "\\,", with: " ").replacingOccurrences(of: "\\ ", with: " ")
    text = text.replacingOccurrences(of: "\\", with: "")
    return text.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
  }

  private static let commands: [(String, String)] = [
    ("\\times", "×"), ("\\cdot", "·"), ("\\div", "÷"), ("\\pm", "±"), ("\\mp", "∓"),
    ("\\leq", "≤"), ("\\geq", "≥"), ("\\le", "≤"), ("\\ge", "≥"), ("\\neq", "≠"),
    ("\\approx", "≈"), ("\\equiv", "≡"), ("\\infty", "∞"), ("\\rightarrow", "→"),
    ("\\leftarrow", "←"), ("\\Rightarrow", "⇒"), ("\\to", "→"), ("\\in", "∈"),
    ("\\sum", "∑"), ("\\prod", "∏"), ("\\int", "∫"), ("\\partial", "∂"), ("\\degree", "°"),
    ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\delta", "δ"), ("\\Delta", "Δ"),
    ("\\epsilon", "ε"), ("\\theta", "θ"), ("\\lambda", "λ"), ("\\mu", "μ"), ("\\pi", "π"),
    ("\\sigma", "σ"), ("\\Sigma", "Σ"), ("\\phi", "φ"), ("\\omega", "ω"), ("\\Omega", "Ω"),
    ("\\left", ""), ("\\right", ""), ("\\quad", " "), ("\\%", "%"), ("\\$", "$"),
  ]

  private static let superscripts: [Character: Character] = [
    "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸",
    "9": "⁹", "+": "⁺", "-": "⁻", "n": "ⁿ", "i": "ⁱ", "(": "⁽", ")": "⁾",
  ]
  private static let subscripts: [Character: Character] = [
    "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈",
    "9": "₉", "+": "₊", "-": "₋", "(": "₍", ")": "₎",
  ]

  /// Replace `\cmd{a}{b}` groups (balanced braces) using `transform`.
  private static func replaceGroups(
    _ text: String, command: String, arity: Int, transform: ([String]) -> String
  ) -> String {
    var output = ""
    var rest = Substring(text)
    while let range = rest.range(of: command + "{") {
      output += rest[..<range.lowerBound]
      var cursor = rest.index(before: range.upperBound)
      var groups: [String] = []
      for _ in 0..<arity {
        guard cursor < rest.endIndex, rest[cursor] == "{",
          let (group, end) = balancedGroup(rest, from: cursor)
        else { break }
        groups.append(group)
        cursor = end
      }
      if groups.count == arity {
        output += transform(groups)
        rest = rest[cursor...]
      } else {
        output += rest[range]
        rest = rest[range.upperBound...]
      }
    }
    return output + rest
  }

  private static func balancedGroup(_ text: Substring, from open: Substring.Index)
    -> (String, Substring.Index)?
  {
    var depth = 0
    var index = open
    while index < text.endIndex {
      if text[index] == "{" { depth += 1 }
      if text[index] == "}" {
        depth -= 1
        if depth == 0 {
          return (String(text[text.index(after: open)..<index]), text.index(after: index))
        }
      }
      index = text.index(after: index)
    }
    return nil
  }

  /// `x^2`, `x^{10}` → x², x¹⁰ when every character has a Unicode form.
  private static func scripts(_ text: String, marker: Character, map: [Character: Character]) -> String {
    var output = ""
    var characters = Array(text)[...]
    while let first = characters.first {
      characters = characters.dropFirst()
      guard first == marker, let next = characters.first else {
        output.append(first)
        continue
      }
      var body: [Character]
      if next == "{", let end = characters.firstIndex(of: "}") {
        body = Array(characters[(characters.startIndex + 1)..<end])
        characters = characters[(end + 1)...]
      } else {
        body = [next]
        characters = characters.dropFirst()
      }
      let mapped = body.compactMap { map[$0] }
      if mapped.count == body.count {
        output += String(mapped)
      } else {
        output += String(marker) + "(" + String(body) + ")"
      }
    }
    return output
  }
}
