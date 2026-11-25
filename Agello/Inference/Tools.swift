import Foundation
import LiteRTLMTools

/// Boundary sanitization for tool outputs so attacker-controlled strings (CSV headers, file names,
/// web titles, Maps POIs, echoed expressions) can never inject Gemma 4 control tokens or blow up
/// KV cache outside ``ToolBudget``.
private enum ToolOutput {
  static func text(_ value: String, maxChars: Int = 240) -> String {
    let clean = PromptText.neutralized(value)
    guard clean.count > maxChars else { return clean }
    return String(clean.prefix(maxChars)) + "…"
  }

  static func boundedList(_ values: [String], maxItems: Int, maxCharsPerItem: Int = 80) -> [String] {
    values.prefix(maxItems).map { text($0, maxChars: maxCharsPerItem) }
  }

  /// Strips an outer `<untrusted_data ...>...</untrusted_data>` envelope when present so
  /// ``UntrustedContext/wrapFitted(_:source:limits:)`` can re-wrap with an intact closing tag.
  static func unwrapOuterUntrusted(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("<untrusted_data"), trimmed.hasSuffix("</untrusted_data>"),
      let openEnd = trimmed.firstIndex(of: ">")
    else { return value }
    let bodyStart = trimmed.index(after: openEnd)
    let bodyEnd = trimmed.index(trimmed.endIndex, offsetBy: -"</untrusted_data>".count)
    guard bodyStart <= bodyEnd else { return "" }
    return String(trimmed[bodyStart..<bodyEnd]).trimmingCharacters(in: .newlines)
  }
}

// MARK: - Date / time tool

/// Returns the device's current local date and time. Fully offline.
struct CurrentDateTimeTool: Tool {
  static let name = "get_current_date_time"
  static let isReadOnly = true
  static let description =
    "Get the current local date and time on the user's device. Use for any question about 'now', today, or the current time."

  @ToolParam(description: "Optional IANA timezone, e.g. 'Europe/Paris'. Defaults to the device timezone.")
  var timeZone: String? = nil

  func run() async throws -> Any {
    guard ToolBudget.claim() != nil else { return ToolBudget.limitReachedResult }
    let zone: TimeZone
    if let requested = timeZone, let resolved = TimeZone(identifier: requested) {
      zone = resolved
    } else {
      zone = .current
    }
    let now = Date()
    let iso = ISO8601DateFormatter()
    iso.timeZone = zone
    ToolActivity.record(Self.name, summary: "Checked the date and time")
    return [
      "iso8601": iso.string(from: now),
      // In English, whatever the device's language (PromptText.date).
      "human": PromptText.dateTime(now, timeZone: zone),
      "timezone": zone.identifier,
    ]
  }
}

// MARK: - Web search tool (automatic mode)

/// Lets the model search the web when a question needs fresh or factual
/// information. Offered only when the user turned on automatic web search.
struct WebSearchTool: Tool {
  static let name = "web_search"
  static let isReadOnly = true
  static let description =
    "Look things up in Wikipedia and other reference sources: facts, recent events, travel, word meanings, quotations, weather, places, exchange rates, scientific and medical papers. Returns numbered sources to cite like [1]."

  @ToolParam(description: "Short query naming the subject, e.g. \"2026 Tour de France\", a place for weather, or \"100 USD to EUR\".")
  var query: String

  @ToolParam(
    description: "Topic category.",
    allowedValues: ["general", "travel", "word", "quote", "weather", "place", "currency", "research", "health", "news"])
  var topic: String = "general"

  /// Runs the search for the app (set by `AppState`) within a budget of tokens; returns the
  /// sources block for the model, or an error message.
  nonisolated(unsafe) static var handler: (@Sendable (String, SearchTopic, Int) async -> String)?

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let handler = Self.handler else {
      return ["error": "Web search is unavailable."]
    }
    ToolActivity.record(Self.name, summary: "Searched the web for “\(trimmed)”")
    let subject = SearchTopic(rawValue: topic.trimmingCharacters(in: .whitespaces).lowercased()) ?? .general
    let result = await handler(trimmed, subject, limits.maxResultTokens)
    // Spotlight external web pages inside <untrusted_data> and fit the body *before* closing tag.
    let inner = ToolOutput.unwrapOuterUntrusted(result)
    return ["sources": UntrustedContext.wrapFitted(inner, source: Self.name, limits: limits)]
  }
}

// MARK: - Calculator tool

enum CalculatorError: Error, LocalizedError, Equatable {
  case emptyExpression
  case tooLong
  case invalidCharacter(Character)
  case malformed
  case divisionByZero
  case notFinite

  var errorDescription: String? {
    switch self {
    case .emptyExpression: return "Empty expression."
    case .tooLong: return "Expression is too long."
    case .invalidCharacter(let c): return "Invalid character: '\(c)'."
    case .malformed: return "Malformed expression."
    case .divisionByZero: return "Division by zero."
    case .notFinite: return "The result is too large or undefined."
    }
  }
}

/// Safe arithmetic evaluator (recursive descent). Accepts numbers, `+ - * /`,
/// `^` or `**` for powers, `%` for percent (`18%` is 0.18; `10 % 3`, with an
/// operand after it, is the remainder) and parentheses. Currency symbols and
/// thousands separators are ignored. Anything else, identifiers and
/// functions included, throws.
enum ArithmeticParser {
  static func evaluate(_ input: String) throws -> Double {
    let trimmed = normalize(input).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw CalculatorError.emptyExpression }
    guard trimmed.count <= 200 else { throw CalculatorError.tooLong }
    var parser = Parser(text: Array(trimmed))
    let value = try parser.parseExpression()
    try parser.expectEnd()
    guard value.isFinite else { throw CalculatorError.notFinite }
    return value
  }

  /// What models write around numbers: currency symbols, thousands separators (including
  /// French thin/non-breaking spaces) and typographic operators ("$1,250 × 2" is "1250 * 2").
  static func normalize(_ input: String) -> String {
    var text = input.replacingOccurrences(of: "[$€£¥₹₩]", with: "", options: .regularExpression)
    text = text.replacingOccurrences(
      of: #"(?<=\d)[,\u00A0\u202F](?=\d{3}(?!\d))"#, with: "", options: .regularExpression)
    return text.replacingOccurrences(of: "×", with: "*")
      .replacingOccurrences(of: "÷", with: "/")
      .replacingOccurrences(of: "\u{2212}", with: "-")
  }

  private struct Parser {
    let text: [Character]
    var index: Int = 0

    mutating func parseExpression() throws -> Double {
      var value = try parseTerm()
      while true {
        skipSpaces()
        guard let c = peek else { return value }
        if c == "+" {
          advance()
          value += try parseTerm()
        } else if c == "-" {
          advance()
          value -= try parseTerm()
        } else {
          return value
        }
      }
    }

    mutating func parseTerm() throws -> Double {
      var value = try parseFactor()
      while true {
        skipSpaces()
        guard let c = peek else { return value }
        if c == "*" {
          advance()
          value *= try parseFactor()
        } else if c == "/" {
          advance()
          let divisor = try parseFactor()
          guard divisor != 0 else { throw CalculatorError.divisionByZero }
          value /= divisor
        } else if c == "%" {
          advance()
          let divisor = try parseFactor()
          guard divisor != 0 else { throw CalculatorError.divisionByZero }
          value = value.truncatingRemainder(dividingBy: divisor)
        } else {
          return value
        }
      }
    }

    /// Unary signs apply after powers: -2^2 is -4.
    mutating func parseFactor() throws -> Double {
      skipSpaces()
      guard let c = peek else { throw CalculatorError.malformed }
      if c == "-" {
        advance()
        return -(try parseFactor())
      }
      if c == "+" {
        advance()
        return try parseFactor()
      }
      return try parsePower()
    }

    /// `^` or `**`, grouping to the right: 2^3^2 is 2^9.
    mutating func parsePower() throws -> Double {
      let base = try parsePercent()
      skipSpaces()
      if peek == "^" {
        advance()
        return pow(base, try parseFactor())
      }
      if peek == "*", peekAfter == "*" {
        advance()
        advance()
        return pow(base, try parseFactor())
      }
      return base
    }

    /// `18%` is 0.18. With an operand after it (`10 % 3`) the `%` is left
    /// for the remainder in `parseTerm`.
    mutating func parsePercent() throws -> Double {
      let value = try parsePrimary()
      skipSpaces()
      guard peek == "%" else { return value }
      var next = index + 1
      while next < text.count, text[next].isWhitespace { next += 1 }
      if next < text.count, text[next].isNumber || text[next] == "." || text[next] == "(" {
        return value
      }
      advance()
      return value / 100
    }

    mutating func parsePrimary() throws -> Double {
      skipSpaces()
      guard let c = peek else { throw CalculatorError.malformed }
      if c == "(" {
        advance()
        let value = try parseExpression()
        skipSpaces()
        guard peek == ")" else { throw CalculatorError.malformed }
        advance()
        return value
      }
      return try parseNumber()
    }

    mutating func parseNumber() throws -> Double {
      skipSpaces()
      let start = index
      var sawDigit = false
      var sawDot = false
      while let c = peek {
        if c.isNumber {
          sawDigit = true
          advance()
        } else if c == "." && !sawDot {
          sawDot = true
          advance()
        } else {
          break
        }
      }
      guard sawDigit else {
        if let c = peek, !"+-*/%^()".contains(c), !c.isWhitespace {
          throw CalculatorError.invalidCharacter(c)
        }
        throw CalculatorError.malformed
      }
      let token = String(text[start..<index])
      guard let value = Double(token) else { throw CalculatorError.malformed }
      return value
    }

    mutating func expectEnd() throws {
      skipSpaces()
      if let c = peek {
        if c.isNumber || c == "." || "+-*/%^()".contains(c) {
          throw CalculatorError.malformed
        }
        throw CalculatorError.invalidCharacter(c)
      }
    }

    var peek: Character? { index < text.count ? text[index] : nil }
    var peekAfter: Character? { index + 1 < text.count ? text[index + 1] : nil }
    mutating func advance() { index += 1 }
    mutating func skipSpaces() {
      while let c = peek, c.isWhitespace { index += 1 }
    }
  }
}

/// Evaluates arithmetic locally. Fully offline.
struct CalculatorTool: Tool {
  static let name = "calculate"
  static let isReadOnly = true
  static let description =
    "Evaluate an arithmetic expression: numbers, + - * /, ^ for powers (x^0.5 is a square root), % for percent (18% is 0.18) and parentheses. Use it for any exact computation instead of mental math."

  @ToolParam(description: "The expression to evaluate, e.g. '(12.5 * 3) + 4' or '1000 * 1.05^10'.")
  var expression: String

  /// Expressions it can't evaluate are answered with an error the model can
  /// act on, never thrown: LiteRT-LM would end the reply on a thrown error.
  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    let shown = ToolBudget.fit(PromptText.neutralized(expression), limits)
    do {
      let value = try ArithmeticParser.evaluate(expression)
      let rounded = Double(String(format: "%.12g", value)) ?? value
      guard rounded.isFinite else { throw CalculatorError.notFinite }
      ToolActivity.record(Self.name, summary: "Calculated \(shown)")
      // 12 significant digits: no 0.30000000000000004 for the model to echo.
      return ["expression": shown, "result": rounded == 0 ? 0.0 : rounded]
    } catch {
      ToolActivity.record(Self.name, summary: "Couldn't calculate \(shown)")
      let reason = (error as? LocalizedError)?.errorDescription ?? "Couldn't evaluate it."
      return [
        "expression": shown,
        "error": ToolOutput.text(
          "\(reason) Use only numbers, + - * /, ^ for powers, % for percent and parentheses."),
      ]
    }
  }
}

// MARK: - Unit conversion tool

/// Converts physical and digital units locally. Fully offline.
struct ConvertUnitsTool: Tool {
  static let name = "convert_units"
  static let isReadOnly = true
  static let description =
    "Convert a numeric measurement between units offline (length, mass, temperature, volume, area, speed, time, data size/rate, energy, power, pressure, angle)."

  @ToolParam(description: "The numeric value to convert, e.g. 72 or 5.5.")
  var value: Double

  @ToolParam(description: "Source unit symbol or name, e.g. 'km', 'lb', 'F', 'GB', 'mph'.")
  var fromUnit: String

  @ToolParam(description: "Target unit symbol or name, e.g. 'mi', 'kg', 'C', 'GiB', 'km/h'.")
  var toUnit: String

  func run() async throws -> Any {
    guard ToolBudget.claim() != nil else { return ToolBudget.limitReachedResult }
    do {
      let res = try UnitConverter.convert(value: value, from: fromUnit, to: toUnit)
      guard res.outputValue.isFinite else { return ["error": "Conversion result is out of range."] }
      ToolActivity.record(
        Self.name, summary: "Converted \(value) \(res.fromSymbol) to \(res.toSymbol)")
      return [
        "result": res.outputValue,
        "formatted": ToolOutput.text(res.formatted),
        "from": ToolOutput.text(res.fromSymbol, maxChars: 40),
        "to": ToolOutput.text(res.toSymbol, maxChars: 40),
        "category": ToolOutput.text(res.category, maxChars: 40),
      ]
    } catch {
      ToolActivity.record(Self.name, summary: "Couldn't convert \(fromUnit) to \(toUnit)")
      let reason = (error as? LocalizedError)?.errorDescription ?? "Conversion failed."
      return ["error": ToolOutput.text(reason)]
    }
  }
}

// MARK: - Workspace research tools

/// Semantically searches files attached to the current chat or project.
struct SearchFilesTool: Tool {
  static let name = "search_files"
  static let isReadOnly = true
  static let description =
    "Search attached chat and project files by meaning and keywords. Returns cited excerpts with file names and page numbers."

  @ToolParam(description: "What to look for in the attached files.")
  var query: String

  @ToolParam(description: "Optional file name to restrict the search to one attached file.")
  var fileName: String? = nil

  @ToolParam(description: "Maximum number of excerpts to return (1 to 10). Default is 5.")
  var limit: Int = 5

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let handler = WorkspaceTools.searchFilesHandler else {
      return ["error": "File search is unavailable."]
    }
    let outcome = await handler(trimmed, fileName, limit)
    let safeAvailable = ToolOutput.boundedList(outcome.availableFiles, maxItems: 32)
    if let error = outcome.error {
      ToolActivity.record(Self.name, summary: "Searched files for “\(trimmed)”")
      return ["error": ToolOutput.text(error), "available_files": safeAvailable]
    }
    ToolActivity.record(Self.name, summary: "Searched files for “\(trimmed)”")
    let formatted = outcome.matches.map { match in
      "[\(match.citation)]\n\(match.excerpt)"
    }.joined(separator: "\n\n")
    let content = formatted.isEmpty
      ? "No matching passages found."
      : UntrustedContext.wrapFitted(formatted, source: Self.name, limits: limits)
    return [
      "available_files": safeAvailable,
      "match_count": outcome.matches.count,
      "excerpts": content,
    ]
  }
}

/// Reads exact page ranges (PDFs/scans) or line ranges (text files) from an attached document.
struct ReadDocumentPagesTool: Tool {
  static let name = "read_document_pages"
  static let isReadOnly = true
  static let description =
    "Read specific 1-based page numbers from an attached PDF/scan, or 1-based line ranges from an attached text/CSV/JSON file."

  @ToolParam(description: "Name of the attached file to read, e.g. 'report.pdf' or 'notes.md'.")
  var fileName: String

  @ToolParam(description: "1-based starting page number (or starting line number for non-paged text files).")
  var startPage: Int

  @ToolParam(description: "Optional 1-based ending page (or ending line) inclusive.")
  var endPage: Int? = nil

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    guard let handler = WorkspaceTools.readDocumentPagesHandler else {
      return ["error": "Document reading is unavailable."]
    }
    let outcome = await handler(fileName, startPage, endPage)
    if let error = outcome.error {
      ToolActivity.record(Self.name, summary: "Tried reading \(fileName)")
      return ["error": ToolOutput.text(error)]
    }
    let unit = outcome.isPaged ? "pp." : "lines"
    let rangeLabel = outcome.start == outcome.end ? "\(outcome.start)" : "\(outcome.start)–\(outcome.end)"
    ToolActivity.record(Self.name, summary: "Read \(outcome.fileName) (\(unit) \(rangeLabel))")
    return [
      "file_name": ToolOutput.text(outcome.fileName, maxChars: 120),
      "unit": outcome.isPaged ? "page" : "line",
      "start": outcome.start,
      "end": outcome.end,
      "total": outcome.totalUnits,
      "content": UntrustedContext.wrapFitted(outcome.content, source: outcome.fileName, limits: limits),
    ]
  }
}

/// Searches the user's past saved conversations on this device by meaning and keywords.
struct SearchPastChatsTool: Tool {
  static let name = "search_past_chats"
  static let isReadOnly = true
  static let description =
    "Search the user's earlier saved chats on this device to recall prior discussions, decisions, or details."

  @ToolParam(description: "Topic, keyword, or question to find in earlier chats.")
  var query: String

  @ToolParam(description: "Maximum number of past chats to return (1 to 8). Default is 5.")
  var limit: Int = 5

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let handler = WorkspaceTools.searchPastChatsHandler else {
      return ["error": "Past chat search is unavailable."]
    }
    let outcome = await handler(trimmed, limit)
    if let error = outcome.error {
      ToolActivity.record(Self.name, summary: "Searched past chats for “\(trimmed)”")
      return ["error": error]
    }
    ToolActivity.record(Self.name, summary: "Searched past chats for “\(trimmed)”")
    if outcome.matches.isEmpty {
      return ["match_count": 0, "results": "No matching earlier chats found."]
    }
    let formatted = outcome.matches.map { match in
      "### \(match.title) (\(match.updatedAt))\n\(match.excerpt)"
    }.joined(separator: "\n\n")
    return [
      "match_count": outcome.matches.count,
      "results": UntrustedContext.wrapFitted(formatted, source: Self.name, limits: limits),
    ]
  }
}

/// Runs deterministic schema inspection, filtering, sorting, and grouped aggregations on CSV/TSV/JSON data.
struct QueryTableOrJsonTool: Tool {
  static let name = "query_table_or_json"
  static let isReadOnly = true
  static let description =
    "Run exact schema, filter, sort, or grouped aggregations on attached or inline CSV/TSV/JSON data."

  @ToolParam(
    description: "Query operation.",
    allowedValues: ["schema", "filter", "count", "sum", "avg", "min", "max", "aggregate"])
  var operation: String

  @ToolParam(description: "Attached file name (CSV/TSV/JSON).")
  var fileName: String? = nil

  @ToolParam(description: "Inline CSV/TSV/JSON text if no fileName.")
  var data: String? = nil

  @ToolParam(description: "Target column for aggregation.")
  var column: String? = nil

  @ToolParam(description: "Optional filter, e.g. \"region = West AND price >= 50\".")
  var whereClause: String? = nil

  @ToolParam(description: "Optional grouping column.")
  var groupBy: String? = nil

  @ToolParam(description: "Optional sort column.")
  var sortBy: String? = nil

  @ToolParam(description: "Sort descending (default false).")
  var descending: Bool = false

  @ToolParam(description: "Max rows/groups (1-50, default 20).")
  var limit: Int = 20

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    let raw: String
    let label: String
    if let fileName, !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard let lookup = WorkspaceTools.lookupDocumentTextHandler,
        let doc = await lookup(fileName)
      else {
        return ["error": ToolOutput.text("Attached file '\(fileName)' was not found.")]
      }
      raw = doc.text
      label = doc.fileName
    } else if let data, !data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      raw = data
      label = "inline data"
    } else {
      return ["error": "Provide either fileName (an attached file) or data (inline CSV/TSV/JSON)."]
    }

    do {
      let request = StructuredDataQuery.Request(
        operation: operation, column: column, whereClause: whereClause,
        groupBy: groupBy, sortBy: sortBy, descending: descending, limit: limit)
      let output = try StructuredDataQuery.execute(raw: raw, request: request)
      ToolActivity.record(Self.name, summary: "Queried \(label) (\(operation))")
      // Bound and neutralize column names so hostile CSV/JSON headers cannot inject control
      // tokens or overflow KV outside ToolBudget.
      let safeColumns = ToolOutput.boundedList(output.columns, maxItems: 64)
      let columnsBudget = ToolBudget.Limits(
        maxResultTokens: min(limits.maxResultTokens / 4, 256), maxCalls: limits.maxCalls)
      _ = ToolBudget.fit(safeColumns.joined(separator: ", "), columnsBudget)
      return [
        "source": ToolOutput.text(label, maxChars: 120),
        "format": output.format,
        "total_rows": output.totalRows,
        "matched_rows": output.matchedRows,
        "columns": safeColumns,
        "result": UntrustedContext.wrapFitted(output.summary, source: label, limits: limits),
      ]
    } catch {
      ToolActivity.record(Self.name, summary: "Couldn't query \(label)")
      let reason = (error as? LocalizedError)?.errorDescription ?? "Query failed."
      return ["error": ToolOutput.text(reason)]
    }
  }
}

// MARK: - Opt-in native iOS personal context tools (EventKit, Contacts, MapKit)

/// Lists Calendar events in an optional date range or matching a query. Read-only.
struct SearchCalendarEventsTool: Tool {
  static let name = "search_calendar_events"
  static let isReadOnly = true
  static let description =
    "Search on-device Calendar events. Omit startDate/endDate when searching by title to search upcoming events (-7d to +30d)."

  @ToolParam(description: "Optional range start (YYYY-MM-DD or ISO-8601).")
  var startDate: String? = nil

  @ToolParam(description: "Optional range end (YYYY-MM-DD or ISO-8601).")
  var endDate: String? = nil

  @ToolParam(description: "Optional title, location, or notes filter.")
  var query: String? = nil

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    guard
      let range = PersonalToolsLogic.resolveCalendarRange(
        startDate: startDate, endDate: endDate, query: query)
    else {
      return ["error": "Invalid date range. Use YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS."]
    }
    let cleanQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasQuery = !(cleanQuery?.isEmpty ?? true)
    let backend = PersonalTools.activeBackend
    switch await backend.searchCalendarEvents(start: range.start, end: range.end, query: cleanQuery) {
    case .error(let message):
      ToolActivity.record(Self.name, summary: "Calendar unavailable")
      return ["error": message]
    case .success(var events):
      // B6 auto-widen: if the model guessed a single-day window with a specific query and found
      // nothing, widen once to -7d...+30d so events like "Team Lunch" tomorrow are still found.
      let spanSeconds = range.end.timeIntervalSince(range.start)
      if events.isEmpty, hasQuery, spanSeconds <= 36 * 3_600 {
        let wide = PersonalToolsLogic.widenedCalendarRange()
        if case .success(let widened) = await backend.searchCalendarEvents(
          start: wide.start, end: wide.end, query: cleanQuery)
        {
          events = widened
        }
      }
      ToolActivity.record(Self.name, summary: "Checked calendar (\(events.count) events)")
      for event in events.prefix(3) {
        ToolCardRecorder.record(
          .calendarEvent(
            CalendarEventCard(
              status: .found,
              eventIdentifier: event.eventIdentifier,
              title: event.title,
              startDate: event.startDate,
              endDate: event.endDate,
              isAllDay: event.isAllDay,
              location: event.location,
              calendarName: event.calendarName)))
      }
      let body = PersonalToolsLogic.formatEvents(events)
      return [
        "count": events.count,
        "events": UntrustedContext.wrapFitted(body, source: Self.name, limits: limits),
      ]
    }
  }
}

/// Finds free daytime slots in the user's Calendar. Read-only.
struct FindFreeSlotsTool: Tool {
  static let name = "find_free_slots"
  static let isReadOnly = true
  static let description = "Find free daytime slots in the user's Calendar between startDate and endDate."

  @ToolParam(description: "Range start (YYYY-MM-DD or ISO-8601).")
  var startDate: String

  @ToolParam(description: "Range end (YYYY-MM-DD or ISO-8601).")
  var endDate: String

  @ToolParam(description: "Minimum slot length in minutes (default 30).")
  var minDurationMinutes: Int = 30

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    guard let start = PersonalToolsLogic.parseDate(startDate, endOfDay: false),
      let end = PersonalToolsLogic.parseDate(endDate, endOfDay: true),
      end > start
    else {
      return ["error": "Invalid date range. Use YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS."]
    }
    switch await PersonalTools.activeBackend.searchCalendarEvents(start: start, end: end, query: nil) {
    case .error(let message):
      ToolActivity.record(Self.name, summary: "Calendar unavailable")
      return ["error": message]
    case .success(let events):
      let slots = PersonalToolsLogic.computeFreeSlots(
        busyEvents: events, windowStart: start, windowEnd: end,
        minDurationMinutes: minDurationMinutes)
      ToolActivity.record(Self.name, summary: "Found \(slots.count) free calendar slots")
      return [
        "count": slots.count,
        "slots": ToolBudget.fit(PersonalToolsLogic.formatFreeSlots(slots), limits),
      ]
    }
  }
}

/// Creates a new Calendar event ONLY after deterministic pre-execution user confirmation.
struct CreateCalendarEventTool: Tool {
  static let name = "create_calendar_event"
  static let isReadOnly = false
  static let description = "Create a Calendar event (always confirms with the user before saving)."

  @ToolParam(description: "Event title.")
  var title: String

  @ToolParam(description: "Start date/time (YYYY-MM-DDTHH:MM:SS).")
  var startDate: String

  @ToolParam(description: "End date/time (YYYY-MM-DDTHH:MM:SS).")
  var endDate: String

  @ToolParam(description: "Optional location.")
  var location: String? = nil

  @ToolParam(description: "Optional notes.")
  var notes: String? = nil

  func run() async throws -> Any {
    guard ToolBudget.claim() != nil else { return ToolBudget.limitReachedResult }
    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty else { return ["error": "Event title cannot be empty."] }
    guard let start = PersonalToolsLogic.parseDate(startDate, endOfDay: false),
      let end = PersonalToolsLogic.parseDate(endDate, endOfDay: false),
      end > start
    else {
      return ["error": "Invalid startDate/endDate. Use YYYY-MM-DDTHH:MM:SS with endDate after startDate."]
    }

    var params: [ToolConfirmationRequest.Parameter] = [
      .init(name: "title", value: cleanTitle),
      .init(name: "start", value: PersonalToolsLogic.formatISO(start)),
      .init(name: "end", value: PersonalToolsLogic.formatISO(end)),
    ]
    if let location, !location.isEmpty { params.append(.init(name: "location", value: location)) }
    if let notes, !notes.isEmpty { params.append(.init(name: "notes", value: String(notes.prefix(200)))) }

    let request = ToolConfirmationRequest(
      toolName: Self.name,
      title: String(localized: "Create calendar event"),
      summary: "Add “\(cleanTitle)” to your Calendar.",
      parameters: params)
    let decision = await ToolConfirmationGate.confirm(request)
    guard case .approved = decision else {
      let reason: String
      if case .denied(let detail) = decision { reason = detail } else { reason = "Denied by user." }
      ToolActivity.record(Self.name, summary: "Cancelled creating “\(cleanTitle)”")
      return ["executed": false, "status": "cancelled", "message": reason]
    }

    switch await PersonalTools.activeBackend.createCalendarEvent(
      title: cleanTitle, start: start, end: end, location: location, notes: notes)
    {
    case .error(let message):
      ToolActivity.record(Self.name, summary: "Couldn't create event “\(cleanTitle)”")
      return ["executed": false, "error": message]
    case .success(let saved):
      ToolActivity.record(Self.name, summary: "Created calendar event “\(saved.title)”")
      ToolCardRecorder.record(
        .calendarEvent(
          CalendarEventCard(
            status: .created,
            eventIdentifier: saved.eventIdentifier,
            title: saved.title,
            startDate: saved.startDate,
            endDate: saved.endDate,
            isAllDay: saved.isAllDay,
            location: saved.location,
            calendarName: saved.calendarName)))
      return [
        "executed": true,
        "status": "created",
        "title": ToolOutput.text(saved.title),
        "start": PersonalToolsLogic.formatISO(saved.startDate),
        "end": PersonalToolsLogic.formatISO(saved.endDate),
        "calendar": ToolOutput.text(saved.calendarName ?? "Default", maxChars: 80),
      ]
    }
  }
}

/// Lists the user's Reminders. Read-only.
struct ListRemindersTool: Tool {
  static let name = "list_reminders"
  static let isReadOnly = true
  static let description = "List on-device Reminders (incomplete by default)."

  @ToolParam(description: "Include completed reminders (default false).")
  var includeCompleted: Bool = false

  @ToolParam(description: "Optional title or notes filter.")
  var query: String? = nil

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    switch await PersonalTools.activeBackend.listReminders(includeCompleted: includeCompleted, query: query) {
    case .error(let message):
      ToolActivity.record(Self.name, summary: "Reminders unavailable")
      return ["error": message]
    case .success(let items):
      ToolActivity.record(Self.name, summary: "Checked reminders (\(items.count))")
      for item in items.prefix(3) {
        ToolCardRecorder.record(
          .reminder(
            ReminderCard(
              status: .found,
              reminderIdentifier: item.reminderIdentifier,
              title: item.title,
              dueDate: item.dueDate,
              listName: item.listName,
              isCompleted: item.isCompleted)))
      }
      let body = PersonalToolsLogic.formatReminders(items)
      return [
        "count": items.count,
        "reminders": UntrustedContext.wrapFitted(body, source: Self.name, limits: limits),
      ]
    }
  }
}

/// Creates a new Reminder ONLY after deterministic pre-execution user confirmation.
struct CreateReminderTool: Tool {
  static let name = "create_reminder"
  static let isReadOnly = false
  static let description = "Create a Reminder (always confirms with the user before saving)."

  @ToolParam(description: "Reminder title.")
  var title: String

  @ToolParam(description: "Optional due date/time (YYYY-MM-DD or ISO-8601).")
  var dueDate: String? = nil

  @ToolParam(description: "Optional notes.")
  var notes: String? = nil

  func run() async throws -> Any {
    guard ToolBudget.claim() != nil else { return ToolBudget.limitReachedResult }
    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty else { return ["error": "Reminder title cannot be empty."] }
    var parsedDue: Date?
    if let dueDate, !dueDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard let parsed = PersonalToolsLogic.parseDate(dueDate, endOfDay: false) else {
        return ["error": "Invalid dueDate. Use YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS."]
      }
      parsedDue = parsed
    }

    var params: [ToolConfirmationRequest.Parameter] = [
      .init(name: "title", value: cleanTitle)
    ]
    if let parsedDue {
      params.append(.init(name: "due", value: PersonalToolsLogic.formatISO(parsedDue)))
    }
    if let notes, !notes.isEmpty {
      params.append(.init(name: "notes", value: String(notes.prefix(200))))
    }

    let request = ToolConfirmationRequest(
      toolName: Self.name,
      title: String(localized: "Create reminder"),
      summary: "Add “\(cleanTitle)” to Reminders.",
      parameters: params)
    let decision = await ToolConfirmationGate.confirm(request)
    guard case .approved = decision else {
      let reason: String
      if case .denied(let detail) = decision { reason = detail } else { reason = "Denied by user." }
      ToolActivity.record(Self.name, summary: "Cancelled reminder “\(cleanTitle)”")
      return ["executed": false, "status": "cancelled", "message": reason]
    }

    switch await PersonalTools.activeBackend.createReminder(
      title: cleanTitle, dueDate: parsedDue, notes: notes)
    {
    case .error(let message):
      ToolActivity.record(Self.name, summary: "Couldn't create reminder “\(cleanTitle)”")
      return ["executed": false, "error": message]
    case .success(let saved):
      ToolActivity.record(Self.name, summary: "Created reminder “\(saved.title)”")
      ToolCardRecorder.record(
        .reminder(
          ReminderCard(
            status: .created,
            reminderIdentifier: saved.reminderIdentifier,
            title: saved.title,
            dueDate: saved.dueDate,
            listName: saved.listName,
            isCompleted: saved.isCompleted)))
      return [
        "executed": true,
        "status": "created",
        "title": ToolOutput.text(saved.title),
        "due": saved.dueDate.map { PersonalToolsLogic.formatISO($0) } ?? "",
        "list": ToolOutput.text(saved.listName ?? "Default", maxChars: 80),
      ]
    }
  }
}

/// Searches the user's Contacts locally on-device. Read-only.
struct SearchContactsTool: Tool {
  static let name = "search_contacts"
  static let isReadOnly = true
  static let description = "Look up phone numbers, emails, addresses, or orgs in Contacts."

  @ToolParam(description: "Name, company, email, or phone fragment.")
  var query: String

  @ToolParam(description: "Max results (1-10, default 5).")
  var limit: Int = 5

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return ["error": "Query cannot be empty."] }
    switch await PersonalTools.activeBackend.searchContacts(query: trimmed, limit: limit) {
    case .error(let message):
      ToolActivity.record(Self.name, summary: "Contacts unavailable")
      return ["error": message]
    case .success(let contacts):
      ToolActivity.record(Self.name, summary: "Searched contacts for “\(trimmed)”")
      TurnContactRoster.register(contacts)
      for contact in contacts.prefix(3) {
        ToolCardRecorder.record(
          .contact(
            ContactCard(
              contactIdentifier: contact.contactIdentifier,
              fullName: contact.fullName,
              organization: contact.organization,
              phones: contact.phones,
              emails: contact.emails,
              postalAddress: contact.postalAddress)))
      }
      let body = PersonalToolsLogic.formatContacts(contacts)
      return [
        "count": contacts.count,
        "contacts": UntrustedContext.wrapFitted(body, source: Self.name, limits: limits),
      ]
    }
  }
}

/// Prepares an SMS or email draft card for the native iOS composer after explicit confirmation.
/// Never sends silently — the OS composer always requires a physical user tap on Send.
struct PrepareMessageTool: Tool {
  static let name = "prepare_message"
  static let isReadOnly = false
  static let description =
    "Draft an SMS or email for the user to review and send via the native iOS composer (never sends silently)."

  @ToolParam(description: "Message channel.", allowedValues: ["sms", "email"])
  var channel: String

  @ToolParam(description: "Recipient phone numbers or email addresses.")
  var recipients: [String]

  @ToolParam(description: "Optional email subject line.")
  var subject: String? = nil

  @ToolParam(description: "Draft message body.")
  var body: String

  func run() async throws -> Any {
    guard ToolBudget.claim() != nil else { return ToolBudget.limitReachedResult }
    let normalizedChannel = channel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let parsedChannel = MessageDraftCard.Channel(rawValue: normalizedChannel) else {
      return ["error": "Invalid channel. Use 'sms' or 'email'."]
    }
    let cleanRecipients = recipients
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    guard !cleanRecipients.isEmpty else {
      return ["error": "Provide at least one recipient phone number or email address."]
    }
    let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanBody.isEmpty else { return ["error": "Message body cannot be empty."] }
    let cleanSubject = subject?.trimmingCharacters(in: .whitespacesAndNewlines)
    let unverified = TurnContactRoster.unverifiedRecipients(from: cleanRecipients)

    var params: [ToolConfirmationRequest.Parameter] = [
      .init(name: "channel", value: parsedChannel == .sms ? "SMS" : "Email"),
      .init(name: "to", value: cleanRecipients.joined(separator: ", ")),
    ]
    if !unverified.isEmpty {
      params.append(
        .init(
          name: "warning",
          value: "Unverified recipient (not in Contacts): \(unverified.joined(separator: ", "))"))
    }
    if let cleanSubject, !cleanSubject.isEmpty {
      params.append(.init(name: "subject", value: cleanSubject))
    }
    params.append(.init(name: "body", value: String(cleanBody.prefix(240))))

    let label = parsedChannel == .sms ? String(localized: "Draft SMS") : String(localized: "Draft email")
    let request = ToolConfirmationRequest(
      toolName: Self.name,
      title: label,
      summary: "Prepare a draft to \(cleanRecipients.joined(separator: ", ")). You will tap Send yourself.",
      parameters: params)
    let decision = await ToolConfirmationGate.confirm(request)
    guard case .approved = decision else {
      let reason: String
      if case .denied(let detail) = decision { reason = detail } else { reason = "Denied by user." }
      ToolActivity.record(Self.name, summary: "Cancelled message draft")
      return ["executed": false, "status": "cancelled", "message": reason]
    }

    let draft = MessageDraftCard(
      channel: parsedChannel,
      recipients: cleanRecipients,
      subject: cleanSubject?.isEmpty == true ? nil : cleanSubject,
      body: cleanBody,
      unverifiedRecipients: unverified)
    ToolCardRecorder.record(.messageDraft(draft))
    ToolActivity.record(Self.name, summary: "Prepared \(parsedChannel.rawValue.uppercased()) draft")
    return [
      "executed": true,
      "status": "draft_ready",
      "channel": parsedChannel.rawValue,
      "recipients": ToolOutput.boundedList(cleanRecipients, maxItems: 10),
      "unverified_recipients": ToolOutput.boundedList(unverified, maxItems: 10),
    ]
  }
}

/// Searches Apple Maps POIs and addresses locally via MapKit. Read-only.
struct SearchPlacesTool: Tool {
  static let name = "search_places"
  static let isReadOnly = true
  static let description = "Search Apple Maps for nearby places, businesses, addresses, and phone numbers."

  @ToolParam(description: "Place type, business name, or address, e.g. 'gas station' or 'coffee shop'.")
  var query: String

  @ToolParam(description: "Optional city, landmark, or 'here' (defaults to current location when omitted).")
  var near: String? = nil

  @ToolParam(description: "Max places (1-10, default 5).")
  var limit: Int = 5

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return ["error": "Query cannot be empty."] }
    switch await PersonalTools.activeBackend.searchPlaces(query: trimmed, near: near, limit: limit) {
    case .error(let message):
      ToolActivity.record(Self.name, summary: "Maps search failed")
      return ["error": message]
    case .success(let places):
      let cleanNear = near?.trimmingCharacters(in: .whitespacesAndNewlines)
      let areaLabel = (cleanNear?.isEmpty == false && !LanguageSupport.meansCurrentLocation(cleanNear ?? ""))
        ? cleanNear : nil
      let label = areaLabel.map { "\(trimmed) near \($0)" } ?? trimmed
      ToolActivity.record(Self.name, summary: "Searched Apple Maps for “\(label)”")
      if !places.isEmpty {
        let cardItems = places.prefix(5).map { p in
          PlacesCard.PlaceItem(
            name: p.name,
            category: p.category,
            address: p.address,
            phone: p.phone,
            websiteURL: p.websiteURL,
            latitude: p.latitude,
            longitude: p.longitude,
            distanceMeters: p.distanceMeters,
            mapItemIdentifier: p.mapItemIdentifier)
        }
        ToolCardRecorder.record(
          .places(PlacesCard(query: trimmed, areaLabel: areaLabel, places: Array(cardItems))))
      }
      let body = PersonalToolsLogic.formatPlaces(places)
      return [
        "count": places.count,
        "places": UntrustedContext.wrapFitted(body, source: Self.name, limits: limits),
      ]
    }
  }
}

/// Estimates distance, travel time, and turn-by-turn directions between two places via Apple Maps.
struct EstimateTravelTimeTool: Tool {
  static let name = "estimate_travel_time"
  static let isReadOnly = true
  static let description =
    "Get travel distance, ETA, and turn-by-turn Apple Maps directions from an origin (or current location) to a destination."

  @ToolParam(description: "Destination place or address.")
  var destination: String

  @ToolParam(description: "Optional starting place; omit or 'here' for current location.")
  var origin: String? = nil

  @ToolParam(
    description: "Transport mode.",
    allowedValues: ["driving", "walking", "cycling", "transit"])
  var transport: String = "driving"

  @ToolParam(description: "Include turn-by-turn steps (default true).")
  var includeSteps: Bool = true

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    switch await PersonalTools.activeBackend.estimateTravelTime(
      origin: origin, destination: destination, transport: transport)
    {
    case .error(let message):
      ToolActivity.record(Self.name, summary: "Couldn't get directions")
      return ["error": ToolOutput.text(message)]
    case .success(let est):
      ToolActivity.record(Self.name, summary: "Got \(est.transport) route to \(est.destination)")
      if let destLat = est.destinationLatitude, let destLon = est.destinationLongitude {
        ToolCardRecorder.record(
          .route(
            RouteCard(
              originName: est.origin,
              originLatitude: est.originLatitude,
              originLongitude: est.originLongitude,
              originIsCurrentLocation: est.originIsCurrentLocation,
              destinationName: est.destination,
              destinationAddress: est.destinationAddress,
              destinationLatitude: destLat,
              destinationLongitude: destLon,
              destinationMapItemIdentifier: est.destinationMapItemIdentifier,
              transport: est.transport,
              distanceMeters: est.distanceMeters,
              expectedTravelSeconds: est.expectedTravelSeconds,
              routeName: est.routeName,
              steps: includeSteps ? Array(est.steps.prefix(15)) : [])))
      }
      let summary = PersonalToolsLogic.formatTravel(est, includeSteps: includeSteps)
      return [
        "origin": ToolOutput.text(est.origin, maxChars: 120),
        "destination": ToolOutput.text(est.destination, maxChars: 120),
        "transport": ToolOutput.text(est.transport, maxChars: 40),
        "distance_km": Double(String(format: "%.2f", est.distanceMeters / 1_000.0)) ?? 0,
        "minutes": max(1, Int((est.expectedTravelSeconds / 60.0).rounded())),
        "step_count": includeSteps ? est.steps.count : 0,
        "summary": UntrustedContext.wrapFitted(summary, source: Self.name, limits: limits),
      ]
    }
  }
}
