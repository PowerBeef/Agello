import CoreAI
import Darwin
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
  /// Precomputed dequantized row for pad token ID `0` so bucket padding copies via `memcpy`.
  private let padRow: [Float16]

  init(contentsOf url: URL) throws {
    let mapped = try Data(contentsOf: url, options: .alwaysMapped)
    // Token gathers access random 384-byte rows across a 68 MB table: hint MADV_RANDOM so the
    // kernel skips wasteful sequential read-ahead page faults.
    mapped.withUnsafeBytes { raw in
      if let base = raw.baseAddress, !raw.isEmpty {
        _ = madvise(UnsafeMutableRawPointer(mutating: base), raw.count, MADV_RANDOM)
      }
    }
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

    var cachedPad = [Float16](repeating: 0, count: dimension)
    cachedPad.withUnsafeMutableBufferPointer { dst in
      if let outBase = dst.baseAddress {
        data.withUnsafeBytes { raw in
          let base = raw.baseAddress!  // swiftlint:disable:this force_unwrapping
          Self.dequantizeRow(
            id: 0, scalesBase: base.advanced(by: scalesOffset),
            weightsBase: base.advanced(by: weightsOffset),
            packedRowBytes: packedRowBytes, scaleMultiplier: Float(bitPattern: mulBits),
            into: outBase)
        }
      }
    }
    self.padRow = cachedPad
  }

  /// Dequantizes a single INT4 row using a 16-entry signed-nibble `Float16` LUT and `SIMD8` stores.
  @inline(__always)
  private static func dequantizeRow(
    id: Int,
    scalesBase: UnsafeRawPointer,
    weightsBase: UnsafeRawPointer,
    packedRowBytes: Int,
    scaleMultiplier: Float,
    into outRow: UnsafeMutablePointer<Float16>
  ) {
    let rowScale =
      scalesBase.loadUnaligned(fromByteOffset: id * MemoryLayout<Float>.size, as: Float.self)
      * scaleMultiplier
    // 16-entry LUT covers every 4-bit two's-complement value (0...7, -8...-1) with exact Float16 rounding.
    var lut = (
      Float16(0 * rowScale), Float16(1 * rowScale), Float16(2 * rowScale), Float16(3 * rowScale),
      Float16(4 * rowScale), Float16(5 * rowScale), Float16(6 * rowScale), Float16(7 * rowScale),
      Float16(-8 * rowScale), Float16(-7 * rowScale), Float16(-6 * rowScale), Float16(-5 * rowScale),
      Float16(-4 * rowScale), Float16(-3 * rowScale), Float16(-2 * rowScale), Float16(-1 * rowScale)
    )
    let packedRow = weightsBase.advanced(by: id * packedRowBytes).assumingMemoryBound(to: UInt8.self)
    withUnsafeBytes(of: &lut) { lutRaw in
      let table = lutRaw.bindMemory(to: Float16.self).baseAddress!  // swiftlint:disable:this force_unwrapping
      let simdBlocks = packedRowBytes / 4
      var byteIndex = 0
      var outIndex = 0
      for _ in 0..<simdBlocks {
        let b0 = packedRow[byteIndex]
        let b1 = packedRow[byteIndex + 1]
        let b2 = packedRow[byteIndex + 2]
        let b3 = packedRow[byteIndex + 3]
        let vec = SIMD8<Float16>(
          table[Int(b0 & 0x0F)], table[Int(b0 >> 4)],
          table[Int(b1 & 0x0F)], table[Int(b1 >> 4)],
          table[Int(b2 & 0x0F)], table[Int(b2 >> 4)],
          table[Int(b3 & 0x0F)], table[Int(b3 >> 4)])
        UnsafeMutableRawPointer(outRow.advanced(by: outIndex))
          .storeBytes(of: vec, as: SIMD8<Float16>.self)
        byteIndex += 4
        outIndex += 8
      }
      while byteIndex < packedRowBytes {
        let b = packedRow[byteIndex]
        outRow[outIndex] = table[Int(b & 0x0F)]
        outRow[outIndex + 1] = table[Int(b >> 4)]
        byteIndex += 1
        outIndex += 2
      }
    }
  }

  /// Dequantizes `tokenIDs` (padded with `padID = 0` up to `bucketLength`) into a contiguous
  /// `[1, bucketLength, dimension]` Float16 buffer.
  func fillFloat16(
    tokenIDs: [Int32],
    bucketLength: Int,
    into destination: UnsafeMutablePointer<Float16>
  ) {
    let count = min(tokenIDs.count, bucketLength)
    let rowBytes = dimension * MemoryLayout<Float16>.size
    padRow.withUnsafeBufferPointer { padBuf in
      let padPtr = padBuf.baseAddress!  // swiftlint:disable:this force_unwrapping
      data.withUnsafeBytes { raw in
        let base = raw.baseAddress!  // swiftlint:disable:this force_unwrapping
        let scalesBase = base.advanced(by: scalesOffset)
        let weightsBase = base.advanced(by: weightsOffset)
        for position in 0..<count {
          let rawID = Int(tokenIDs[position])
          let id = (rawID >= 0 && rawID < vocabSize) ? rawID : 0
          let outRow = destination.advanced(by: position * dimension)
          if id == 0 {
            memcpy(outRow, padPtr, rowBytes)
          } else {
            Self.dequantizeRow(
              id: id, scalesBase: scalesBase, weightsBase: weightsBase,
              packedRowBytes: packedRowBytes, scaleMultiplier: scaleMultiplier, into: outRow)
          }
        }
      }
      if count < bucketLength {
        for position in count..<bucketLength {
          memcpy(destination.advanced(by: position * dimension), padPtr, rowBytes)
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

  private struct CoreAIResources {
    let model: AIModel
    let tokenizer: SentencePieceTokenizer
    let table: INT4EmbeddingTable
    var functions: [Int: InferenceFunction] = [:]
  }

  private enum LoadedResources {
    case coreAI(CoreAIResources)
    case stub(@Sendable (String) async throws -> [Float])
  }

  private struct AssetLoadError: Error {
    let underlying: Error
  }

  /// Test seam injected only by unit tests to exercise the actor's cache recovery, coalescing,
  /// and `unload()` state machine without requiring an on-disk `.aimodel`.
  struct TestHooks: Sendable {
    let load: @Sendable (_ bypassCache: Bool) async throws -> (@Sendable (String) async throws -> [Float])
    let evict: @Sendable () -> Void
  }

  private let bundleURL: URL
  private let testHooks: TestHooks?
  private var resources: LoadedResources?
  private var loading: Task<LoadedResources, Error>?
  private var loadingBypassesCache = false
  private var generation = 0
  private var unloadGeneration = 0

  init(bundleURL: URL, testHooks: TestHooks? = nil) {
    self.bundleURL = bundleURL
    self.testHooks = testHooks
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
    unloadGeneration += 1
    loading?.cancel()
    loading = nil
    loadingBypassesCache = false
    resources = nil
  }

  // MARK: - Inference

  private static func isRecoverableCoreAIError(_ error: Error) -> Bool {
    !(error is CancellationError || error is AssetLoadError
      || error is INT4EmbeddingTable.LoadError || error is SentencePieceTokenizer.LoadError)
  }

  private static func unwrappedError(_ error: Error) -> Error {
    (error as? AssetLoadError)?.underlying ?? error
  }

  private func encode(prompt: String) async throws -> [Float] {
    let gen = generation
    let unloadGen = unloadGeneration
    do {
      let loaded = try await loadedResources(bypassCache: false)
      return try await runEncode(prompt: prompt, resources: loaded)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard Self.isRecoverableCoreAIError(error) else {
        throw Self.unwrappedError(error)
      }
      // If unload() ran while this call was in flight, never resurrect the ANE model.
      guard unloadGeneration == unloadGen else {
        throw error
      }
      do {
        let fresh: LoadedResources
        if generation == gen {
          // iOS 27's AIModelCache.default can return a stale AIModel handle whose compiled
          // MPSGraphNDX ANE binary was purged or invalidated (throwing _GenericObjCError.nilError on
          // loadFunction/run). Evict only this model's cache entries and re-specialize once cleanly.
          Log.engine.warning(
            "embedder: Core AI ANE call failed (\(error.localizedDescription, privacy: .public)); evicting cache and re-specializing"
          )
          evictCacheAndReset()
          fresh = try await loadedResources(bypassCache: true)
        } else {
          // A sibling caller already evicted the stale cache and started (or completed) recovery;
          // join that recovery instead of cancelling it and double-evicting.
          fresh = try await loadedResources(bypassCache: false)
        }
        return try await runEncode(prompt: prompt, resources: fresh)
      } catch {
        throw Self.unwrappedError(error)
      }
    }
  }

  private func runEncode(prompt: String, resources loaded: LoadedResources) async throws -> [Float] {
    switch loaded {
    case .stub(let encode):
      return try await encode(prompt)
    case .coreAI(let core):
      let maxLen = Self.buckets[Self.buckets.count - 1]
      let tokens = core.tokenizer.encodeWithSpecialTokens(prompt, maxLength: maxLen)
      let bucket = Self.bucket(for: tokens.count)
      let function = try functionForBucket(bucket, fallbackModel: core.model)

      var embeddings = NDArray(shape: [1, bucket, core.table.dimension], scalarType: .float16)
      embeddings.mutableView(as: Float16.self).withUnsafeMutablePointer { ptr, _, _ in
        core.table.fillFloat16(tokenIDs: tokens, bucketLength: bucket, into: ptr)
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
  }

  private func functionForBucket(
    _ bucket: Int, fallbackModel: AIModel
  ) throws -> InferenceFunction {
    if case .coreAI(let current) = resources, let cached = current.functions[bucket] {
      return cached
    }
    let model: AIModel = if case .coreAI(let current) = resources { current.model } else { fallbackModel }
    let name = "encoder_\(bucket)"
    guard let fn = try model.loadFunction(named: name) else {
      throw EmbedderError.missingFunction(name)
    }
    if case .coreAI(var current) = resources {
      current.functions[bucket] = fn
      resources = .coreAI(current)
    }
    return fn
  }

  private func evictCacheAndReset() {
    generation += 1
    loading?.cancel()
    loading = nil
    loadingBypassesCache = false
    resources = nil
    if let testHooks {
      testHooks.evict()
      return
    }
    let modelURL = bundleURL.appendingPathComponent("text_encoder.aimodel", isDirectory: true)
    let options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
    try? AIModelCache.default.deleteEntry(for: modelURL, options: options)
    try? AIModelCache.default.deleteEntries(for: modelURL)
  }

  private func loadedResources(bypassCache: Bool) async throws -> LoadedResources {
    var needsBypass = bypassCache
    while true {
      try Task.checkCancellation()
      if !needsBypass, let resources { return resources }
      let started = generation
      let startedUnload = unloadGeneration
      let task: Task<LoadedResources, Error>
      let ownsTask: Bool
      if let existing = loading, !needsBypass || loadingBypassesCache {
        task = existing
        ownsTask = false
      } else {
        loading?.cancel()
        let url = bundleURL
        let hooks = testHooks
        let taskBypass = needsBypass
        let created = Task<LoadedResources, Error> {
          if let hooks { return .stub(try await hooks.load(taskBypass)) }
          return .coreAI(try await Self.load(bundleURL: url, bypassCache: taskBypass))
        }
        loading = created
        loadingBypassesCache = taskBypass
        task = created
        ownsTask = true
      }
      defer {
        if ownsTask, loading == task {
          loading = nil
          loadingBypassesCache = false
        }
      }
      do {
        let loaded = try await task.value
        if unloadGeneration != startedUnload { throw CancellationError() }
        if generation == started {
          if ownsTask { resources = loaded }
          return loaded
        }
        needsBypass = false
      } catch is CancellationError {
        if !Task.isCancelled, unloadGeneration == startedUnload, generation != started {
          needsBypass = false
          continue
        }
        throw CancellationError()
      }
    }
  }

  private static func load(bundleURL: URL, bypassCache: Bool) async throws -> CoreAIResources {
    let started = ContinuousClock.now
    let modelURL = bundleURL.appendingPathComponent("text_encoder.aimodel", isDirectory: true)
    let tableURL = bundleURL.appendingPathComponent("embed_tokens.bin")
    let tokenizerURL = bundleURL.appendingPathComponent("tokenizer.model")

    async let tokenizerTask = Task.detached(priority: .userInitiated) {
      do {
        return try SentencePieceTokenizer(contentsOf: tokenizerURL)
      } catch {
        throw AssetLoadError(underlying: error)
      }
    }.value
    async let tableTask = Task.detached(priority: .userInitiated) {
      do {
        return try INT4EmbeddingTable(contentsOf: tableURL)
      } catch {
        throw AssetLoadError(underlying: error)
      }
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
    return CoreAIResources(model: model, tokenizer: tokenizer, table: table)
  }
}
