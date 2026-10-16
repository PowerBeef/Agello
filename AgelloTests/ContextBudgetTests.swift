import XCTest

@testable import Agello

/// KV-cache budgeting (audit #15: overflowing the window crashed the app).
final class ContextBudgetTests: XCTestCase {
  /// LiteRT-LM gives these files `maxNumTokens` positions up to 32,002 and
  /// 32,000 for any request of 32,003 or more (their export window).
  func testAllocatedPositions() {
    XCTAssertEqual(ContextBudget.allocatedPositions(requested: 8_192), 8_192)
    XCTAssertEqual(ContextBudget.allocatedPositions(requested: 32_000), 32_000)
    XCTAssertEqual(ContextBudget.allocatedPositions(requested: 32_002), 32_002)
    XCTAssertEqual(ContextBudget.allocatedPositions(requested: 32_003), 32_000)
    XCTAssertEqual(ContextBudget.allocatedPositions(requested: 32_768), 32_000)
  }

  private func turns(_ count: Int, length: Int = 300) -> [(role: ChatRole, text: String)] {
    (0..<count).map { i in
      let letter = Character(Unicode.Scalar(UInt8(97 + i % 26)))
      return (i.isMultiple(of: 2) ? .user : .model, String(repeating: letter, count: length))
    }
  }

  func testEstimateIsPessimisticForEnglish() {
    // ~4.5 bytes/token is typical for English; the estimate must not be lower.
    let text = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 20)
    let realisticTokens = text.utf8.count / 4
    XCTAssertGreaterThan(ContextBudget.estimateTokens(text), realisticTokens)
  }

  /// Gemma splits numbers into single digits and reads about a token per ideograph: estimates
  /// made without its tokenizer must not fall below that.
  func testEstimateCoversDigitsAndIdeographs() {
    let digits = String(repeating: "2026-10-16 ", count: 30)
    XCTAssertGreaterThanOrEqual(
      ContextBudget.estimateTextTokens(digits), digits.filter(\.isNumber).count)
    let chinese = String(repeating: "上下文窗口", count: 40)
    XCTAssertGreaterThanOrEqual(ContextBudget.estimateTextTokens(chinese), chinese.count)
    // English stays at 3 bytes a token.
    let english = String(repeating: "The quick brown fox. ", count: 10)
    XCTAssertEqual(
      ContextBudget.estimateTextTokens(english),
      Int((Double(english.utf8.count) / ContextBudget.bytesPerToken).rounded(.up)))
    XCTAssertEqual(
      ContextBudget.estimateTextTokens(bytes: digits.utf8.count, weight: Chunker.weight(of: digits)),
      ContextBudget.estimateTextTokens(digits))
  }

  /// With the engine's exact counts, trimming follows them rather than the estimate.
  func testTrimmedHistoryUsesExactCountsWhenGiven() {
    let history = turns(6, length: 300)
    // Each turn of 300 letters is estimated at 100 tokens; say the tokenizer counts 40.
    let exact = Array(repeating: 40, count: history.count)
    let budget = 3 * (40 + ContextBudget.perTurnOverhead)
    let estimated = ContextBudget.trimmedHistory(history, budget: budget)
    let counted = ContextBudget.trimmedHistory(history, budget: budget, tokens: exact)
    XCTAssertGreaterThan(counted.count, estimated.count)
    XCTAssertEqual(counted.last?.text, history.last?.text)
    XCTAssertEqual(counted.first?.role, .user)
  }

  /// A reply too long to keep whole is cut in proportion to its counted tokens.
  func testTruncationFollowsCountedTokens() {
    let reply = String(repeating: "Ice moves. ", count: 120)
    let history: [(role: ChatRole, text: String)] = [(.user, "Glaciers?"), (.model, reply)]
    // Say the reply really takes 600 tokens, and there's room for about 200 of them.
    let budget = 4 + 200 + 2 * ContextBudget.perTurnOverhead + 2
    let trimmed = ContextBudget.trimmedHistory(history, budget: budget, tokens: [4, 600])
    XCTAssertEqual(trimmed.map(\.role), [.user, .model])
    let kept = trimmed.last?.text ?? ""
    let share = Double(kept.utf8.count) / Double(reply.utf8.count)
    XCTAssertEqual(share, 200.0 / 600.0, accuracy: 0.02)
  }

  func testImageAndAudioCountTowardInput() {
    let textOnly = ContextBudget.estimateInput(text: "hi", imageTokens: nil, audioSeconds: nil)
    let withImage = ContextBudget.estimateInput(text: "hi", imageTokens: 280, audioSeconds: nil)
    let withAudio = ContextBudget.estimateInput(text: "hi", imageTokens: nil, audioSeconds: 10)
    XCTAssertGreaterThanOrEqual(withImage - textOnly, 280)
    XCTAssertGreaterThanOrEqual(withAudio - textOnly, 250)
  }

  func testFitsLeavesRoomForReplyAndMargin() {
    XCTAssertTrue(ContextBudget.fits(used: 100, input: 50, maxNumTokens: 4096, thinkingBudget: nil))
    // 1024 window: reserve is 341 + 64 margin.
    XCTAssertFalse(ContextBudget.fits(used: 600, input: 50, maxNumTokens: 1024, thinkingBudget: nil))
  }

  func testThinkingEnlargesReserveButIsCappedByWindow() {
    let plain = ContextBudget.replyReserve(maxNumTokens: 8192, thinkingBudget: nil)
    let thinking = ContextBudget.replyReserve(maxNumTokens: 8192, thinkingBudget: 1024)
    XCTAssertGreaterThan(thinking, plain)
    XCTAssertLessThanOrEqual(
      ContextBudget.replyReserve(maxNumTokens: 1024, thinkingBudget: 4096), 1024 / 3)
  }

  func testTrimmedHistoryKeepsNewestWithinBudgetStartingOnUser() {
    let history = turns(10)
    let budget = 400
    let trimmed = ContextBudget.trimmedHistory(history, budget: budget)
    XCTAssertFalse(trimmed.isEmpty)
    XCTAssertLessThanOrEqual(ContextBudget.estimateHistory(trimmed), budget)
    XCTAssertEqual(trimmed.first?.role, .user)
    // Newest turns survive.
    XCTAssertEqual(trimmed.last?.text, history.last?.text)
  }

  /// Device finding: at a 1024 window the newest reply alone exceeded the
  /// history budget and every turn was dropped.
  func testOversizedLatestReplyIsTruncatedNotDropped() {
    let history: [(role: ChatRole, text: String)] = [
      (.user, "Write about volcanoes."), (.model, String(repeating: "Lava flows. ", count: 60)),
      (.user, "Write about glaciers."), (.model, String(repeating: "Ice moves. ", count: 120)),
    ]
    let budget = 344
    let trimmed = ContextBudget.trimmedHistory(history, budget: budget)
    XCTAssertEqual(trimmed.map(\.role), [.user, .model])
    XCTAssertEqual(trimmed.first?.text, "Write about glaciers.")
    XCTAssertTrue(trimmed.last?.text.hasSuffix("…") ?? false)
    XCTAssertTrue(trimmed.last?.text.hasPrefix("Ice moves.") ?? false)
    XCTAssertLessThanOrEqual(ContextBudget.estimateHistory(trimmed), budget)
  }

  /// Device finding (second trim, 1024 window): the newest reply fit the
  /// budget on its own but its prompt didn't, so the leading-user rule
  /// dropped everything ("replaying 0/10 turns").
  func testReplyThatFitsAloneKeepsItsPrompt() {
    let prompt = "Write about 120 words on rainforests."
    let budget = 344
    // A reply whose estimate is just under the whole budget.
    let replyBytes = Int(Double(budget - ContextBudget.perTurnOverhead - 1) * ContextBudget.bytesPerToken)
    let reply = String(repeating: "r", count: replyBytes)
    XCTAssertLessThanOrEqual(ContextBudget.estimateTokens(reply), budget)
    let history: [(role: ChatRole, text: String)] = [
      (.user, "Write about deserts."), (.model, "Deserts are dry."),
      (.user, prompt), (.model, reply),
    ]
    let trimmed = ContextBudget.trimmedHistory(history, budget: budget)
    XCTAssertEqual(trimmed.map(\.role), [.user, .model])
    XCTAssertEqual(trimmed.first?.text, prompt)
    XCTAssertTrue(trimmed.last?.text.hasSuffix("…") ?? false)
    XCTAssertLessThanOrEqual(ContextBudget.estimateHistory(trimmed), budget)
  }

  func testPrefixNeverSplitsCharacters() {
    XCTAssertEqual(ContextBudget.prefix("héllo", maxBytes: 2), "h")
    XCTAssertEqual(ContextBudget.prefix("héllo", maxBytes: 3), "hé")
    XCTAssertEqual(ContextBudget.prefix("👍👍", maxBytes: 5), "👍")
  }

  func testTrimmedHistoryCanBeEmpty() {
    XCTAssertTrue(ContextBudget.trimmedHistory(turns(4, length: 5000), budget: 100).isEmpty)
  }

  func testHistoryBudgetUsesAtMostHalfTheWindow() {
    let budget = ContextBudget.historyBudget(maxNumTokens: 8192, input: 50, thinkingBudget: nil)
    XCTAssertLessThanOrEqual(budget, 4096)
    XCTAssertGreaterThan(budget, 0)
    XCTAssertEqual(
      ContextBudget.historyBudget(maxNumTokens: 1024, input: 900, thinkingBudget: nil), 0)
  }

  /// After trimming, the full send must fit: preamble + history + input + reply.
  func testTrimmedConversationFitsTheWindow() {
    for window in [1024, 2048, 4096] {
      let input = ContextBudget.estimateInput(
        text: String(repeating: "a", count: 600), imageTokens: nil, audioSeconds: nil)
      let budget = ContextBudget.historyBudget(
        maxNumTokens: window, input: input, thinkingBudget: nil)
      let trimmed = ContextBudget.trimmedHistory(turns(40), budget: budget)
      let used = ContextBudget.preambleTokens + ContextBudget.estimateHistory(trimmed)
      XCTAssertTrue(
        ContextBudget.fits(used: used, input: input, maxNumTokens: window, thinkingBudget: nil),
        "window \(window)")
      XCTAssertNotNil(ContextBudget.outputCap(maxNumTokens: window, used: used, input: input))
    }
  }

  func testOutputCapNeverExceedsRemainingRoom() {
    let cap = ContextBudget.outputCap(maxNumTokens: 1024, used: 600, input: 100)
    XCTAssertEqual(cap, 1024 - 600 - 100 - ContextBudget.safetyMargin)
    XCTAssertNil(ContextBudget.outputCap(maxNumTokens: 1024, used: 900, input: 50))
  }
}
