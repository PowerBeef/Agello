import XCTest

@testable import Agello

final class CalculatorToolTests: XCTestCase {
  // The tool budget is global: don't leave a spent one for the next test.
  override func tearDown() {
    ToolBudget.end()
    super.tearDown()
  }

  func testPrecedence() throws {
    XCTAssertEqual(try ArithmeticParser.evaluate("2+3*4"), 14)
    XCTAssertEqual(try ArithmeticParser.evaluate("(2+3)*4"), 20)
    XCTAssertEqual(try ArithmeticParser.evaluate("(12.5*3)+4"), 41.5)
  }

  func testUnaryAndRemainder() throws {
    XCTAssertEqual(try ArithmeticParser.evaluate("-5+2"), -3)
    XCTAssertEqual(try ArithmeticParser.evaluate("10/4"), 2.5)
    XCTAssertEqual(try ArithmeticParser.evaluate("10%3"), 1)
    XCTAssertEqual(try ArithmeticParser.evaluate("  7  "), 7)
  }

  func testErrors() {
    XCTAssertThrowsError(try ArithmeticParser.evaluate("")) { error in
      XCTAssertEqual(error as? CalculatorError, .emptyExpression)
    }
    XCTAssertThrowsError(try ArithmeticParser.evaluate("1/0")) { error in
      XCTAssertEqual(error as? CalculatorError, .divisionByZero)
    }
    XCTAssertThrowsError(try ArithmeticParser.evaluate("2+")) { error in
      XCTAssertEqual(error as? CalculatorError, .malformed)
    }
    XCTAssertThrowsError(try ArithmeticParser.evaluate("2&2")) { error in
      XCTAssertEqual(error as? CalculatorError, .invalidCharacter("&"))
    }
    // Hostile input must never evaluate: no function calls, no identifiers.
    XCTAssertThrowsError(try ArithmeticParser.evaluate("sqrt(4)"))
    XCTAssertThrowsError(try ArithmeticParser.evaluate("__import__('os')"))
  }

  func testPowers() throws {
    XCTAssertEqual(try ArithmeticParser.evaluate("2^10"), 1024)
    XCTAssertEqual(try ArithmeticParser.evaluate("2 ** 10"), 1024)
    XCTAssertEqual(try ArithmeticParser.evaluate("-2^2"), -4)
    XCTAssertEqual(try ArithmeticParser.evaluate("2^3^2"), 512)
    XCTAssertEqual(try ArithmeticParser.evaluate("16^0.5"), 4)
    XCTAssertEqual(try ArithmeticParser.evaluate("2^-1"), 0.5)
    XCTAssertEqual(try ArithmeticParser.evaluate("3*2^2"), 12)
    // The tour's savings question: $250 a month at 4% for 5 years.
    XCTAssertEqual(
      try ArithmeticParser.evaluate("250 * ((1 + 0.04/12)^60 - 1) / (0.04/12)"), 16_574.74, accuracy: 0.01)
    XCTAssertEqual(
      try ArithmeticParser.evaluate("250 * (((1 + 0.04/12)**60) - 1) / (0.04/12)"), 16_574.74, accuracy: 0.01)
  }

  func testPercent() throws {
    XCTAssertEqual(try ArithmeticParser.evaluate("86.40 * 18%"), 15.552, accuracy: 1e-9)
    XCTAssertEqual(try ArithmeticParser.evaluate("4% / 12"), 0.04 / 12, accuracy: 1e-12)
    XCTAssertEqual(try ArithmeticParser.evaluate("50%"), 0.5)
    XCTAssertEqual(try ArithmeticParser.evaluate("(1 + 5%)^2"), 1.1025, accuracy: 1e-12)
    // An operand after % keeps the remainder.
    XCTAssertEqual(try ArithmeticParser.evaluate("10 % 3"), 1)
    XCTAssertEqual(try ArithmeticParser.evaluate("10%(2+1)"), 1)
  }

  func testCurrencySeparatorsAndTypographicOperators() throws {
    XCTAssertEqual(try ArithmeticParser.evaluate("$250 * 60"), 15_000)
    XCTAssertEqual(try ArithmeticParser.evaluate("1,000 * 1.04"), 1_040)
    XCTAssertEqual(try ArithmeticParser.evaluate("1,234,567 + 1"), 1_234_568)
    XCTAssertEqual(try ArithmeticParser.evaluate("€12.50 × 4"), 50)
    XCTAssertEqual(try ArithmeticParser.evaluate("10 ÷ 4 \u{2212} 0.5"), 2)
    // A decimal comma isn't a thousands separator: rejected, not misread.
    XCTAssertThrowsError(try ArithmeticParser.evaluate("1,5 * 2")) { error in
      XCTAssertEqual(error as? CalculatorError, .invalidCharacter(","))
    }
  }

  func testNonFiniteResults() {
    XCTAssertThrowsError(try ArithmeticParser.evaluate("10^400")) { error in
      XCTAssertEqual(error as? CalculatorError, .notFinite)
    }
    XCTAssertThrowsError(try ArithmeticParser.evaluate("(-8)^0.5")) { error in
      XCTAssertEqual(error as? CalculatorError, .notFinite)
    }
  }

  /// A thrown error would end the whole reply (LiteRT-LM), so the tool
  /// answers with an error the model can act on.
  func testToolRunReturnsErrorsInsteadOfThrowing() async throws {
    ToolBudget.begin(.init(maxResultBytes: 400, maxCalls: 3))
    for expression in ["2^", "sqrt(4)", "1/0"] {
      var tool = CalculatorTool()
      tool.expression = expression
      let output = try await tool.run() as? [String: Any]
      XCTAssertNil(output?["result"], expression)
      let message = try XCTUnwrap(output?["error"] as? String, expression)
      XCTAssertTrue(message.contains("^ for powers"), message)
    }
  }

  func testToolRoundsResultsForTheModel() async throws {
    ToolBudget.begin(.init(maxResultBytes: 400, maxCalls: 2))
    var tool = CalculatorTool()
    tool.expression = "0.1 + 0.2"
    let output = try await tool.run() as? [String: Any]
    XCTAssertEqual(output?["result"] as? Double, 0.3)
  }

  func testToolRunReturnsResult() async throws {
    var tool = CalculatorTool()
    tool.expression = "(12.5*3)+4"
    let output = try await tool.run() as? [String: Any]
    XCTAssertEqual(output?["result"] as? Double, 41.5)
    XCTAssertEqual(output?["expression"] as? String, "(12.5*3)+4")
  }

  func testToolNaming() {
    XCTAssertEqual(CalculatorTool.name, "calculate")
    XCTAssertFalse(CalculatorTool.description.isEmpty)
    XCTAssertEqual(CurrentDateTimeTool.name, "get_current_date_time")
  }
}
