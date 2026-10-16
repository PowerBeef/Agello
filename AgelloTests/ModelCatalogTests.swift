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
      "https://huggingface.co/PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope/resolve/\(spec.revision)/gemma-4-E4B-it-fp16-rope.litertlm"
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
      "2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb")
  }

  func testOriginalE4BFileIsRetired() {
    // The unpatched file isn't in the catalog, so ModelStore deletes it.
    XCTAssertFalse(ModelCatalog.all.map(\.fileName).contains("gemma-4-E4B-it.litertlm"))
  }

  func testVerifiedSize() {
    // Byte counts verified against the Hugging Face content-length header.
    XCTAssertEqual(ModelCatalog.e4b.sizeBytes, 3_660_726_272)
    XCTAssertEqual(ModelCatalog.embeddingGemma.sizeBytes, 164_626_432)
    XCTAssertEqual(
      ModelCatalog.embeddingGemma.downloadURL.absoluteString,
      "https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm/resolve/9be6e8b90982095dc05c2bd162e4b954ee4dbac7/embeddinggemma-2-text-270m.litertlm"
    )
  }
}
