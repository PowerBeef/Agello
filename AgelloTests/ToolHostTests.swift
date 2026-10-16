import XCTest

@testable import Agello

/// Tool budgets (KV-cache safety) and helper-task parsing.
final class ToolHostTests: XCTestCase {
  override func tearDown() {
    ToolBudget.reset()
    super.tearDown()
  }

  /// A tool round that outlives its reply (the stream was stopped while a tool ran) must not
  /// get the unrestricted budget: its result would land in a KV cache nobody budgeted.
  func testNoToolCallsAfterTheReplyEnded() {
    ToolBudget.begin(.init(maxResultTokens: 40, maxCalls: 2))
    ToolBudget.end()
    XCTAssertNil(ToolBudget.claim())
    ToolBudget.reset()
    XCTAssertNotNil(ToolBudget.claim(), "Direct calls (tests, probes) are unrestricted")
  }

  func testCallLimitIsEnforcedPerReply() {
    ToolBudget.begin(.init(maxResultTokens: 40, maxCalls: 2))
    XCTAssertNotNil(ToolBudget.claim())
    XCTAssertNotNil(ToolBudget.claim())
    XCTAssertNil(ToolBudget.claim(), "Third call must be refused")
    ToolBudget.begin(.init(maxResultTokens: 40, maxCalls: 2))
    XCTAssertNotNil(ToolBudget.claim(), "A new reply starts a fresh budget")
  }

  func testNoToolsWhenToolsAreOff() {
    ToolBudget.begin(.init(maxResultTokens: 40, maxCalls: 0))
    XCTAssertNil(ToolBudget.claim())
  }

  func testPlanSplitsTheRoomWhenAnyToolIsOffered() {
    let plan = ToolBudget.plan(room: 4_000, toolsOffered: true)
    XCTAssertEqual(plan.outputCap, 1_000, "A quarter of the room per generation")
    XCTAssertEqual(plan.limits.maxCalls, 2)
    XCTAssertEqual(plan.limits.maxResultTokens, 500)
    // Two tool results plus three generations fit the room.
    XCTAssertLessThanOrEqual(3 * plan.outputCap + 2 * plan.limits.maxResultTokens, 4_000)
  }

  /// Think's reasoning can't use up a round: the first round grows to the reasoning budget plus
  /// an answer (up to half the room), the reasoning shrinks to leave the answer room when the
  /// round is small, and the whole reply still fits the room.
  func testThinkingLeavesEveryReplyAnAnswer() {
    for room in [600, 2_000, 4_000, 7_000, 30_000] {
      for thinking in [128, 1_024, 4_096] {
        let plan = ToolBudget.plan(room: room, toolsOffered: true, thinkingBudget: thinking)
        let reasoning = try? XCTUnwrap(plan.thinkingBudget)
        XCTAssertLessThanOrEqual(reasoning ?? .max, thinking)
        XCTAssertGreaterThanOrEqual(
          plan.outputCap - (reasoning ?? 0), min(ToolBudget.answerTokens, plan.outputCap / 2),
          "room \(room), thinking \(thinking)")
        XCTAssertLessThanOrEqual(plan.outputCap, room / 2)
        XCTAssertLessThanOrEqual(
          plan.outputCap + 2 * plan.followUpCap + 2 * plan.limits.maxResultTokens, room)
      }
    }
    // Room enough: the whole budget plus an answer.
    let roomy = ToolBudget.plan(room: 7_000, toolsOffered: true, thinkingBudget: 1_024)
    XCTAssertEqual(roomy.thinkingBudget, 1_024)
    XCTAssertGreaterThanOrEqual(roomy.outputCap, 1_024 + ToolBudget.answerTokens)
    // Without Think the split is unchanged.
    let plain = ToolBudget.plan(room: 4_000, toolsOffered: true)
    XCTAssertNil(plain.thinkingBudget)
    XCTAssertEqual(plain.outputCap, 1_000)
    XCTAssertEqual(plain.followUpCap, 1_000)
  }

  /// A reply cap set in options applies to every round, and the reasoning fits inside it.
  func testMaxOutputTokensCapsEveryRoundAndLeavesAnAnswer() {
    let plan = ToolBudget.plan(
      room: 7_000, toolsOffered: true, thinkingBudget: 1_024, maxOutputTokens: 400)
    XCTAssertEqual(plan.outputCap, 400)
    XCTAssertEqual(plan.followUpCap, 400)
    XCTAssertEqual(plan.thinkingBudget, 200)
    let solo = ToolBudget.plan(room: 7_000, toolsOffered: false, thinkingBudget: 4_096)
    XCTAssertEqual(solo.outputCap, 7_000)
    XCTAssertEqual(solo.thinkingBudget, 4_096)
  }

  func testPlanGivesTheWholeRoomWithoutTools() {
    let plan = ToolBudget.plan(room: 4_000, toolsOffered: false)
    XCTAssertEqual(plan.outputCap, 4_000)
    XCTAssertEqual(plan.limits.maxCalls, 0)
  }

  func testResultsAreTrimmedToBudgetAndAccounted() {
    let limits = ToolBudget.Limits(maxResultTokens: 4, maxCalls: 1)
    ToolBudget.begin(limits)
    let fitted = ToolBudget.fit("héllo wörld, this is long", limits)
    XCTAssertLessThanOrEqual(ContextBudget.estimateTextTokens(fitted), 4)
    XCTAssertTrue(fitted.hasPrefix("hél"))
    XCTAssertTrue(fitted.hasSuffix("…"))
    XCTAssertEqual(ToolBudget.resultTokens, ContextBudget.estimateTextTokens(fitted))
    XCTAssertEqual(ToolBudget.fit("ok", limits), "ok")
  }

  /// Gemma reads a token per digit: a table of numbers is trimmed by tokens, not bytes, or two
  /// results three times their budget would overflow the room.
  func testDigitResultsAreTrimmedByTokens() {
    let limits = ToolBudget.Limits(maxResultTokens: 100, maxCalls: 1)
    ToolBudget.begin(limits)
    let table = (0..<200).map { "\($0 * 7919)" }.joined(separator: " ")
    let fitted = ToolBudget.fit(table, limits)
    let digits = fitted.filter(\.isNumber).count
    XCTAssertLessThanOrEqual(digits, 100)
    XCTAssertGreaterThan(digits, 60, "Trimmed far more than needed")
    XCTAssertLessThanOrEqual(ToolBudget.resultTokens, 100)
  }

  func testCalculatorRefusesBeyondTheLimitAndRecordsActivity() async throws {
    ToolBudget.begin(.init(maxResultTokens: 40, maxCalls: 1))
    let cursor = ToolActivity.cursor
    var tool = CalculatorTool()
    tool.expression = "6*7"
    let first = try await tool.run() as? [String: Any]
    XCTAssertEqual(first?["result"] as? Double, 42)
    let second = try await tool.run() as? [String: Any]
    XCTAssertNotNil(second?["error"])
    XCTAssertEqual(ToolActivity.records(since: cursor).map(\.summary), ["Calculated 6*7"])
  }

  func testTitleParsing() {
    XCTAssertEqual(HelperTasks.parseTitle(Data(#"{"title":"Lighthouse Keepers"}"#.utf8)), "Lighthouse Keepers")
    XCTAssertEqual(HelperTasks.cleanTitle(#"  "Trip to Kyoto."  "#), "Trip to Kyoto")
    XCTAssertEqual(HelperTasks.cleanTitle("Title: Bread\n baking"), "Title: Bread baking")
    XCTAssertNil(HelperTasks.cleanTitle(" ** "))
    XCTAssertNil(HelperTasks.parseTitle(Data("not json".utf8)))
    let long = HelperTasks.cleanTitle(String(repeating: "word ", count: 30))
    XCTAssertLessThanOrEqual(long?.count ?? 0, HelperTasks.maxTitleLength)
    XCTAssertFalse(long?.hasSuffix(" ") ?? true)
  }

  func testTitlePromptIsBounded() {
    let prompt = HelperTasks.titlePrompt(
      user: String(repeating: "a", count: 5_000), reply: String(repeating: "b", count: 5_000))
    XCTAssertLessThan(prompt.utf8.count, 1_600)
  }
}
