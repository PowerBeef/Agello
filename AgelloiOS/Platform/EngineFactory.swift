import Foundation

/// Live engine & embedder factory for hardware iOS builds (`Agello`).
/// Replaced by `AgelloSim/Platform/EngineFactory.swift` in the Simulator bridge target.
enum EngineFactory {
  static func makeLiveEngine() -> any ChatEngineProtocol {
    LiteRTChatEngine()
  }

  static func aneBundleURL() -> URL? {
    guard let dir = try? ModelStore.modelsDirectory() else { return nil }
    let url = dir.appendingPathComponent(CoreAIEmbedder.bundleDirectoryName, isDirectory: true)
    return CoreAIEmbedder.isAvailable(at: url) ? url : nil
  }

  @MainActor
  static func hasLocalEmbedder(store: ModelStore) -> Bool {
    aneBundleURL() != nil || store.isDownloaded(ModelCatalog.embeddingGemma)
  }

  static func usesGPUEmbedderWithoutInstance() -> Bool {
    guard aneBundleURL() == nil else { return false }
    return ModelCatalog.embeddingGemma.extractedDirectoryName == nil
  }

  @MainActor
  static func makeLocalEmbedder(store: ModelStore) -> (any TextEmbedder)? {
    if let aneURL = aneBundleURL() {
      return CoreAIEmbedder(bundleURL: aneURL)
    }
    let spec = ModelCatalog.embeddingGemma
    if spec.extractedDirectoryName == nil, store.isDownloaded(spec),
      let url = store.localURL(for: spec)
    {
      return LiteRTEmbedder(modelURL: url)
    }
    store.ensureDownloaded(spec)
    return nil
  }
}
