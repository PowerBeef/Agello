import LiteRTLM
import XCTest

@testable import Agello

extension ProbeScenarioTests {
  /// Probe 14: the GPU weight cache stays bounded. LiteRT-LM keeps a full
  /// copy of the GPU weights (2.2 GB for E4B) for every context size in one
  /// file: measured from an empty cache, 8K 2.20 GB (7.5 s load), 8K again
  /// 2.20 GB (0.8 s), 4K 4.40 GB, 16K 6.60 GB; MTP and vision added nothing.
  /// `EngineCache` gives each context size its own folder and keeps the
  /// `keptContextSizes` most recently used, so loading 8K, 4K, 16K, 8K leaves
  /// two folders, each with one copy.
  func test14_WeightCacheGrowth() async throws {
    _ = try await harness.ensureDownloaded(ModelCatalog.e4b)
    await appState.engine.unload()
    let url = try XCTUnwrap(appState.store.localURL(for: ModelCatalog.e4b))
    let files = FileManager.default
    let root = URL(fileURLWithPath: try EngineCache.directory(maxNumTokens: 8_192))
      .deletingLastPathComponent()
    func folders() -> [String: Int64] {
      var sizes: [String: Int64] = [:]
      for name in (try? files.contentsOfDirectory(atPath: root.path)) ?? [] {
        let folder = root.appendingPathComponent(name)
        let contents = (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
        sizes[name] = contents.reduce(Int64(0)) { total, file in
          let attributes = try? files.attributesOfItem(atPath: folder.appendingPathComponent(file).path)
          return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
      }
      return sizes
    }
    // Start from empty context-size caches.
    for name in (try? files.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix("kv-") {
      try files.removeItem(at: root.appendingPathComponent(name))
    }

    var rows: [[String: Any]] = []
    let singleCopyBytes: Int64 = 3_000_000_000  // one E4B copy is ~2.6 GB
    for tokens in [8_192, 4_096, 16_384, 8_192] {
      let started = Date()
      let engine = Engine(
        engineConfig: try EngineConfig(
          modelPath: url.path, backend: .gpu, visionBackend: .cpu(), maxNumTokens: tokens,
          cacheDir: try EngineCache.directory(maxNumTokens: tokens)))
      try await engine.initialize()
      let loadSeconds = Date().timeIntervalSince(started)
      let conversation = try await engine.createConversation(with: ConversationConfig())
      _ = try await conversation.sendMessage(LiteRTLM.Message("Say 'ok'."), maxOutputTokens: 4)
      let sizes = folders()
      let sizeFolders = sizes.filter { $0.key.hasPrefix("kv-") }
      let row: [String: Any] = [
        "tokens": tokens, "loadSeconds": (loadSeconds * 10).rounded() / 10,
        "folders": sizes.mapValues { Double($0) / 1e9 },
      ]
      rows.append(row)
      print("PROBE14 \(row)")
      harness.record("probe14_weight_cache", ["rows": rows], in: self)
      XCTAssertLessThanOrEqual(sizeFolders.count, EngineCache.keptContextSizes, "\(sizes)")
      XCTAssertNotNil(sizeFolders[EngineCache.folder(maxNumTokens: tokens)], "\(sizes)")
      for (name, bytes) in sizeFolders {
        XCTAssertLessThan(bytes, singleCopyBytes, "\(name) holds more than one weight copy")
      }
    }
  }
}
