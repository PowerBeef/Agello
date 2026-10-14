import XCTest

@testable import Agello

final class PersonalizationTests: XCTestCase {
  private let base = "You are a helpful on-device assistant."

  func testEmptyPersonalizationKeepsTheBasePrompt() {
    XCTAssertEqual(Personalization().systemPrompt(base: base), base)
  }

  func testFieldsAreAddedInOrder() {
    var p = Personalization()
    p.name = "  Patrice "
    p.aboutYou = "I build iOS apps."
    p.instructions = "Answer in French."
    p.style = .concise
    XCTAssertEqual(
      p.systemPrompt(base: base),
      """
      You are a helpful on-device assistant.

      Keep answers short and to the point; skip preambles and summaries.

      The user's name is Patrice.

      About the user:
      I build iOS apps.

      How the user wants you to respond:
      Answer in French.
      """)
  }

  func testDisabledPersonalizationIsIgnored() {
    var p = Personalization()
    p.name = "Patrice"
    p.enabled = false
    XCTAssertEqual(p.systemPrompt(base: base), base)
  }

  func testLongFieldsAreCapped() {
    var p = Personalization()
    p.aboutYou = String(repeating: "a", count: 5000)
    let prompt = p.systemPrompt(base: "")
    XCTAssertEqual(prompt.filter { $0 == "a" }.count, Personalization.fieldLimit)
  }

  func testDecodingToleratesMissingAndUnknownKeys() throws {
    let data = Data(#"{"name":"Sam","style":"mystery"}"#.utf8)
    let decoded = try JSONDecoder().decode(Personalization.self, from: data)
    XCTAssertEqual(decoded.name, "Sam")
    XCTAssertEqual(decoded.style, .standard)
    XCTAssertTrue(decoded.enabled)
  }

  func testPreambleGrowsWithTheSystemPrompt() {
    let short = ContextBudget.preambleTokens(systemPrompt: base)
    let long = ContextBudget.preambleTokens(systemPrompt: base + String(repeating: "x", count: 3000))
    XCTAssertGreaterThanOrEqual(long - short, 1000)
  }
}
