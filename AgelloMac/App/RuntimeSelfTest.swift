import Darwin
import Foundation
import LiteRTLM

/// `Agello --runtime-self-test [--cpu] [--model PATH] [--embedding-model PATH]`: loads E4B,
/// validates it with a one-token reply as the app does, generates up to 64 tokens, embeds one
/// sentence with EmbeddingGemma, prints one JSON object and exits (0 when every step passed).
/// It runs inside the signed, sandboxed app, so it checks the runtime under the hardened
/// runtime and the sandbox; the DMG check (M8) reuses it.
///
/// The models default to the app's own Models folder (Application Support, in the
/// container); clone them there from a local copy with `cp -c`.
enum RuntimeSelfTest {
  static let flag = "--runtime-self-test"
  /// `ModelCatalog`'s file names (the shared app isn't in this target yet).
  static let chatModelFile = "gemma-4-E4B-it-fp16-rope.litertlm"
  static let embeddingModelFile = "embeddinggemma-2-text-270m.litertlm"

  static func run(arguments: [String]) async -> Int32 {
    var report: [String: Any] = ["runtimeBuild": runtimeBuildInfo() ?? [:]]
    let useCPU = arguments.contains("--cpu")
    report["backend"] = useCPU ? "cpu" : "gpu"
    do {
      let chatModel = try modelPath(arguments, option: "--model", file: chatModelFile)
      let embeddingModel = try modelPath(
        arguments, option: "--embedding-model", file: embeddingModelFile)
      let backend: Backend = useCPU ? .cpu() : .gpu

      var started = Date()
      let engine = Engine(
        engineConfig: try EngineConfig(
          modelPath: chatModel, backend: backend, maxNumTokens: 4_096, cacheDir: ":nocache"))
      try await engine.initialize()
      report["loadSeconds"] = Date().timeIntervalSince(started)

      let probe = try await engine.createConversation(with: ConversationConfig())
      _ = try await probe.sendMessage(Message("Hi"), maxOutputTokens: 1)
      report["validated"] = true

      started = Date()
      let conversation = try await engine.createConversation(with: ConversationConfig())
      let reply = try await conversation.sendMessage(
        Message("Describe a lighthouse at night in a few sentences."), maxOutputTokens: 64
      ).toString
      let generated = try await engine.countTokens(reply)
      report["generatedTokens"] = generated
      report["generationSeconds"] = Date().timeIntervalSince(started)
      report["reply"] = String(reply.prefix(160))

      let embedder = EmbeddingEngine(
        config: EmbeddingEngineConfig(modelPath: embeddingModel, backend: backend, cacheDir: ":nocache"))
      try await embedder.initialize()
      let vector = try await embedder.computeEmbedding(
        contents: [.text("task: search result | query: a lighthouse at night")]
      ).embedding
      await embedder.close()
      report["embeddingDimensions"] = vector.count
      report["embeddingFinite"] = vector.allSatisfy(\.isFinite)

      let passed = generated > 0 && !vector.isEmpty && vector.allSatisfy(\.isFinite)
      report["passed"] = passed
      print(json(report))
      return passed ? 0 : 1
    } catch {
      report["passed"] = false
      report["error"] = String(describing: error)
      print(json(report))
      return 1
    }
  }

  private static func modelPath(_ arguments: [String], option: String, file: String) throws -> String {
    if let index = arguments.firstIndex(of: option), arguments.indices.contains(index + 1) {
      return arguments[index + 1]
    }
    let folder = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
    ).appendingPathComponent("Models", isDirectory: true)
    return folder.appendingPathComponent(file).path
  }

  /// `litert_lm_get_build_info`, looked up at run time: Google's binary doesn't have it.
  private static func runtimeBuildInfo() -> [String: String]? {
    typealias GetBuildInfo = @convention(c) () -> UnsafePointer<CChar>?
    guard let handle = dlopen(nil, RTLD_NOW), let address = dlsym(handle, "litert_lm_get_build_info"),
      let text = unsafeBitCast(address, to: GetBuildInfo.self)()
    else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(String(cString: text).utf8))) as? [String: String]
  }

  private static func json(_ report: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else {
      return "{\"passed\": false}"
    }
    return String(decoding: data, as: UTF8.self)
  }
}
