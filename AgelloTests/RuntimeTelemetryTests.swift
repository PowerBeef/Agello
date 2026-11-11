import XCTest

@testable import Agello

final class RuntimeTelemetryTests: XCTestCase {
  private func totals(prefilled: Int, decoded: Int, prefillMs: Double, decodeMs: Double) -> TelemetryTotals {
    TelemetryTotals(
      tokensPrefilled: prefilled, tokensDecoded: decoded, prefillMilliseconds: prefillMs,
      decodeMilliseconds: decodeMs)
  }

  /// Reply stats come from the runtime's telemetry alone: the runtime the app links has it.
  func testTheRuntimeHasTelemetry() {
    XCTAssertNotNil(RuntimeTelemetry.totals())
  }

  func testParsesCountersAndSpanTotals() throws {
    let json = """
      {"counters": {"tokens_prefilled": 738, "tokens_decoded": 286, "mtp_rounds": 72},
       "spans": {"turn.prefill": {"count": 1, "total_ms": 612.5}, "turn.decode": {"count": 1, "total_ms": 2000}},
       "anomalies": []}
      """
    let parsed = try XCTUnwrap(TelemetryTotals(json: Data(json.utf8)))
    XCTAssertEqual(parsed, totals(prefilled: 738, decoded: 286, prefillMs: 612.5, decodeMs: 2000))
  }

  func testCountersWithoutSpansParseWithNoTimes() throws {
    // Level 1 records counters only.
    let json = #"{"counters": {"tokens_prefilled": 12, "tokens_decoded": 30}}"#
    let parsed = try XCTUnwrap(TelemetryTotals(json: Data(json.utf8)))
    XCTAssertEqual(parsed, totals(prefilled: 12, decoded: 30, prefillMs: 0, decodeMs: 0))
  }

  func testRejectsSnapshotsWithoutCounters() {
    XCTAssertNil(TelemetryTotals(json: Data("not json".utf8)))
    XCTAssertNil(TelemetryTotals(json: Data(#"{"spans": {}}"#.utf8)))
  }

  func testAReplyIsTheDifferenceOfTheTotals() throws {
    let before = totals(prefilled: 100, decoded: 50, prefillMs: 200, decodeMs: 1000)
    let after = totals(prefilled: 838, decoded: 336, prefillMs: 812.5, decodeMs: 3000)
    let reply = try XCTUnwrap(ReplyTelemetry(before: before, after: after))
    XCTAssertEqual(reply.inputTokens, 738)
    XCTAssertEqual(reply.outputTokens, 286)
    XCTAssertEqual(try XCTUnwrap(reply.decodeTokensPerSecond), 143, accuracy: 1e-9)
  }

  func testAResetDuringTheReplyGivesNoStats() {
    // The test harness resets telemetry for each scenario.
    let before = totals(prefilled: 900, decoded: 400, prefillMs: 700, decodeMs: 3000)
    let after = totals(prefilled: 40, decoded: 20, prefillMs: 30, decodeMs: 150)
    XCTAssertNil(ReplyTelemetry(before: before, after: after))
  }

  func testAReplyThatDecodedNothingGivesNoStats() {
    let before = totals(prefilled: 100, decoded: 50, prefillMs: 200, decodeMs: 1000)
    XCTAssertNil(ReplyTelemetry(before: before, after: before))
  }

  func testWithoutDecodeTimesTheSpeedIsUnknown() throws {
    let before = totals(prefilled: 0, decoded: 0, prefillMs: 0, decodeMs: 0)
    let after = totals(prefilled: 40, decoded: 25, prefillMs: 0, decodeMs: 0)
    let reply = try XCTUnwrap(ReplyTelemetry(before: before, after: after))
    XCTAssertEqual(reply.outputTokens, 25)
    XCTAssertNil(reply.decodeTokensPerSecond)
  }
}
