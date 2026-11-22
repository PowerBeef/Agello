import Foundation

/// Pure helpers and sendable bridge closures connecting workspace tools (`search_files`,
/// `read_document_pages`, `search_past_chats`, `query_table_or_json`) to ``AppState``'s
/// active thread, project documents, and chat history without exposing `LiteRTLM` outside `Tools.swift`.
enum WorkspaceTools {
  struct FileMatch: Equatable, Sendable {
    var fileName: String
    var citation: String
    var excerpt: String
  }

  struct FileSearchResult: Equatable, Sendable {
    var matches: [FileMatch]
    var availableFiles: [String]
    var error: String?
  }

  struct DocumentPageResult: Equatable, Sendable {
    var fileName: String
    var isPaged: Bool
    var totalUnits: Int
    var start: Int
    var end: Int
    var content: String
    var error: String?
  }

  struct PastChatMatch: Equatable, Sendable {
    var title: String
    var updatedAt: String
    var excerpt: String
  }

  struct PastChatSearchResult: Equatable, Sendable {
    var matches: [PastChatMatch]
    var error: String?
  }

  struct DocumentLookupResult: Equatable, Sendable {
    var fileName: String
    var text: String
  }

  /// Bridges installed by `AppState` on startup so tools execute cleanly in Swift 6 concurrency.
  nonisolated(unsafe) static var searchFilesHandler:
    (@Sendable (_ query: String, _ fileName: String?, _ limit: Int) async -> FileSearchResult)?
  nonisolated(unsafe) static var readDocumentPagesHandler:
    (@Sendable (_ fileName: String, _ startPage: Int, _ endPage: Int?) async -> DocumentPageResult)?
  nonisolated(unsafe) static var searchPastChatsHandler:
    (@Sendable (_ query: String, _ limit: Int) async -> PastChatSearchResult)?
  nonisolated(unsafe) static var lookupDocumentTextHandler:
    (@Sendable (_ fileName: String) async -> DocumentLookupResult?)?

  /// Extract 1-based page range `[start...end]` from a paged document's stored `[Page N]` text,
  /// or 1-based line range `[start...end]` from an unpaged text document.
  static func sliceDocument(
    name: String, text: String, pageCount: Int, startPage: Int, endPage: Int?
  ) -> DocumentPageResult {
    let clampedStart = max(1, startPage)
    if pageCount > 0 {
      let pages = splitPages(text)
      let total = max(pageCount, pages.count)
      guard !pages.isEmpty else {
        return DocumentPageResult(
          fileName: name, isPaged: true, totalUnits: total, start: clampedStart, end: clampedStart,
          content: "", error: "No page text found in \(name).")
      }
      guard clampedStart <= pages.count else {
        return DocumentPageResult(
          fileName: name, isPaged: true, totalUnits: pages.count, start: clampedStart,
          end: clampedStart, content: "",
          error: "\(name) has \(pages.count) pages; requested start page \(clampedStart) is out of range.")
      }
      let requestedEnd = endPage.map { max(clampedStart, $0) } ?? clampedStart
      let clampedEnd = min(pages.count, requestedEnd)
      let body = (clampedStart...clampedEnd)
        .map { "[Page \($0)]\n\(pages[$0 - 1])" }
        .joined(separator: "\n\n")
      return DocumentPageResult(
        fileName: name, isPaged: true, totalUnits: pages.count, start: clampedStart,
        end: clampedEnd, content: body, error: nil)
    }

    // Plain text / CSV / JSON / Markdown: treat startPage..endPage as 1-based line ranges
    // (defaulting to a 60-line window when endPage is omitted).
    let lines = text.components(separatedBy: .newlines)
    guard !lines.isEmpty else {
      return DocumentPageResult(
        fileName: name, isPaged: false, totalUnits: 0, start: clampedStart, end: clampedStart,
        content: "", error: "\(name) is empty.")
    }
    guard clampedStart <= lines.count else {
      return DocumentPageResult(
        fileName: name, isPaged: false, totalUnits: lines.count, start: clampedStart,
        end: clampedStart, content: "",
        error: "\(name) has \(lines.count) lines; requested start line \(clampedStart) is out of range.")
    }
    let requestedEnd = endPage.map { max(clampedStart, $0) } ?? min(lines.count, clampedStart + 59)
    let clampedEnd = min(lines.count, requestedEnd)
    let slice = lines[(clampedStart - 1)..<clampedEnd].enumerated()
      .map { "\(clampedStart + $0.offset): \($0.element)" }
      .joined(separator: "\n")
    return DocumentPageResult(
      fileName: name, isPaged: false, totalUnits: lines.count, start: clampedStart,
      end: clampedEnd, content: slice, error: nil)
  }

  /// Splits `ExtractedDocument.fullText` (`[Page 1]\n...\n\n[Page 2]\n...`) back into page strings.
  static func splitPages(_ fullText: String) -> [String] {
    let pattern = #"(?m)^\[Page \d+\]\n?"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [fullText] }
    let ns = fullText as NSString
    let matches = regex.matches(in: fullText, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return [fullText] }
    var pages: [String] = []
    for (index, match) in matches.enumerated() {
      let bodyStart = match.range.location + match.range.length
      let bodyEnd = index + 1 < matches.count ? matches[index + 1].range.location : ns.length
      let page = ns.substring(with: NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart)))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      pages.append(page)
    }
    return pages
  }

  /// Matches a user/model-supplied `fileName` against candidate names (exact, case-insensitive,
  /// basename, or unique substring).
  static func matchDocumentName<T>(_ requested: String, among items: [T], name: (T) -> String) -> T? {
    let query = requested.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return nil }
    if let exact = items.first(where: { name($0) == query }) { return exact }
    if let ci = items.first(where: { name($0).caseInsensitiveCompare(query) == .orderedSame }) { return ci }
    let stemMatches = items.filter {
      let stem = (name($0) as NSString).deletingPathExtension
      return stem.caseInsensitiveCompare(query) == .orderedSame
    }
    if stemMatches.count == 1 { return stemMatches[0] }
    let partial = items.filter { name($0).localizedCaseInsensitiveContains(query) }
    if partial.count == 1 { return partial[0] }
    return nil
  }
}
