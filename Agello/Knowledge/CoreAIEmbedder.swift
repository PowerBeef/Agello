import CoreAI
import Foundation

/// Memory-mapped INT4 token embedding table (`embed_tokens.bin`, AGET v1 format):
/// 32-byte header, `vocabSize` Float32 per-row scales, then `vocabSize * (dim / 2)` packed
/// signed two's-complement 4-bit weights (low nibble first). Clean file-backed pages keep dirty
/// RAM near zero while lookups run in <0.1 ms on CPU.
struct INT4EmbeddingTable: @unchecked Sendable {
  enum LoadError: Error, LocalizedError {
    case invalidHeader
    case truncatedFile

    var errorDescription: String? {
      switch self {
      case .invalidHeader: return "Invalid INT4 embedding table header."
      case .truncatedFile: return "INT4 embedding table is truncated."
      }
    }
  }

  static let headerBytes = 32
  private let data: Data
  let vocabSize: Int
  let dimension: Int
  let scaleMultiplier: Float
  private let scalesOffset: Int
  private let weightsOffset: Int
  private let packedRowBytes: Int

  init(contentsOf url: URL) throws {
    let mapped = try Data(contentsOf: url, options: .alwaysMapped)
    try self.init(data: mapped)
  }

  init(data: Data) throws {
    guard data.count >= Self.headerBytes else { throw LoadError.invalidHeader }
    var magic: UInt32 = 0
    var version: UInt32 = 0
    var vocab: UInt32 = 0
    var dim: UInt32 = 0
    var mulBits: UInt32 = 0
    data.withUnsafeBytes { raw in
      magic = raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
      version = raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
      vocab = raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian
      dim = raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self).littleEndian
      mulBits = raw.loadUnaligned(fromByteOffset: 16, as: UInt32.self).littleEndian
    }
    // "AGET" little-endian: 0x54454741
    guard magic == 0x5445_4741, version == 1, vocab > 0, dim > 0, dim.isMultiple(of: 2) else {
      throw LoadError.invalidHeader
    }
    let vocabSize = Int(vocab)
    let dimension = Int(dim)
    let packedRowBytes = dimension / 2
    let scalesOffset = Self.headerBytes
    let weightsOffset = scalesOffset + vocabSize * MemoryLayout<Float>.size
    let requiredBytes = weightsOffset + vocabSize * packedRowBytes
    guard data.count >= requiredBytes else { throw LoadError.truncatedFile }

    self.data = data
    self.vocabSize = vocabSize
    self.dimension = dimension
    self.scaleMultiplier = Float(bitPattern: mulBits)
    self.scalesOffset = scalesOffset
    self.weightsOffset = weightsOffset
    self.packedRowBytes = packedRowBytes
  }

  /// Dequantizes `tokenIDs` (padded with `padID = 0` up to `bucketLength`) into a contiguous
  /// `[1, bucketLength, dimension]` Float16 buffer.
  func fillFloat16(
    tokenIDs: [Int32],
    bucketLength: Int,
    into destination: UnsafeMutablePointer<Float16>
  ) {
    let count = min(tokenIDs.count, bucketLength)
    data.withUnsafeBytes { raw in
      let base = raw.baseAddress!  // swiftlint:disable:this force_unwrapping
      let scalesBase = base.advanced(by: scalesOffset)
      let weightsBase = base.advanced(by: weightsOffset)
      for position in 0..<bucketLength {
        let rawID = position < count ? Int(tokenIDs[position]) : 0
        let id = (rawID >= 0 && rawID < vocabSize) ? rawID : 0
        let rowScale =
          scalesBase.loadUnaligned(
            fromByteOffset: id * MemoryLayout<Float>.size, as: Float.self) * scaleMultiplier
        let packedRow = weightsBase.advanced(by: id * packedRowBytes)
          .assumingMemoryBound(to: UInt8.self)
        let outRow = destination.advanced(by: position * dimension)
        for byteIndex in 0..<packedRowBytes {
          let byte = packedRow[byteIndex]
          let lo = Int(byte & 0x0F)
          let hi = Int(byte >> 4)
          let sLo = Float(lo >= 8 ? lo - 16 : lo)
          let sHi = Float(hi >= 8 ? hi - 16 : hi)
          outRow[byteIndex * 2] = Float16(sLo * rowScale)
          outRow[byteIndex * 2 + 1] = Float16(sHi * rowScale)
        }
      }
    }
  }
}

/// EmbeddingGemma 2 (text, 270M, 768-dim) running exclusively on the Apple Neural Engine via
/// iOS 27 / macOS 27 Core AI (`text_encoder.aimodel`, 4-bucket asymmetric INT4). Leaves the
/// Metal GPU completely uncontended so indexing, search, memory ranking, and web reranking run
/// concurrently with Gemma 4 E4B generation.
actor CoreAIEmbedder: TextEmbedder {
  static let bundleDirectoryName = EmbeddingBundleLayout.directoryName
  static let buckets = [128, 256, 512, 1024]

  nonisolated let dimensions = EmbeddingGemmaPrompts.outputSize
  /// Shares the exact vector space (cosine parity >= 0.999 vs FP32 / >= 0.995 vs LiteRT GPU)
  /// so already-indexed SwiftData passages and chats stay valid without re-indexing.
  nonisolated let identifier = EmbeddingGemmaPrompts.identifier
  nonisolated let relatedThreshold: Float = 0.60
  nonisolated let relatedMargin: Float = 0.07
  nonisolated let usesGPU = false

  enum EmbedderError: Error, LocalizedError {
    case missingFunction(String)
    case missingOutput

    var errorDescription: String? {
      switch self {
      case .missingFunction(let name): return "Core AI embedder function '\(name)' not found."
      case .missingOutput: return "Core AI embedder produced no encodings output."
      }
    }
  }

  private struct LoadedResources {
    let model: AIModel
    let tokenizer: SentencePieceTokenizer
    let table: INT4EmbeddingTable
    var functions: [Int: InferenceFunction] = [:]
  }

  private let bundleURL: URL
  private var resources: LoadedResources?
  private var loading: Task<LoadedResources, Error>?
  private var generation = 0

  init(bundleURL: URL) {
    self.bundleURL = bundleURL
  }

  /// Returns `true` when `directory` contains a complete ANE EmbeddingGemma 2 bundle.
  static func isAvailable(at directory: URL) -> Bool {
    EmbeddingBundleLayout.isAvailable(at: directory)
  }

  /// Smallest static ANE bucket >= `tokenCount` (capped at the largest bucket).
  static func bucket(for tokenCount: Int) -> Int {
    buckets.first { tokenCount <= $0 } ?? buckets[buckets.count - 1]
  }

  func embed(documents: [(title: String, text: String)]) async throws -> [[Float]] {
    var vectors: [[Float]] = []
    vectors.reserveCapacity(documents.count)
    for document in documents {
      try Task.checkCancellation()
      let prompt = EmbeddingGemmaPrompts.documentPrompt(title: document.title, text: document.text)
      vectors.append(try await encode(prompt: prompt))
      await Task.yield()
    }
    return vectors
  }

  func embed(query: String) async throws -> [Float] {
    try await embed(query: query, task: .search)
  }

  func embed(query: String, task: EmbeddingQueryTask) async throws -> [Float] {
    try await encode(prompt: EmbeddingGemmaPrompts.queryPrompt(query, task: task))
  }

  func unload() async {
    generation += 1
    loading?.cancel()
    loading = nil
    resources = nil
  }

  // MARK: - Inference

  private func encode(prompt: String) async throws -> [Float] {
    do {
      let loaded = try await loadedResources(bypassCache: false)
      return try await runEncode(prompt: prompt, resources: loaded)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // iOS 27's AIModelCache.default can return a stale AIModel handle whose compiled
      // MPSGraphNDX ANE binary was purged or invalidated (throwing _GenericObjCError.nilError on
      // loadFunction/run). Evict the app's Core AI cache and re-specialize once cleanly.
      Log.engine.warning(
        "embedder: Core AI ANE call failed (\(error.localizedDescription, privacy: .public)); evicting cache and re-specializing"
      )
      evictCacheAndReset()
      let fresh = try await loadedResources(bypassCache: true)
      return try await runEncode(prompt: prompt, resources: fresh)
    }
  }

  private func runEncode(prompt: String, resources loaded: LoadedResources) async throws -> [Float] {
    let maxLen = Self.buckets[Self.buckets.count - 1]
    let tokens = loaded.tokenizer.encodeWithSpecialTokens(prompt, maxLength: maxLen)
    let bucket = Self.bucket(for: tokens.count)
    let function = try functionForBucket(bucket, fallbackModel: loaded.model)

    var embeddings = NDArray(shape: [1, bucket, loaded.table.dimension], scalarType: .float16)
    embeddings.mutableView(as: Float16.self).withUnsafeMutablePointer { ptr, _, _ in
      loaded.table.fillFloat16(tokenIDs: tokens, bucketLength: bucket, into: ptr)
    }

    var mask = NDArray(shape: [1, bucket], scalarType: .float16)
    let validCount = min(tokens.count, bucket)
    mask.mutableView(as: Float16.self).withUnsafeMutablePointer { ptr, _, _ in
      for i in 0..<bucket {
        ptr[i] = i < validCount ? Float16(1) : Float16(0)
      }
    }

    var outputs = try await function.run(inputs: [
      "embeddings": embeddings,
      "input_mask": mask,
    ])
    guard let array = outputs.remove("encodings")?.ndArray else {
      throw EmbedderError.missingOutput
    }
    let vector: [Float] = array.view(as: Float16.self).withUnsafePointer { ptr, _, _ in
      (0..<dimensions).map { Float(ptr[$0]) }
    }
    return VectorIndex.normalized(vector)
  }

  private func functionForBucket(
    _ bucket: Int, fallbackModel: AIModel
  ) throws -> InferenceFunction {
    if let cached = resources?.functions[bucket] { return cached }
    let model = resources?.model ?? fallbackModel
    let name = "encoder_\(bucket)"
    guard let fn = try model.loadFunction(named: name) else {
      throw EmbedderError.missingFunction(name)
    }
    resources?.functions[bucket] = fn
    return fn
  }

  private func evictCacheAndReset() {
    generation += 1
    loading?.cancel()
    loading = nil
    resources = nil
    let modelURL = bundleURL.appendingPathComponent("text_encoder.aimodel", isDirectory: true)
    let options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
    try? AIModelCache.default.deleteEntry(for: modelURL, options: options)
    try? AIModelCache.default.deleteEntries(for: modelURL)
    try? AIModelCache.default.deleteAll()
  }

  private func loadedResources(bypassCache: Bool) async throws -> LoadedResources {
    if !bypassCache, let resources { return resources }
    let started = generation
    if !bypassCache, let loading {
      let shared = try await loading.value
      guard generation == started else { throw CancellationError() }
      return shared
    }
    let url = bundleURL
    let task = Task { try await Self.load(bundleURL: url, bypassCache: bypassCache) }
    loading = task
    defer { if loading == task { loading = nil } }
    let loaded = try await task.value
    guard generation == started else { throw CancellationError() }
    resources = loaded
    return loaded
  }

  private static func load(bundleURL: URL, bypassCache: Bool) async throws -> LoadedResources {
    let started = ContinuousClock.now
    let modelURL = bundleURL.appendingPathComponent("text_encoder.aimodel", isDirectory: true)
    let tableURL = bundleURL.appendingPathComponent("embed_tokens.bin")
    let tokenizerURL = bundleURL.appendingPathComponent("tokenizer.model")

    async let tokenizerTask = Task.detached(priority: .userInitiated) {
      try SentencePieceTokenizer(contentsOf: tokenizerURL)
    }.value
    async let tableTask = Task.detached(priority: .userInitiated) {
      try INT4EmbeddingTable(contentsOf: tableURL)
    }.value

    let options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
    let model: AIModel
    if !bypassCache, let cached = try? AIModelCache.default.model(for: modelURL, options: options) {
      model = cached
    } else {
      model = try await AIModel(contentsOf: modelURL, options: options)
    }

    let tokenizer = try await tokenizerTask
    let table = try await tableTask
    Log.engine.info(
      "embedder: loaded Core AI ANE bundle in \(String(describing: ContinuousClock.now - started), privacy: .public)"
    )
    return LoadedResources(model: model, tokenizer: tokenizer, table: table)
  }
}
