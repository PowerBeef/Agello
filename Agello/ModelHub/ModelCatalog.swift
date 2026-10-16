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
  /// and programs, per context size on Google's binary).
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
  /// litert-community's Gemma 4 E4B build with float16-exact rotary positions:
  /// the original corrupts digits past 2,048 context tokens with 16-bit GPU
  /// activations (LiteRT-LM #3913). Positions split in 512-token blocks, exact
  /// on M1-class GPUs too. Same weights; reproducible from the original with
  /// the fork's `patch_rope.py --split --block 512` (sha256
  /// 6353a23321e46624e0fa1b038d23370e8e0af84032d24d30ef53be3b116f655c).
  static let e4b = ModelSpec(
    id: .e4b,
    displayName: "Gemma 4 E4B",
    tagline: "Private, on-device. Text, vision, audio and reasoning.",
    repo: "PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope",
    fileName: "gemma-4-E4B-it-fp16-rope.litertlm",
    sizeBytes: 3_660_726_272,
    revision: "a1693e22a3439b0d36570cc7844d7b572336a85d",
    sha256: "6353a23321e46624e0fa1b038d23370e8e0af84032d24d30ef53be3b116f655c",
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
