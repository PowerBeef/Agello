import XCTest

@testable import Agello

/// Probe 35: the last characters of a Think reply after a tool call (2026-11-17). With the chat
/// system prompt D4, `ThinkingScenarioTests/test02`'s chat answered "10" for 400 ÷ 4 and "40"
/// for 391 + 9, the calculator having run each time; with the old prompt this Mac's replies kept
/// them, and the iPhone's lost their final period. Runs that chat with speculative decoding on
/// and off and records every chunk the engine received, to find where the tail goes.
extension ProbeScenarioTests {
  func test35_ThinkReplyTail() async throws {
    try await requireLoadedModel()
    guard let live = harness.liveEngine else { throw XCTSkip("Needs the LiteRT engine") }
    let saved = appState.options
    defer { appState.options = saved }
    let turns = [
      "What is 17 * 23? Think it through, then give the number.",
      "Add 9 to that result. Reply with the number.",
      "Now divide it by 4. Reply with the number.",
    ]
    var rows: [[String: Any]] = []
    for speculative in [true, false] {
      appState.options.enableThinking = true
      appState.options.enableSpeculativeDecoding = speculative
      await appState.applyCurrentOptions()
      let thread = harness.newThread()
      for prompt in turns {
        await live.recordChunks(true)
        let exchange = await harness.ask(prompt, in: thread)
        let chunks = await live.chunkLog ?? []
        await live.recordChunks(false)
        rows.append([
          "speculative": speculative, "prompt": prompt, "reply": exchange.text,
          "thought": String((exchange.reply?.thought ?? "").suffix(200)),
          "tools": exchange.reply?.parts.toolActivity.map { "\($0.name): \($0.summary)" } ?? [],
          "outputTokens": exchange.reply?.stats?.outputTokens ?? -1,
          "lastChunks": Array(chunks.suffix(8)), "chunkCount": chunks.count,
          "error": appState.generationError ?? "",
        ])
        print("probe35 mtp=\(speculative) \(prompt.prefix(24)) -> \(exchange.text.debugDescription)")
      }
    }
    // What the model sees of its own last reply: a bare answer, then a request to quote it, with
    // and without Think and speculative decoding; and the cache's growth over each reply.
    var quotes: [[String: Any]] = []
    let pairs = [
      ("What is 391 + 9? Reply with just the number.", "Quote your previous reply exactly, in double quotes."),
      ("Write the number four hundred in digits, nothing else.", "Quote your previous reply exactly, in double quotes."),
      ("Name the capital of France in one word, with no period.", "Quote your previous reply exactly, in double quotes."),
    ]
    for (thinking, speculative) in [(true, true), (true, false), (false, true), (false, false)] {
      appState.options.enableThinking = thinking
      appState.options.enableSpeculativeDecoding = speculative
      await appState.applyCurrentOptions()
      for (ask, quote) in pairs {
        let thread = harness.newThread()
        let before = await live.cachedTokenCount()
        let first = await harness.ask(ask, in: thread)
        let afterFirst = await live.cachedTokenCount()
        let second = await harness.ask(quote, in: thread)
        quotes.append([
          "thinking": thinking, "speculative": speculative, "ask": ask, "reply": first.text,
          "quoted": second.text, "quotedThought": String((second.reply?.thought ?? "").prefix(300)),
          "tools": first.reply?.parts.toolActivity.map(\.summary) ?? [],
          "replyOutputTokens": first.reply?.stats?.outputTokens ?? -1,
          "cacheBefore": before, "cacheAfterReply": afterFirst,
        ])
        print(
          "probe35 think=\(thinking) mtp=\(speculative) \(ask.prefix(20)) -> \(first.text.debugDescription) quoted \(second.text.debugDescription)")
      }
    }
    harness.record("probe35_thinkReplyTail", ["rows": rows, "quotes": quotes], in: self)
  }
}
