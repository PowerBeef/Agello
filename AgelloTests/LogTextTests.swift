import XCTest

@testable import Agello

/// Error logs name the error's kind, never its text (an error can carry the model's response).
final class LogTextTests: XCTestCase {
  private enum Wrapped: Error {
    case invalidResponse(String)
    case plain
  }

  func testCaseNamesWithoutTheirValues() {
    XCTAssertEqual(LogText.errorKind(ChatError.contextFull), "ChatError.contextFull")
    let underlying = LogText.errorKind(ChatError.underlying(message: "My name is Alice"))
    XCTAssertEqual(underlying, "ChatError.underlying")
    let wrapped = LogText.errorKind(Wrapped.invalidResponse("{\"memories\": [\"Lives in Montreal\"]}"))
    XCTAssertEqual(wrapped, "Wrapped.invalidResponse")
    XCTAssertEqual(LogText.errorKind(Wrapped.plain), "Wrapped.plain")
  }

  func testFoundationErrorsByDomainAndCode() {
    let error = NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [NSLocalizedDescriptionKey: "secret"])
    XCTAssertEqual(LogText.errorKind(error), "NSURLErrorDomain -1001")
  }
}
