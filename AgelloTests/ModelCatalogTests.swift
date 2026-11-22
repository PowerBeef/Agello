import XCTest

@testable import Agello

final class ModelCatalogTests: XCTestCase {
  func testE4BIsTheOnlyChatModel() {
    XCTAssertEqual(ModelCatalog.all.map(\.id), [.e4b, .embeddingGemma])
    // A chat never runs on the embedding model.
    XCTAssertEqual(ModelID(storedValue: "embeddinggemma-2-text-270m"), .e4b)
    XCTAssertEqual(ModelCatalog.default.id, .e4b)
    XCTAssertEqual(ModelCatalog.spec(for: .e4b).id, .e4b)
  }

  func testRetiredModelIdentifiersContinueOnE4B() {
    XCTAssertEqual(ModelID(storedValue: "e2b"), .e4b)
    XCTAssertEqual(ModelID(storedValue: "e4b"), .e4b)
    XCTAssertEqual(ModelID(storedValue: "something-else"), .e4b)
  }

  func testDownloadURLIsPinnedToACommit() {
    let spec = ModelCatalog.e4b
    // A commit hash, not a branch: the exact patched file (LiteRT-LM #3913).
    XCTAssertNotNil(
      spec.revision.wholeMatch(of: /[0-9a-f]{40}/), "Pin the chat model to a commit: \(spec.revision)")
    XCTAssertEqual(spec.downloadURL.scheme, "https")
    XCTAssertEqual(spec.downloadURL.host, "huggingface.co")
    XCTAssertEqual(
      spec.downloadURL.absoluteString,
      "https://huggingface.co/PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope/resolve/\(spec.revision)/gemma-4-E4B-it-agello-v2.litertlm"
    )
  }

  /// Every download is pinned to a commit and checked against its SHA-256 (Hugging Face's
  /// LFS id), so a changed upstream file can't replace what was tested.
  func testEveryModelIsPinnedAndChecksummed() {
    for spec in ModelCatalog.all {
      XCTAssertNotNil(spec.revision.wholeMatch(of: /[0-9a-f]{40}/), "\(spec.id): \(spec.revision)")
      XCTAssertNotNil(spec.sha256?.wholeMatch(of: /[0-9a-f]{64}/), "\(spec.id): no SHA-256")
      XCTAssertGreaterThan(spec.engineCacheBytes, 0, "\(spec.id)")
    }
    XCTAssertEqual(
      ModelCatalog.embeddingGemma.sha256,
      "122c2d86657c20aa567fb778801a46e3aec786eec7bbabff618f1c4a531b2ece")
    XCTAssertEqual(
      ModelCatalog.embeddingGemma.extractedDirectoryName, CoreAIEmbedder.bundleDirectoryName)
  }

  func testOriginalE4BFileIsRetired() {
    // Retired files aren't in the catalog, so ModelStore deletes them.
    XCTAssertFalse(ModelCatalog.all.map(\.fileName).contains("gemma-4-E4B-it.litertlm"))
    XCTAssertFalse(ModelCatalog.all.map(\.fileName).contains("embeddinggemma-2-text-270m.litertlm"))
  }

  func testVerifiedSize() {
    // Byte counts verified against the Hugging Face content-length header.
    XCTAssertEqual(ModelCatalog.e4b.sizeBytes, 3_686_465_536)
    XCTAssertEqual(
      ModelCatalog.e4b.sha256,
      "7d63a4d8efee11108933c28e9f9a0a17804998379b5fd58ae03031130dac7e7b")
    XCTAssertEqual(ModelCatalog.embeddingGemma.sizeBytes, 128_245_086)
    XCTAssertEqual(
      ModelCatalog.embeddingGemma.downloadURL.absoluteString,
      "https://huggingface.co/PowerBeef02/embeddinggemma-2-text-270m-coreai-ane/resolve/964dc1c0d594cb3bdbe9efef8429df88712ef94b/embeddinggemma-2-text-270m-ane.aar"
    )
  }
}
