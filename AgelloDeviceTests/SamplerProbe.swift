import LiteRTLM
import XCTest

@testable import Agello

extension ProbeScenarioTests {
  /// Probe 18: do Settings' sampler presets reach the model on Google's binary, and does
  /// Regenerate give a new reply? Each arm loads a fresh engine (the random state lives in the
  /// engine, seeded 0) and, like the app, first validates it with a one-token reply on a default
  /// conversation; then three new conversations with the preset's sampler answer a high-entropy
  /// prompt, as Regenerate would. Control arms skip the validation, or give each conversation its
  /// own seed. Records only: the replies per arm and how many differ.
  ///
  /// Mac, Google's v0.18.0 (2026-10-16), "Invent a name for a new color…":
  /// - MTP on: Precise and Creative give the same reply three times (greedy, whatever the preset).
  /// - MTP off: the preset applies, validated or not (Precise "Lumina-Glow", Creative
  ///   "Vantablaze"), but each new conversation (seed 0) repeats the same reply: Regenerate can't
  ///   vary it.
  /// - MTP off with a seed per conversation: three different replies.
  func test18_SamplerPresetsReachTheModel() async throws {
    _ = try await harness.ensureDownloaded(ModelCatalog.e4b)
    await appState.engine.unload()
    ExperimentalFlags.optIntoExperimentalAPIs()
    defer { ExperimentalFlags.enableSpeculativeDecoding = nil }
    let url = try XCTUnwrap(appState.store.localURL(for: ModelCatalog.e4b))
    let prompt = "Invent a name for a new color and describe it in one short sentence."

    struct Arm {
      let preset: SamplerPreset
      let mtp: Bool
      var validated = true
      var seeded = false
      var label: String {
        "\(preset.rawValue) mtp=\(mtp ? "on" : "off")\(validated ? "" : " unvalidated")\(seeded ? " seeds" : "")"
      }
    }
    let arms = [
      Arm(preset: .precise, mtp: true), Arm(preset: .creative, mtp: true),
      Arm(preset: .precise, mtp: false), Arm(preset: .creative, mtp: false),
      Arm(preset: .creative, mtp: false, validated: false),
      Arm(preset: .creative, mtp: true, validated: false),
      Arm(preset: .creative, mtp: false, seeded: true),
    ]
    var rows: [[String: Any]] = []
    for arm in arms {
      ExperimentalFlags.enableSpeculativeDecoding = arm.mtp
      let engine = Engine(
        engineConfig: try EngineConfig(
          modelPath: url.path, backend: .gpu, maxNumTokens: 8_192,
          cacheDir: try EngineCache.directory(maxNumTokens: 8_192)))
      try await engine.initialize()
      if arm.validated {
        let probe = try await engine.createConversation(with: ConversationConfig())
        _ = try await probe.sendMessage(LiteRTLM.Message("Hi"), maxOutputTokens: 1)
      }
      var replies: [String] = []
      for index in 0..<3 {
        let sampler = try SamplerConfig(
          topK: arm.preset.topK, topP: arm.preset.topP, temperature: arm.preset.temperature,
          seed: arm.seeded ? 1_000 + index : 0)
        let conversation = try await engine.createConversation(
          with: ConversationConfig(samplerConfig: sampler, enableSpeculativeDecoding: arm.mtp))
        let reply = try await conversation.sendMessage(LiteRTLM.Message(prompt), maxOutputTokens: 48)
        replies.append(reply.toString.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      rows.append(["arm": arm.label, "distinct": Set(replies).count, "replies": replies])
      print("probe18: \(arm.label): \(Set(replies).count) distinct of 3 — \(replies.first ?? "")")
      harness.record("probe18_sampler", ["prompt": prompt, "rows": rows], in: self)
      XCTAssertFalse(replies.contains(where: \.isEmpty), "\(arm.label): empty reply")
    }
  }
}
