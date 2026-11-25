import Foundation

/// Engine & embedder factory for the unshipped iOS Simulator bridge target (`AgelloSim`).
/// Routes LLM inference and EmbeddingGemma 2 ANE embeddings over loopback (`127.0.0.1`)
/// to `agello serve` running on the host Mac's real Metal 4 GPU and Neural Engine.
enum EngineFactory {
  static func makeLiveEngine() -> any ChatEngineProtocol {
    RemoteChatEngine()
  }

  static func aneBundleURL() -> URL? { nil }

  @MainActor
  static func hasLocalEmbedder(store: ModelStore) -> Bool { true }

  static func usesGPUEmbedderWithoutInstance() -> Bool { false }

  @MainActor
  static func makeLocalEmbedder(store: ModelStore) -> (any TextEmbedder)? {
    RemoteEmbedder()
  }
}
