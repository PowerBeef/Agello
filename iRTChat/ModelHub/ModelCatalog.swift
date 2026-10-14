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
  /// activations (LiteRT-LM #3913). Same weights; reproducible from the
  /// original (sha256 4a691f036fb06f7d4761da0026ad69a8b16cd7d9bc3965de9c2765edec7cb15f).
  static let e4b = ModelSpec(
    id: .e4b,
    displayName: "Gemma 4 E4B",
    tagline: "Private, on-device. Text, vision, audio and reasoning.",
    repo: "PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope",
    fileName: "gemma-4-E4B-it-fp16-rope.litertlm",
    sizeBytes: 3_659_988_992,
    revision: "13d5aa4cc27f986fe469267da96f177408d98b69"
  )

  /// EmbeddingGemma 2 (text, 270M): turns text into vectors for search by
  /// meaning in files and memory.
  static let embeddingGemma = ModelSpec(
    id: .embeddingGemma,
    displayName: "EmbeddingGemma",
    tagline: "Finds the right passages in your files and memories.",
    repo: "litert-community/embeddinggemma-2-text-270m-litert-lm",
    fileName: "embeddinggemma-2-text-270m.litertlm",
    sizeBytes: 164_626_432
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
