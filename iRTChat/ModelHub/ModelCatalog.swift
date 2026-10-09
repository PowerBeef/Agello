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

  var downloadURL: URL {
    // swiftlint:disable:next force_unwrapping
    URL(string: "https://huggingface.co/\(repo)/resolve/main/\(fileName)")!
  }

  var sizeDisplay: String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: sizeBytes)
  }
}

enum ModelCatalog {
  static let e4b = ModelSpec(
    id: .e4b,
    displayName: "Gemma 4 E4B",
    tagline: "Private, on-device. Text, vision, audio and reasoning.",
    repo: "litert-community/gemma-4-E4B-it-litert-lm",
    fileName: "gemma-4-E4B-it.litertlm",
    sizeBytes: 3_659_530_240
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
