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

  // MARK: - The base and its slots

  /// Tuesday, November 17, 2026, noon in Montreal.
  private let day = Date(timeIntervalSince1970: 1_794_934_800)

  func testTheDefaultBaseIsFilledWithNoSlotLeft() {
    XCTAssertEqual(InferenceOptions().systemPrompt, SystemPrompt.base)
    let prompt = SystemPrompt.compose(
      base: SystemPrompt.base, personalization: Personalization(), project: nil, today: day, current: .tapSearch)
    XCTAssertTrue(prompt.hasPrefix("You are Agello, an assistant running on the user's iPhone. Today is "), prompt)
    XCTAssertTrue(prompt.contains("November 17, 2026."), prompt)
    XCTAssertTrue(prompt.contains("say it may be out of date; the user can tap Search for current information."))
    XCTAssertFalse(prompt.contains("{"), prompt)
    XCTAssertFalse(prompt.contains(SystemPrompt.precedenceLine))
    XCTAssertTrue(prompt.hasSuffix("still give your best answer."))
  }

  func testCurrentInformationFollowsTheSearchSettings() {
    var settings = WebSearchSettings()
    XCTAssertEqual(SystemPrompt.CurrentInfo(webSettings: settings), .tapSearch)
    settings.automatic = true
    XCTAssertEqual(SystemPrompt.CurrentInfo(webSettings: settings), .automaticSearch)
    settings.allowed = false
    XCTAssertEqual(SystemPrompt.CurrentInfo(webSettings: settings), SystemPrompt.CurrentInfo.none)
    let automatic = SystemPrompt.fill(SystemPrompt.base, today: day, current: .automaticSearch, precedence: false)
    XCTAssertTrue(automatic.contains("out of date; use web_search when a question needs current facts."))
    let offline = SystemPrompt.fill(SystemPrompt.base, today: day, current: .none, precedence: false)
    XCTAssertTrue(offline.contains("say it may be out of date.\n"), offline)
  }

  func testPrecedenceOnlyWhenPreferencesOrAProjectFollow() {
    func prompt(_ personalization: Personalization, project: ProjectContext? = nil, memories: [String] = []) -> String {
      SystemPrompt.compose(
        base: SystemPrompt.base, personalization: personalization, project: project, memories: memories, today: day)
    }
    XCTAssertFalse(prompt(Personalization(), memories: ["Likes tea."]).contains(SystemPrompt.precedenceLine))
    var named = Personalization()
    named.name = "Sam"
    XCTAssertTrue(
      prompt(named).contains("still give your best answer.\n\n\(SystemPrompt.precedenceLine)\n\nThe user's name is Sam."))
    var concise = Personalization()
    concise.style = .concise
    XCTAssertTrue(prompt(concise).contains(SystemPrompt.precedenceLine))
    named.enabled = false
    XCTAssertFalse(prompt(named).contains(SystemPrompt.precedenceLine))
    let project = ProjectContext(id: UUID(), name: "Trip", instructions: "Plan in metric.")
    XCTAssertTrue(prompt(Personalization(), project: project).contains(SystemPrompt.precedenceLine))
  }

  func testABaseWithoutSlotsIsUnchanged() {
    var named = Personalization()
    named.name = "Sam"
    XCTAssertEqual(
      SystemPrompt.compose(base: base, personalization: named, project: nil, today: day, current: .automaticSearch),
      base + "\n\nThe user's name is Sam.")
  }

  func testPreambleGrowsWithTheSystemPrompt() {
    let short = ContextBudget.preambleTokens(systemPrompt: base)
    let long = ContextBudget.preambleTokens(systemPrompt: base + String(repeating: "x", count: 3000))
    XCTAssertGreaterThanOrEqual(long - short, 1000)
  }
}
