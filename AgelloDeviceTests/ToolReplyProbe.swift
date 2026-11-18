import LiteRTLM
import XCTest

@testable import Agello

/// Probe 36: the reply after a tool call (2026-11-17). With the one-line prompt, probe 34's "What
/// year is it?" called the date tool and then wrote nothing. Asks the date questions under the
/// old line and D4, records the tools that ran and every chunk the engine received.
extension ProbeScenarioTests {
  func test36_ReplyAfterToolCall() async throws {
    try await requireLoadedModel()
    guard let live = harness.liveEngine else { throw XCTSkip("Needs the LiteRT engine") }
    let saved = appState.options
    defer { appState.options = saved }
    let prompts = ["What year is it?", "What's today's date?", "What time is it?", "What day of the week is it?"]
    var rows: [[String: Any]] = []
    for (name, base) in [("legacy", Self.recordedSystemPrompt), ("D4", SystemPrompt.base)] {
      appState.options.systemPrompt = base
      appState.options.enableThinking = false
      await appState.applyCurrentOptions()
      for (index, prompt) in prompts.enumerated() {
        // PROBE36_TRACE=<folder> with AGELLO_TELEMETRY=3: the runtime's trace of each question,
        // every decoded token's id included.
        let traceFolder = ProcessInfo.processInfo.environment["PROBE36_TRACE"]
        if traceFolder != nil { Telemetry.reset() }
        await live.recordChunks(true)
        let exchange = await harness.ask(prompt, in: harness.newThread())
        if let traceFolder {
          _ = Telemetry.writeTrace(to: URL(fileURLWithPath: traceFolder).appendingPathComponent("\(name)-\(index).json"))
        }
        let chunks = await live.chunkLog ?? []
        await live.recordChunks(false)
        rows.append([
          "base": name, "prompt": prompt, "reply": exchange.text,
          "tools": exchange.reply?.parts.toolActivity.map { "\($0.name): \($0.summary)" } ?? [],
          "outputTokens": exchange.reply?.stats?.outputTokens ?? -1, "chunks": Array(chunks.prefix(40)),
          "error": appState.generationError ?? "",
        ])
        print("probe36 \(name) \(prompt) -> \(exchange.text.prefix(80).debugDescription) tools=\(exchange.reply?.parts.toolActivity.count ?? 0)")
      }
    }
    harness.record("probe36_replyAfterToolCall", ["rows": rows], in: self)
  }
}
