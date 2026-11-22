import Foundation
import LiteRTLM

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

  @ToolParam(description: "A short, self-contained query naming the subject, like \"2026 Tour de France\". For weather, the place; for currency, like \"100 USD to EUR\".")
  var query: String

  @ToolParam(description: "What it's about: general, travel, word, quote, weather, place, currency, research, health or news.")
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
    // Web pages can't close the tool response or open a turn.
    return ["sources": ToolBudget.fit(PromptText.neutralized(result), limits)]
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

  /// What models write around numbers: currency symbols, thousands
  /// separators and typographic operators ("$1,250 × 2" is "1250 * 2").
  static func normalize(_ input: String) -> String {
    var text = input.replacingOccurrences(of: "[$€£¥]", with: "", options: .regularExpression)
    text = text.replacingOccurrences(
      of: #"(?<=\d),(?=\d{3}(?!\d))"#, with: "", options: .regularExpression)
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
    let shown = ToolBudget.fit(expression, limits)
    do {
      let value = try ArithmeticParser.evaluate(expression)
      ToolActivity.record(Self.name, summary: "Calculated \(shown)")
      // 12 significant digits: no 0.30000000000000004 for the model to echo.
      return ["expression": shown, "result": Double(String(format: "%.12g", value)) ?? value]
    } catch {
      ToolActivity.record(Self.name, summary: "Couldn't calculate \(shown)")
      let reason = (error as? LocalizedError)?.errorDescription ?? "Couldn't evaluate it."
      return [
        "expression": shown,
        "error": "\(reason) Use only numbers, + - * /, ^ for powers, % for percent and parentheses.",
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
      ToolActivity.record(
        Self.name, summary: "Converted \(value) \(res.fromSymbol) to \(res.toSymbol)")
      return [
        "result": res.outputValue,
        "formatted": res.formatted,
        "from": res.fromSymbol,
        "to": res.toSymbol,
        "category": res.category,
      ]
    } catch {
      ToolActivity.record(Self.name, summary: "Couldn't convert \(fromUnit) to \(toUnit)")
      let reason = (error as? LocalizedError)?.errorDescription ?? "Conversion failed."
      return ["error": reason]
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
    if let error = outcome.error {
      ToolActivity.record(Self.name, summary: "Searched files for “\(trimmed)”")
      return ["error": error, "available_files": outcome.availableFiles]
    }
    ToolActivity.record(Self.name, summary: "Searched files for “\(trimmed)”")
    let formatted = outcome.matches.map { match in
      "[\(match.citation)]\n\(match.excerpt)"
    }.joined(separator: "\n\n")
    let content = formatted.isEmpty
      ? "No matching passages found."
      : ToolBudget.fit(PromptText.neutralized(formatted), limits)
    return [
      "available_files": outcome.availableFiles,
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
      return ["error": error]
    }
    let unit = outcome.isPaged ? "pp." : "lines"
    let rangeLabel = outcome.start == outcome.end ? "\(outcome.start)" : "\(outcome.start)–\(outcome.end)"
    ToolActivity.record(Self.name, summary: "Read \(outcome.fileName) (\(unit) \(rangeLabel))")
    return [
      "file_name": outcome.fileName,
      "unit": outcome.isPaged ? "page" : "line",
      "start": outcome.start,
      "end": outcome.end,
      "total": outcome.totalUnits,
      "content": ToolBudget.fit(PromptText.neutralized(outcome.content), limits),
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
      "results": ToolBudget.fit(PromptText.neutralized(formatted), limits),
    ]
  }
}

/// Runs deterministic schema inspection, filtering, sorting, and grouped aggregations on CSV/TSV/JSON data.
struct QueryTableOrJsonTool: Tool {
  static let name = "query_table_or_json"
  static let isReadOnly = true
  static let description =
    "Inspect, filter, sort, or compute exact aggregations (count, sum, avg, min, max, aggregate) over a CSV, TSV, or JSON attached file or inline snippet."

  @ToolParam(description: "Operation: 'schema', 'filter', 'count', 'sum', 'avg', 'min', 'max', or 'aggregate'.")
  var operation: String

  @ToolParam(description: "Optional attached file name containing CSV, TSV, or JSON data.")
  var fileName: String? = nil

  @ToolParam(description: "Optional inline CSV, TSV, or JSON text when not reading from an attached file.")
  var data: String? = nil

  @ToolParam(description: "Column name to aggregate for sum/avg/min/max/aggregate/count.")
  var column: String? = nil

  @ToolParam(description: "Optional filter like \"region = West\" or \"price >= 50 AND status != closed\".")
  var whereClause: String? = nil

  @ToolParam(description: "Optional column name to group aggregations by.")
  var groupBy: String? = nil

  @ToolParam(description: "Optional column name to sort filtered rows by.")
  var sortBy: String? = nil

  @ToolParam(description: "Sort descending when true. Default is false.")
  var descending: Bool = false

  @ToolParam(description: "Maximum rows or groups to return (1 to 50). Default is 20.")
  var limit: Int = 20

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    let raw: String
    let label: String
    if let fileName, !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard let lookup = WorkspaceTools.lookupDocumentTextHandler,
        let doc = await lookup(fileName)
      else {
        return ["error": "Attached file '\(fileName)' was not found."]
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
      return [
        "source": label,
        "format": output.format,
        "total_rows": output.totalRows,
        "matched_rows": output.matchedRows,
        "columns": output.columns,
        "result": ToolBudget.fit(PromptText.neutralized(output.summary), limits),
      ]
    } catch {
      ToolActivity.record(Self.name, summary: "Couldn't query \(label)")
      let reason = (error as? LocalizedError)?.errorDescription ?? "Query failed."
      return ["error": reason]
    }
  }
}
