import Foundation

/// Builds what the model reads when a chat has files: whole files when they
/// fit, a section-by-section summary for "summarize this" on long files, or
/// the most relevant excerpts with page labels. Pure (unit-tested); the
/// app supplies documents, retrieval results, and summaries.
enum FileContext {
  /// One file's contribution to the prompt.
  enum Material: Equatable {
    /// The whole file (paged text keeps its "[Page N]" markers).
    case full(name: String, pageCount: Int, text: String)
    /// A section-by-section summary of a long file.
    case summary(name: String, pageCount: Int, text: String)
    /// Retrieved passages, each with its citation label.
    case excerpts([(label: String, text: String)])

    static func == (lhs: Material, rhs: Material) -> Bool {
      switch (lhs, rhs) {
      case let (.full(a, b, c), .full(d, e, f)), let (.summary(a, b, c), .summary(d, e, f)):
        return a == d && b == e && c == f
      case let (.excerpts(a), .excerpts(b)):
        return a.map(\.label) == b.map(\.label) && a.map(\.text) == b.map(\.text)
      default:
        return false
      }
    }
  }

  /// Share of the context window the files may use.
  static let windowShare = 0.5

  /// Tokens available for file material in a `window`-token context.
  static func budget(window: Int, question: String) -> Int {
    max(512, Int(Double(window) * windowShare) - ContextBudget.estimateTokens(question))
  }

  /// The prompt sent to the model: instructions, the file material, then
  /// the user's question.
  static func prompt(question: String, materials: [Material]) -> String {
    var blocks: [String] = [
      "The user attached files. Use them to answer. When you use a fact from a file, cite it "
        + "like (report.pdf, p. 4), or (notes.md) for files without pages. If the files don't "
        + "contain the answer, say so."
    ]
    for material in materials {
      switch material {
      case .full(let name, let pages, let text):
        blocks.append("<file name=\"\(name)\"\(pages > 0 ? " pages=\"\(pages)\"" : "")>\n\(text)\n</file>")
      case .summary(let name, let pages, let text):
        blocks.append(
          "<summary of=\"\(name)\" pages=\"\(pages)\">\n\(text)\n</summary>")
      case .excerpts(let excerpts):
        let body = excerpts.map { "[\($0.label)]\n\($0.text)" }.joined(separator: "\n\n")
        blocks.append("<excerpts>\n\(body)\n</excerpts>")
      }
    }
    blocks.append("Question: \(question.isEmpty ? "Describe the attached files." : question)")
    return blocks.joined(separator: "\n\n")
  }

  // MARK: - Summaries of long files

  /// Whether the user asks about a whole document rather than a detail.
  static func wantsSummary(_ question: String) -> Bool {
    let text = question.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    let cues = [
      "summar", "overview", "tl;dr", "tldr", "key point", "main point", "main idea",
      "key takeaway", "takeaways", "gist", "outline", "what is this about", "what's this about",
      "what is it about", "what is the document about", "what is this document",
      "resume", "resumer", "synthese", "points cles", "idees principales", "de quoi parle",
      "en bref",
    ]
    return question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || cues.contains { text.contains($0) }
  }

  /// Tokens of document text per summarized section.
  static let sectionTokens = 2_400
  /// Output tokens per section summary.
  static let sectionSummaryTokens = 220

  struct Section: Equatable {
    var pageStart: Int?
    var pageEnd: Int?
    var text: String

    var label: String {
      guard let start = pageStart else { return "Part" }
      if let end = pageEnd, end != start { return "Pages \(start)–\(end)" }
      return "Page \(start)"
    }
  }

  /// Consecutive passages grouped into ~``sectionTokens`` sections.
  static func sections(_ chunks: [ChunkDraft]) -> [Section] {
    var sections: [Section] = []
    var current: [ChunkDraft] = []
    var tokens = 0
    func flush() {
      guard !current.isEmpty else { return }
      sections.append(
        Section(
          pageStart: current.compactMap(\.pageStart).min(),
          pageEnd: current.compactMap(\.pageEnd).max(),
          text: current.map(\.text).joined(separator: "\n\n")))
      current = []
      tokens = 0
    }
    for chunk in chunks {
      let cost = ContextBudget.estimateTokens(chunk.text)
      if tokens + cost > sectionTokens { flush() }
      current.append(chunk)
      tokens += cost
    }
    flush()
    return sections
  }

  static func sectionPrompt(_ section: Section, of name: String) -> String {
    """
    Summarize this part of the document "\(name)" (\(section.label.lowercased())) in 4 to 8 \
    short bullet points. Keep key facts, numbers, names, decisions and conclusions. Write in \
    the document's language. Output only the bullet points.

    \(section.text)
    """
  }

  /// A document summary from its section summaries, labelled by pages.
  static func joinSummaries(_ summaries: [String], sections: [Section]) -> String {
    zip(sections, summaries)
      .filter { !$0.1.isEmpty }
      .map { "\($0.0.label):\n\($0.1)" }
      .joined(separator: "\n\n")
  }

  // MARK: - Fitting the budget

  /// Passages in rank order until `budget` tokens are used (at least one).
  static func fit(_ passages: [Passage], budget: Int) -> [Passage] {
    var kept: [Passage] = []
    var used = 0
    for passage in passages {
      let cost = ContextBudget.estimateTokens(passage.text) + 12
      if !kept.isEmpty, used + cost > budget { break }
      kept.append(passage)
      used += cost
    }
    return kept
  }

  /// `text` cut to about `tokens` (at a line break where possible).
  static func truncate(_ text: String, tokens: Int) -> String {
    let maxBytes = Int(Double(tokens) * ContextBudget.bytesPerToken)
    guard text.utf8.count > maxBytes else { return text }
    let prefix = ContextBudget.prefix(text, maxBytes: maxBytes)
    if let newline = prefix.lastIndex(of: "\n"), prefix.distance(from: prefix.startIndex, to: newline) > prefix.count / 2 {
      return String(prefix[..<newline]) + "\n…"
    }
    return prefix + "…"
  }
}
