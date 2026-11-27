@_spi(Testing) import LiteRTLMTools
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
    XCTAssertEqual(plan.outputCap, 2_000, "Half the room for the round that answers")
    XCTAssertEqual(plan.followUpCap, 500)
    XCTAssertEqual(plan.limits.maxCalls, 2)
    XCTAssertEqual(plan.limits.maxResultTokens, 500)
    // Two tool results plus three generations fit the room.
    XCTAssertLessThanOrEqual(plan.outputCap + 2 * plan.followUpCap + 2 * plan.limits.maxResultTokens, 4_000)
  }

  /// Probe 23: with tools offered, a long answer stopped at a quarter of the room, reasoning
  /// included (about 1,960 tokens in a new 8K chat). Now the answer keeps half the room, with the
  /// reasoning budget on top, and at least a quarter deep in a chat.
  func testLongAnswersKeepHalfTheRoomWithThink() {
    // A new 16K chat (about 15,800 tokens free) and one trimmed down to its reply reserve.
    for (room, share) in [(15_800, 2), (5_120, 4)] {
      let plan = ToolBudget.plan(room: room, toolsOffered: true, thinkingBudget: 1_024)
      let reasoning = plan.thinkingBudget ?? 0
      XCTAssertEqual(reasoning, 1_024)
      XCTAssertGreaterThanOrEqual(plan.outputCap - reasoning, room / share, "room \(room)")
      // A tool round still has its reasoning budget plus an answer when the room allows.
      XCTAssertGreaterThanOrEqual(plan.followUpCap, min(room / 8, 1_024 + ToolBudget.answerTokens))
    }
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
        let followUpReasoning = try? XCTUnwrap(plan.followUpThinkingBudget)
        XCTAssertLessThanOrEqual(followUpReasoning ?? .max, thinking)
        XCTAssertGreaterThanOrEqual(
          plan.followUpCap - (followUpReasoning ?? 0),
          min(ToolBudget.answerTokens, plan.followUpCap / 2),
          "follow-up room \(room), thinking \(thinking)")
        XCTAssertLessThanOrEqual(plan.outputCap, room / 2 + thinking)
        XCTAssertLessThanOrEqual(
          plan.outputCap + 2 * plan.followUpCap + 2 * plan.limits.maxResultTokens, room)
      }
    }
    // Room enough: the whole budget plus an answer.
    let roomy = ToolBudget.plan(room: 7_000, toolsOffered: true, thinkingBudget: 1_024)
    XCTAssertEqual(roomy.thinkingBudget, 1_024)
    XCTAssertGreaterThanOrEqual(roomy.outputCap, 1_024 + ToolBudget.answerTokens)
    // Without Think the first round gets half the room.
    let plain = ToolBudget.plan(room: 4_000, toolsOffered: true)
    XCTAssertNil(plain.thinkingBudget)
    XCTAssertNil(plain.followUpThinkingBudget)
    XCTAssertEqual(plain.outputCap, 2_000)
    XCTAssertEqual(plain.followUpCap, 500)
  }

  /// A reply cap set in options applies to every round, and the reasoning fits inside it.
  func testMaxOutputTokensCapsEveryRoundAndLeavesAnAnswer() {
    let plan = ToolBudget.plan(
      room: 7_000, toolsOffered: true, thinkingBudget: 1_024, maxOutputTokens: 400)
    XCTAssertEqual(plan.outputCap, 400)
    XCTAssertEqual(plan.followUpCap, 400)
    XCTAssertEqual(plan.thinkingBudget, 200)
    XCTAssertEqual(plan.followUpThinkingBudget, 200)
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

  /// Regression for RT-P0-10: 64-bit integer boundaries (`Int.max`, `2^63 - 512`, `2^53 + 1`) and
  /// overflowing numeric values (`"9223372036854775808"`, `NSNumber(value: 2^63)`) must never trap in
  /// `Int(Double)` or lose precision through IEEE 754 binary64.
  func testToolManagerIntegerCoercionHandles64BitBoundariesWithoutTrapping() async throws {
    let nearMax = Int.max - 511  // 2^63 - 512 (rounds up to 2^63 in Double)
    let beyondDoublePrecision = (1 << 53) + 1  // 9_007_199_254_740_993

    // Exact 64-bit integers and integer NSNumbers preserve full precision without trapping.
    XCTAssertEqual(ToolManager.coerceArgument(Int.max, expectedType: "integer") as? Int, Int.max)
    XCTAssertEqual(ToolManager.coerceArgument(Int.min, expectedType: "integer") as? Int, Int.min)
    XCTAssertEqual(ToolManager.coerceArgument(nearMax, expectedType: "integer") as? Int, nearMax)
    XCTAssertEqual(
      ToolManager.coerceArgument(beyondDoublePrecision, expectedType: "integer") as? Int,
      beyondDoublePrecision)
    XCTAssertEqual(
      ToolManager.coerceArgument(NSNumber(value: Int.max), expectedType: "integer") as? Int,
      Int.max)
    XCTAssertEqual(
      ToolManager.coerceArgument(NSNumber(value: Int.min), expectedType: "integer") as? Int,
      Int.min)
    XCTAssertEqual(
      ToolManager.coerceArgument(NSNumber(value: nearMax), expectedType: "integer") as? Int,
      nearMax)
    XCTAssertEqual(
      ToolManager.coerceArgument(NSNumber(value: beyondDoublePrecision), expectedType: "integer") as? Int,
      beyondDoublePrecision)

    // Stringified exact 64-bit integers & whole-number decimals coerce accurately.
    XCTAssertEqual(
      ToolManager.coerceArgument("9223372036854775807", expectedType: "integer") as? Int, Int.max)
    XCTAssertEqual(
      ToolManager.coerceArgument("-9223372036854775808", expectedType: "integer") as? Int, Int.min)
    XCTAssertEqual(
      ToolManager.coerceArgument("9007199254740993", expectedType: "integer") as? Int,
      beyondDoublePrecision)
    XCTAssertEqual(ToolManager.coerceArgument("5.0", expectedType: "integer") as? Int, 5)
    XCTAssertEqual(ToolManager.coerceArgument(NSNumber(value: 5.0), expectedType: "integer") as? Int, 5)

    // Out-of-range / non-integer / boolean inputs must remain uncoerced (not Swift `Int`), NEVER trap.
    // Check dynamic type directly to bypass Foundation's `NSNumber -> Int` bridge (which maps 2^63 to Int.max).
    XCTAssertEqual(
      ToolManager.coerceArgument("9223372036854775808", expectedType: "integer") as? String,
      "9223372036854775808")
    let rejectedInputs: [Any] = [
      NSNumber(value: UInt64(Int.max) + 1),
      NSNumber(value: 9_223_372_036_854_775_808.0),
      NSNumber(value: 5.5),
      NSNumber(value: Double.nan),
      NSNumber(value: Double.infinity),
      true,
    ]
    for input in rejectedInputs {
      let coerced = ToolManager.coerceArgument(input, expectedType: "integer")
      XCTAssertNotEqual(ObjectIdentifier(type(of: coerced)), ObjectIdentifier(Int.self))
    }

    // End-to-end ToolManager.execute: exact 64-bit values succeed; overflowing string & float NSNumber throw DecodingError.
    let manager = ToolManager(tools: [EchoIntTool()])
    for exact in [Int.max, Int.min, nearMax, beyondDoublePrecision] {
      let out = try await manager.execute(
        name: EchoIntTool.name, arguments: ["value": NSNumber(value: exact)]) as? [String: Any]
      XCTAssertEqual(out?["value"] as? Int, exact)
    }
    for overflowing: Any in ["9223372036854775808", NSNumber(value: 9_223_372_036_854_775_808.0)] {
      do {
        _ = try await manager.execute(name: EchoIntTool.name, arguments: ["value": overflowing])
        XCTFail("Expected DecodingError for overflowing integer \(overflowing)")
      } catch is DecodingError {
        // Expected clean decode failure (no SIGTRAP).
      }
    }
  }
}

private struct EchoIntTool: Tool {
  static let name = "echo_int"
  static let description = "Echoes an integer."

  @ToolParam(description: "Integer value.")
  var value: Int

  func run() async throws -> Any {
    ["value": value]
  }
}
