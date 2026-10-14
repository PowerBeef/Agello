import LiteRTLM
import XCTest

@testable import Agello

extension ProbeScenarioTests {
  /// Probe 14: what grows the GPU weight cache. From an empty cache, load
  /// E4B on the GPU one engine configuration at a time and record the cache
  /// files' sizes and the load time after each.
  func test14_WeightCacheGrowth() async throws {
    _ = try await harness.ensureDownloaded(ModelCatalog.e4b)
    await appState.engine.unload()
    let url = try XCTUnwrap(appState.store.localURL(for: ModelCatalog.e4b))
    let dir = try LiteRTChatEngine.cacheDirectory()
    let files = FileManager.default
    func cacheFiles() -> [String: Int64] {
      var sizes: [String: Int64] = [:]
      for name in (try? files.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix("gemma-4-E4B") {
        let attributes = try? files.attributesOfItem(atPath: (dir as NSString).appendingPathComponent(name))
        let short = name.replacingOccurrences(
          of: #"^gemma-4-E4B-it-fp16-rope\.litertlm_\d+_\d+"#, with: "", options: .regularExpression)
        sizes[short] = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
      }
      return sizes
    }
    // Start from an empty E4B cache.
    for name in (try? files.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix("gemma-4-E4B") {
      try files.removeItem(atPath: (dir as NSString).appendingPathComponent(name))
    }

    struct Step {
      var label: String
      var tokens: Int
      var mtp = true
      var vision = true
    }
    let steps = [
      Step(label: "8K", tokens: 8_192),
      Step(label: "8K again", tokens: 8_192),
      Step(label: "4K", tokens: 4_096),
      Step(label: "4K again", tokens: 4_096),
      Step(label: "8K after 4K", tokens: 8_192),
      Step(label: "8K without MTP", tokens: 8_192, mtp: false),
      Step(label: "8K without vision", tokens: 8_192, vision: false),
      Step(label: "16K", tokens: 16_384),
    ]
    var rows: [[String: Any]] = []
    for step in steps {
      ExperimentalFlags.enableSpeculativeDecoding = step.mtp
      let started = Date()
      let engine = Engine(
        engineConfig: try EngineConfig(
          modelPath: url.path, backend: .gpu, visionBackend: step.vision ? .cpu() : nil,
          maxNumTokens: step.tokens, cacheDir: dir))
      try await engine.initialize()
      let loadSeconds = Date().timeIntervalSince(started)
      let conversation = try await engine.createConversation(with: ConversationConfig())
      _ = try await conversation.sendMessage(LiteRTLM.Message("Say 'ok'."), maxOutputTokens: 4)
      let sizes = cacheFiles()
      let row: [String: Any] = [
        "step": step.label, "loadSeconds": (loadSeconds * 10).rounded() / 10,
        "weightCacheGB": Double(sizes["_mldrift_weight_cache.bin"] ?? 0) / 1e9,
        "programCacheMB": Double(sizes["_mldrift_program_cache.bin"] ?? 0) / 1e6,
        "drafterWeightCacheMB": Double(sizes[".mtp_drafter_mldrift_weight_cache.bin"] ?? 0) / 1e6,
        "allFilesGB": Double(sizes.values.reduce(0, +)) / 1e9,
      ]
      rows.append(row)
      print("PROBE14 \(row)")
      harness.record("probe14_weight_cache", ["rows": rows, "files": sizes], in: self)
    }
    ExperimentalFlags.enableSpeculativeDecoding = true
  }
}
