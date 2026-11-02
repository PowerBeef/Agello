import XCTest

@testable import Agello

extension ProbeScenarioTests {
  /// Probe 23: long, complex answers with Think. How much of the reply's output cap reasoning
  /// takes, and whether the answer stops at the cap (`reachedLimit`), with and without the
  /// on-device tools (which split the room, ToolBudget.plan), in new chats and deeper into one.
  func test23_LongAnswersWithThink() async throws {
    try await requireLoadedModel()
    let prompts = [
      "Compare TCP and QUIC in depth: handshakes, head-of-line blocking, congestion control, connection migration and security. Use a heading for each and give a concrete example for each point.",
      "Plan a two-week trip to Japan on a budget: the route, rail passes, lodging, food, a day-by-day itinerary, and a cost table at the end.",
      "Explain how a transformer language model works, from tokenization to sampling, for a programmer who knows no machine learning. Include a small worked example of attention with numbers.",
    ]
    var rows: [[String: Any]] = []
    func reply(_ label: String, _ prompt: String, in thread: ChatThread) async {
      let exchange = await harness.ask(prompt, in: thread)
      let answer = exchange.text
      let thought = exchange.reply?.thought ?? ""
      let stats = exchange.reply?.stats
      let row: [String: Any] = [
        "case": label, "accepted": exchange.accepted, "seconds": exchange.seconds,
        "thinking": appState.resolved?.thinkingBudget ?? 0, "tools": appState.enableTools,
        "window": appState.resolved?.maxNumTokens ?? 0,
        "outputTokens": stats?.outputTokens ?? -1, "reachedLimit": stats?.reachedLimit ?? false,
        "reasoningTokensEst": ContextBudget.estimateTextTokens(thought),
        "answerTokensEst": ContextBudget.estimateTextTokens(answer),
        "answerTail": String(answer.suffix(70)),
        "error": appState.generationError ?? "",
      ]
      rows.append(row)
      print("PROBE23 \(row)")
      harness.record("probe23_long_answers_with_think", ["rows": rows], in: self)
    }
    for (thinking, tools) in [(true, true), (true, false), (false, true)] {
      appState.options.enableThinking = thinking
      appState.enableTools = tools
      await appState.applyCurrentOptions()
      let label = "\(thinking ? "think" : "no-think") \(tools ? "tools" : "no-tools")"
      for prompt in prompts {
        await reply("\(label), new chat", prompt, in: harness.newThread())
      }
    }
    // The default (Think, tools) as a chat goes on: history leaves less room for each reply.
    appState.options.enableThinking = true
    appState.enableTools = true
    await appState.applyCurrentOptions()
    let thread = harness.newThread()
    for (turn, prompt) in prompts.enumerated() {
      await reply("think tools, turn \(turn + 1) of one chat", prompt, in: thread)
    }
  }
}
