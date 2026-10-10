import Foundation
import LiteRTLM

// MARK: - Date / time tool

/// Returns the device's current local date and time. Fully offline.
struct CurrentDateTimeTool: Tool {
  static let name = "get_current_date_time"
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
    let pretty = DateFormatter()
    pretty.timeZone = zone
    pretty.dateStyle = .full
    pretty.timeStyle = .short
    ToolActivity.record(Self.name, summary: "Checked the date and time")
    return [
      "iso8601": iso.string(from: now),
      "human": pretty.string(from: now),
      "timezone": zone.identifier,
    ]
  }
}

// MARK: - Web search tool (automatic mode)

/// Lets the model search the web when a question needs fresh or factual
/// information. Offered only when the user turned on automatic web search.
struct WebSearchTool: Tool {
  static let name = "web_search"
  static let description =
    "Search the web for current events, recent facts, prices, schedules, or anything you are unsure about. Returns numbered sources to cite like [1]."

  @ToolParam(description: "A short, self-contained web search query.")
  var query: String = ""

  /// Runs the search for the app (set by `AppState`); returns the sources
  /// block for the model, or an error message.
  nonisolated(unsafe) static var handler: (@Sendable (String, Int) async -> String)?

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let handler = Self.handler else {
      return ["error": "Web search is unavailable."]
    }
    ToolActivity.record(Self.name, summary: "Searched the web for “\(trimmed)”")
    let result = await handler(trimmed, limits.maxResultBytes)
    return ["sources": ToolBudget.fit(result, limits)]
  }
}

// MARK: - Calculator tool

enum CalculatorError: Error, LocalizedError, Equatable {
  case emptyExpression
  case tooLong
  case invalidCharacter(Character)
  case malformed
  case divisionByZero

  var errorDescription: String? {
    switch self {
    case .emptyExpression: return "Empty expression."
    case .tooLong: return "Expression is too long."
    case .invalidCharacter(let c): return "Invalid character: '\(c)'."
    case .malformed: return "Malformed expression."
    case .divisionByZero: return "Division by zero."
    }
  }
}

/// Safe arithmetic evaluator (recursive descent). Only digits, whitespace,
/// `+ - * / %` and parentheses are accepted; anything else throws.
enum ArithmeticParser {
  static func evaluate(_ input: String) throws -> Double {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw CalculatorError.emptyExpression }
    guard trimmed.count <= 200 else { throw CalculatorError.tooLong }
    var parser = Parser(text: Array(trimmed))
    let value = try parser.parseExpression()
    try parser.expectEnd()
    guard value.isFinite else { throw CalculatorError.malformed }
    return value
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

    mutating func parseFactor() throws -> Double {
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
      if c == "-" {
        advance()
        return -(try parseFactor())
      }
      if c == "+" {
        advance()
        return try parseFactor()
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
        if let c = peek, !"+-*/%()".contains(c), !c.isWhitespace {
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
        if c.isNumber || c == "." || "+-*/%()".contains(c) {
          throw CalculatorError.malformed
        }
        throw CalculatorError.invalidCharacter(c)
      }
    }

    var peek: Character? { index < text.count ? text[index] : nil }
    mutating func advance() { index += 1 }
    mutating func skipSpaces() {
      while let c = peek, c.isWhitespace { index += 1 }
    }
  }
}

/// Evaluates arithmetic locally. Fully offline.
struct CalculatorTool: Tool {
  static let name = "calculate"
  static let description =
    "Evaluate an arithmetic expression with numbers, + - * / % and parentheses. Use it for any exact computation instead of mental math."

  @ToolParam(description: "The expression to evaluate, e.g. '(12.5 * 3) + 4'.")
  var expression: String = ""

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    let shown = ToolBudget.fit(expression, limits)
    let result = try ArithmeticParser.evaluate(expression)
    ToolActivity.record(Self.name, summary: "Calculated \(shown)")
    return ["expression": shown, "result": result]
  }
}
