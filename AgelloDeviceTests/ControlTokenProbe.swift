import LiteRTLM
import XCTest

@testable import Agello

extension ProbeScenarioTests {
  /// Probe 19: Gemma 4's tokenizer reads chat markers written in plain text as control tokens, and
  /// a zero-width joiner (``PromptText``) stops it. Each marker should be one token as written and
  /// several ordinary ones once neutralized, none of them the marker's.
  ///
  /// Mac, Google's v0.18.0 (2026-10-16): every template marker is one control token as text
  /// (`<|turn>` 105, `<turn|>` 106, `<|tool_response>` 50, `<|"|>` 52…) and five to seven
  /// ordinary tokens neutralized; `<bos>`, `<eos>`, `<pad>`, `<start_of_turn>` are ordinary text.
  func test19_ControlTokensInTextAreNeutralized() async throws {
    _ = try await harness.ensureDownloaded(ModelCatalog.e4b)
    await appState.engine.unload()
    let url = try XCTUnwrap(appState.store.localURL(for: ModelCatalog.e4b))
    let engine = Engine(
      engineConfig: try EngineConfig(
        modelPath: url.path, backend: .gpu, maxNumTokens: 8_192,
        cacheDir: try EngineCache.directory(maxNumTokens: 8_192)))
    try await engine.initialize()
    let markers = PromptText.controlTokens + ["<bos>", "<eos>", "<pad>", "<start_of_turn>", "<end_of_turn>"]
    var rows: [[String: Any]] = []
    var problems: [String] = []
    for marker in markers {
      let raw = try await engine.tokenize(marker)
      let safe = try await engine.tokenize(PromptText.neutralized(marker))
      rows.append(["marker": marker, "raw": raw, "neutralized": safe])
      // A marker the tokenizer reads as one control token must not survive neutralizing.
      if raw.count == 1, safe.contains(raw[0]) {
        problems.append("\(marker): still \(raw[0]) after neutralizing (\(safe))")
      }
      if raw.count == 1, !PromptText.neutralized(marker).unicodeScalars.contains(PromptText.joiner) {
        problems.append("\(marker): one token \(raw[0]) as text, and PromptText leaves it alone")
      }
    }
    harness.record("probe19_control_tokens", ["rows": rows, "problems": problems], in: self)
    XCTAssertEqual(problems, [])
  }
}
