import LiteRTLM
import XCTest

@testable import Agello

/// Probe 15's tool: it always fails, like a call with arguments that don't
/// decode or a tool name the model invented.
struct FailingLookupTool: Tool {
  static let name = "lookup_order_status"
  static let description = "Look up the shipping status of an order by its number."

  @ToolParam(description: "The order number, e.g. '4417'.")
  var orderNumber: String = ""

  nonisolated(unsafe) static var calls = 0

  struct Offline: Error, LocalizedError {
    var errorDescription: String? { "The order service is offline." }
  }

  func run() async throws -> Any {
    Self.calls += 1
    throw Offline()
  }
}

extension ProbeScenarioTests {
  /// Probe 15: a failing tool call doesn't end the reply. The wrapper
  /// vendored from PowerBeef/agello-litert-lm (agello) answers it with an error the
  /// model reads; LiteRT-LM v0.18.0 threw toolExecutionError and the reply
  /// ended there.
  func test15_FailingToolCallKeepsTheReply() async throws {
    _ = try await harness.ensureDownloaded(ModelCatalog.e4b)
    await appState.engine.unload()
    let url = try XCTUnwrap(appState.store.localURL(for: ModelCatalog.e4b))
    let engine = Engine(
      engineConfig: try EngineConfig(
        modelPath: url.path, backend: .gpu, maxNumTokens: 8_192,
        cacheDir: try EngineCache.directory(maxNumTokens: 8_192)))
    try await engine.initialize()
    let config = ConversationConfig(
      systemMessage: LiteRTLM.Message(InferenceOptions().systemPrompt), tools: [FailingLookupTool()])
    let conversation = try await engine.createConversation(with: config)
    FailingLookupTool.calls = 0

    var reply = ""
    var thrown = ""
    do {
      reply = try await conversation.sendMessage(
        LiteRTLM.Message("Use the lookup_order_status tool to check order 4417, then tell me what you found."),
        maxOutputTokens: 200
      ).toString
    } catch {
      thrown = String(describing: error)
    }
    harness.record(
      "probe15_failing_tool",
      ["calls": FailingLookupTool.calls, "reply": reply, "thrown": thrown], in: self)
    XCTAssertGreaterThan(FailingLookupTool.calls, 0, "The model never called the tool")
    XCTAssertEqual(thrown, "", "The failed tool call ended the reply")
    XCTAssertFalse(reply.isEmpty, "No reply after the failed tool call")
  }
}
