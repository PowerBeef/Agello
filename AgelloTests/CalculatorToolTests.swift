import XCTest

@testable import Agello

final class CalculatorToolTests: XCTestCase {
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
