import Foundation

/// Downloadable Gemma 4 model in `.litertlm` format.
struct ModelSpec: Identifiable, Sendable, Equatable {
  let id: ModelID
  let displayName: String
  let tagline: String
  let repo: String
  let fileName: String
  /// Expected download size in bytes (verified against Hugging Face).
  let sizeBytes: Int64
  /// Hugging Face commit (or branch) to download: a commit pins the exact file.
  var revision = "main"
  /// SHA-256 of the file (Hugging Face's LFS id), checked before the file is used.
  var sha256: String?
  /// Disk the engine cache takes beside the file once the model loads (GPU-format weights
  /// and programs, one copy for every context size).
  var engineCacheBytes: Int64 = 0
  /// When set, `fileName` is an Apple Archive (`.aar`) verified by exact size and SHA-256,
  /// then atomically extracted into this directory inside `Models/`.
  var extractedDirectoryName: String?

  var downloadURL: URL {
    // swiftlint:disable:next force_unwrapping
    URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(fileName)")!
  }

  private static let byteCountStyle = ByteCountFormatStyle(style: .file)

  static func formatByteCount(_ bytes: Int64) -> String {
    byteCountStyle.format(bytes)
  }

  var sizeDisplay: String {
    Self.formatByteCount(sizeBytes)
  }
}

enum ModelCatalog {
  /// Agello v2 Gemma 4 E4B artifact: 1,536-slot local KV rings, 128K global
  /// window with shared unshifted Dual-GATHER float16-exact rotary tables
  /// (<0.001 rad across 0..131,071; fixes LiteRT-LM #3913), and `verify_8`
  /// speculative signature. Same weights; reproducible from the patched base
  /// with `tools/model-surgery/build_v2.sh` at `LiteRT-LM@3af6200d` (sha256
  /// d6e644ce5c468fc0694c9587f78f722548bbe7f4fc12353f4937f573670ee3bc).
  static let e4b = ModelSpec(
    id: .e4b,
    displayName: "Gemma 4 E4B",
    tagline: "Private, on-device. Text, vision, audio and reasoning.",
    repo: "PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope",
    fileName: "gemma-4-E4B-it-agello-v2.litertlm",
    sizeBytes: 3_685_449_728,
    revision: "c2758a36c0931fc96cd628a38492ffc759c06942",
    sha256: "d6e644ce5c468fc0694c9587f78f722548bbe7f4fc12353f4937f573670ee3bc",
    engineCacheBytes: 2_500_000_000
  )

  /// EmbeddingGemma 2 (text, 270M, 768-dim) for Apple Neural Engine via Core AI
  /// (`embeddinggemma-2-text-270m-ane.aar` -> 4-bucket asymmetric INT4 `.aimodel`,
  /// `mmap` INT4 token table, and SentencePiece model). Runs on ANE with zero
  /// Metal GPU contention alongside Gemma 4 E4B.
  static let embeddingGemma = ModelSpec(
    id: .embeddingGemma,
    displayName: "EmbeddingGemma",
    tagline: "Finds the right passages in your files and memories.",
    repo: "PowerBeef02/embeddinggemma-2-text-270m-coreai-ane",
    fileName: "embeddinggemma-2-text-270m-ane.aar",
    sizeBytes: 128_245_086,
    revision: "41026d1cbf50d4825e0b2c91f2cc131f7433f071",
    sha256: "122c2d86657c20aa567fb778801a46e3aec786eec7bbabff618f1c4a531b2ece",
    engineCacheBytes: 180_000_000,
    extractedDirectoryName: EmbeddingBundleLayout.directoryName
  )

  static let all: [ModelSpec] = [e4b, embeddingGemma]

  static let `default`: ModelSpec = e4b

  static func spec(for id: ModelID) -> ModelSpec {
    switch id {
    case .e4b: return e4b
    case .embeddingGemma: return embeddingGemma
    }
  }
}
