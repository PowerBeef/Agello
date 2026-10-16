import LiteRTLM
import XCTest

@testable import Agello

extension ProbeScenarioTests {
  /// Probe 17: the message renderer and the tokenizer LiteRT-LM exports count exactly what a send
  /// prefills, so the app can budget the context window without estimates. On a new conversation
  /// the rendered message carries the system prompt, the tool schemas and the replayed history,
  /// and the runtime adds one token (BOS) the text doesn't show; later it's only the new turn.
  /// Each count is compared with the runtime's own prefill count.
  ///
  /// Mac, Google's v0.18.0 binary (2026-10-16): exact on every turn, plain and Think.
  func test17_RenderedMessagesCountExactly() async throws {
    _ = try await harness.ensureDownloaded(ModelCatalog.e4b)
    await appState.engine.unload()
    ExperimentalFlags.optIntoExperimentalAPIs()
    ExperimentalFlags.enableBenchmark = true
    let url = try XCTUnwrap(appState.store.localURL(for: ModelCatalog.e4b))
    let engine = Engine(
      engineConfig: try EngineConfig(
        modelPath: url.path, backend: .gpu, maxNumTokens: 8_192,
        cacheDir: try EngineCache.directory(maxNumTokens: 8_192)))
    try await engine.initialize()

    let arms: [(name: String, thinking: Bool)] = [("plain", false), ("think", true)]
    let prompts = [
      "Say hello in French, in one word.",
      "Repeat these exactly: 0123456789, 2026-10-16, 3.14159.",
      "日本語で「ありがとう」と言ってください。",
    ]
    var rows: [[String: Any]] = []
    var mismatches: [String] = []
    for arm in arms {
      let config = ConversationConfig(
        systemMessage: LiteRTLM.Message(InferenceOptions().systemPrompt),
        initialMessages: [
          LiteRTLM.Message("My name is Ada and I like lighthouses.", role: .user),
          LiteRTLM.Message("Nice to meet you, Ada! Lighthouses are wonderful.", role: .model),
        ],
        tools: [CurrentDateTimeTool(), CalculatorTool()],
        thinkingConfig: arm.thinking ? ThinkingConfig(enableThinking: true, thinkingTokenBudget: 256) : nil)
      let conversation = try await engine.createConversation(with: config)
      let preface = try await engine.countTokens(conversation.renderPrefaceIntoString())
      for (index, prompt) in prompts.enumerated() {
        let message = LiteRTLM.Message(prompt, role: .user)
        let rendered = try conversation.renderMessageIntoString(message)
        let predicted = try await engine.countTokens(rendered)
        let before = try conversation.getTokenCount()
        let reply = try await conversation.sendMessage(message, maxOutputTokens: 48)
        let info = try conversation.getBenchmarkInfo()
        let after = try conversation.getTokenCount()
        rows.append([
          "arm": arm.name, "turn": index, "predicted": predicted,
          "prefilled": info.lastPrefillTokenCount, "decoded": info.lastDecodeTokenCount,
          "kvBefore": before, "kvAfter": after, "preface": preface,
          "rendered": String(rendered.prefix(400)), "reply": String(reply.toString.prefix(120)),
        ])
        if predicted + (before == 0 ? 1 : 0) != info.lastPrefillTokenCount {
          mismatches.append("\(arm.name) turn \(index): predicted \(predicted), prefilled \(info.lastPrefillTokenCount)")
        }
      }
    }
    harness.record("probe17_exact_counts", ["rows": rows, "mismatches": mismatches], in: self)
    XCTAssertEqual(mismatches, [])
  }
}
