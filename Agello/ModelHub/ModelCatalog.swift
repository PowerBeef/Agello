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

  var downloadURL: URL {
    // swiftlint:disable:next force_unwrapping
    URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(fileName)")!
  }

  var sizeDisplay: String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: sizeBytes)
  }
}

enum ModelCatalog {
  /// Agello v2 Gemma 4 E4B artifact: 1,536-slot local KV rings, 128K global
  /// window with shared unshifted Dual-GATHER float16-exact rotary tables
  /// (<0.001 rad across 0..131,071; fixes LiteRT-LM #3913), and `verify_8`
  /// speculative signature. Same weights; reproducible from the patched base
  /// with `tools/model-surgery/build_v2.sh` (sha256
  /// 7d63a4d8efee11108933c28e9f9a0a17804998379b5fd58ae03031130dac7e7b).
  static let e4b = ModelSpec(
    id: .e4b,
    displayName: "Gemma 4 E4B",
    tagline: "Private, on-device. Text, vision, audio and reasoning.",
    repo: "PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope",
    fileName: "gemma-4-E4B-it-agello-v2.litertlm",
    sizeBytes: 3_686_465_536,
    revision: "9935a8114c3a10920bbd5e85be92087727246254",
    sha256: "7d63a4d8efee11108933c28e9f9a0a17804998379b5fd58ae03031130dac7e7b",
    engineCacheBytes: 2_500_000_000
  )

  /// EmbeddingGemma 2 (text, 270M): turns text into vectors for search by
  /// meaning in files and memory.
  static let embeddingGemma = ModelSpec(
    id: .embeddingGemma,
    displayName: "EmbeddingGemma",
    tagline: "Finds the right passages in your files and memories.",
    repo: "litert-community/embeddinggemma-2-text-270m-litert-lm",
    fileName: "embeddinggemma-2-text-270m.litertlm",
    sizeBytes: 164_626_432,
    revision: "9be6e8b90982095dc05c2bd162e4b954ee4dbac7",
    sha256: "2d079ee2f6f066b1f368e8d7c819f55214eaef1d0513b312321901f30ab286fb",
    engineCacheBytes: 100_000_000
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
