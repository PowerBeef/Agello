import LiteRTLM
import XCTest

@testable import iRTChat

/// Feasibility probes for LiteRT-LM features the overhaul builds on.
/// Opt-in: HARNESS_PROBES=1. Each probe frees the app's engine first.
final class ProbeScenarioTests: DeviceTestCase {

  override func setUp() async throws {
    try await super.setUp()
    guard ProcessInfo.processInfo.environment["HARNESS_PROBES"] == "1" else {
      throw XCTSkip("Set HARNESS_PROBES=1 to run LiteRT-LM probes")
    }
  }

  private func gemmaEngine(maxNumTokens: Int = 8_192) async throws -> Engine {
    _ = try await harness.ensureDownloaded(ModelCatalog.e4b)
    await appState.engine.unload()
    let url = try XCTUnwrap(appState.store.localURL(for: ModelCatalog.e4b))
    let engine = Engine(
      engineConfig: try EngineConfig(
        modelPath: url.path, backend: .gpu, maxNumTokens: maxNumTokens,
        cacheDir: try LiteRTChatEngine.cacheDirectory()))
    try await engine.initialize()
    return engine
  }

  /// Helper tasks (titles, memory, query rewriting) need a second, short-lived
  /// conversation on the chat engine without disturbing the main one.
  func test01_SecondConversationOnSameEngine() async throws {
    let engine = try await gemmaEngine()
    let main = try await engine.createConversation(with: ConversationConfig())
    _ = try await main.sendMessage(
      LiteRTLM.Message("Remember this code word: ZORBLAX. Reply only with 'noted'."))
    let beforeHelper = MemoryProbe.footprintBytes()

    let started = Date()
    var helperReply = ""
    var helperError = ""
    do {
      let helper = try await engine.createConversation(with: ConversationConfig())
      let reply = try await helper.sendMessage(
        LiteRTLM.Message("Give a three-word title for a chat about lighthouse keepers."),
        maxOutputTokens: 16)
      helperReply = reply.toString
    } catch {
      helperError = String(describing: error)
    }
    let helperSeconds = Date().timeIntervalSince(started)
    let helperFootprint = MemoryProbe.footprintBytes()

    let recall = try await main.sendMessage(LiteRTLM.Message("What code word did I give you?"))
    // Measured on device (v0.18.0): creating a second conversation wipes the
    // first one's context — one live conversation per engine. The app must
    // therefore rebuild (reseed) the main conversation after any helper task.
    let rebuilt = try await engine.createConversation(
      with: ConversationConfig(initialMessages: [
        LiteRTLM.Message(
          "Remember this code word: ZORBLAX. Reply only with 'noted'.", role: .user),
        LiteRTLM.Message("noted", role: .model),
      ]))
    let rebuiltRecall = try await rebuilt.sendMessage(
      LiteRTLM.Message("What code word did I give you?"))
    harness.record(
      "probe01_secondConversation",
      [
        "helperReply": helperReply, "helperError": helperError, "helperSeconds": helperSeconds,
        "helperDeltaGB": (Double(helperFootprint) - Double(beforeHelper)) / 1e9,
        "mainRecallAfterHelper": recall.toString,
        "mainKeptContext": recall.toString.localizedCaseInsensitiveContains("ZORBLAX"),
        "rebuiltRecall": rebuiltRecall.toString,
      ], in: self)
    XCTAssertTrue(helperError.isEmpty, helperError)
    XCTAssertFalse(helperReply.isEmpty)
    XCTAssertTrue(
      rebuiltRecall.toString.localizedCaseInsensitiveContains("ZORBLAX"),
      "Rebuilding the main conversation must restore its context: \(rebuiltRecall.toString)")
  }

  /// Structured helper outputs (search queries, memory facts) via
  /// JSON-schema constrained decoding.
  func test02_ConstrainedJSON() async throws {
    let engine = try await gemmaEngine()
    let conversation = try await engine.createConversation(
      with: ConversationConfig(enableResponseFormat: true))
    let schema: [String: Any] = [
      "type": "object",
      "properties": [
        "queries": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 3]
      ],
      "required": ["queries"],
    ]
    let started = Date()
    let reply = try await conversation.sendMessage(
      LiteRTLM.Message(
        "Write web search queries to answer: who won the most recent Tour de France, and by how much?"),
      maxOutputTokens: 128,
      responseFormat: try .json(schema: schema))
    let seconds = Date().timeIntervalSince(started)
    let text = reply.toString
    let parsed =
      (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    let queries = parsed?["queries"] as? [String] ?? []
    harness.record(
      "probe02_constrainedJSON",
      ["raw": text, "queries": queries, "seconds": seconds], in: self)
    XCTAssertNotNil(parsed, "Not valid JSON: \(text)")
    XCTAssertFalse(queries.isEmpty, "No queries: \(text)")
  }

  /// EmbeddingGemma 2 (text, 270M) for retrieval: load, speed, and whether
  /// the nearest passage is the right one.
  func test03_EmbeddingGemma() async throws {
    await appState.engine.unload()
    let url = try await Self.embeddingModel()
    let loadStarted = Date()
    let engine = EmbeddingEngine(
      config: EmbeddingEngineConfig(
        modelPath: url.path, backend: .gpu, cacheDir: try LiteRTChatEngine.cacheDirectory()))
    try await engine.initialize()
    let loadSeconds = Date().timeIntervalSince(loadStarted)
    let afterLoad = MemoryProbe.footprintBytes()

    let options = EmbeddingOptions(normalize: true, outputSize: 256)
    let passages = [
      "Mount Everest is Earth's highest mountain above sea level, at 8,849 metres.",
      "Python is a high-level programming language known for readable syntax.",
      "Paris is the capital of France and sits on the river Seine.",
      "The lighthouse keeper polished the lens every morning at dawn.",
    ]
    let embedStarted = Date()
    var vectors: [[Float]] = []
    for passage in passages {
      let response = try await engine.computeEmbedding(
        contents: [.text("title: none | text: " + passage)], options: options)
      vectors.append(response.embedding)
    }
    let perPassage = Date().timeIntervalSince(embedStarted) / Double(passages.count)
    let query = try await engine.computeEmbedding(
      contents: [.text("task: search result | query: How tall is the tallest mountain?")],
      options: options
    ).embedding
    let scores = vectors.map { zip($0, query).reduce(0) { $0 + $1.0 * $1.1 } }
    let best = scores.indices.max { scores[$0] < scores[$1] } ?? -1

    // Throughput on a realistic chunk (~400 tokens).
    let chunk = CalibrationScenarioTests.filler(bytes: 1_800)
    let chunkStarted = Date()
    _ = try await engine.computeEmbedding(contents: [.text("title: none | text: " + chunk)], options: options)
    let chunkSeconds = Date().timeIntervalSince(chunkStarted)
    await engine.close()

    harness.record(
      "probe03_embeddingGemma",
      [
        "loadSeconds": loadSeconds, "footprintGB": Double(afterLoad) / 1e9,
        "dimensions": query.count, "secondsPerShortPassage": perPassage,
        "secondsPer400TokenChunk": chunkSeconds, "scores": scores.map(Double.init),
        "bestIndex": best,
      ], in: self)
    XCTAssertEqual(query.count, 256)
    XCTAssertEqual(best, 0, "Wrong nearest passage: \(scores)")
  }

  static func embeddingModel() async throws -> URL {
    let dir = try FileManager.default.url(
      for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let destination = dir.appendingPathComponent("embeddinggemma-2-text-270m.litertlm")
    if FileManager.default.fileExists(atPath: destination.path) { return destination }
    let source = URL(
      string:
        "https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm/resolve/main/embeddinggemma-2-text-270m.litertlm"
    )!
    let (temporary, response) = try await URLSession.shared.download(from: source)
    try ModelStore.validateResponse(response)
    try FileManager.default.moveItem(at: temporary, to: destination)
    return destination
  }

  /// Numbers in replies came out duplicated once ("March 202026",
  /// "pp. 222–24"). Copy tasks and the real file follow-up, with speculative
  /// decoding (MTP) on and off, counting corrupted outputs.
  func test04_NumberFidelityWithAndWithoutMTP() async throws {
    try await requireLoadedModel()
    let copyLine =
      "The renovation budget of 4.2 million dollars was approved in March 2026 (coastal-report.pdf, pp. 22–24)."
    let years = (2018...2030).map(String.init).joined(separator: ", ")
    var report: [String: Any] = [:]
    for mtp in [true, false] {
      appState.options.enableSpeculativeDecoding = mtp
      await appState.applyCurrentOptions()
      _ = await appState.ensureEngineLoaded()
      var failures: [String] = []
      var trials = 0
      for _ in 0..<6 {
        trials += 2
        let copy = await harness.ask(
          "Copy this line exactly, with nothing else:\n\(copyLine)", in: harness.newThread())
        let copied = copy.text.replacingOccurrences(of: "**", with: "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if !copied.contains(copyLine) { failures.append("copy: \(copied)") }
        let list = await harness.ask(
          "Write the years from 2018 to 2030 separated by commas and spaces, nothing else.",
          in: harness.newThread())
        if !list.text.contains(years) { failures.append("years: \(list.text)") }
      }
      for _ in 0..<4 {
        trials += 1
        let thread = harness.newThread()
        let document = appState.knowledge.add(KnowledgeScenarioTests.report(), threadID: thread.id)
        if let document { await appState.knowledge.waitForIndexing([document]) }
        let reply = await harness.ask(
          "What was the harbour renovation budget, and when was it approved?", in: thread)
        let pages = reply.text.matches(of: /pp?\. ?(\d+)/).compactMap { Int($0.output.1) }
        if reply.text.contains("202026") || pages.contains(where: { $0 > 40 })
          || !reply.text.contains("2026")
        {
          failures.append("file: \(reply.text)")
        }
      }
      report[mtp ? "mtpOn" : "mtpOff"] = [
        "trials": trials, "failures": failures.count, "examples": Array(failures.prefix(6)),
        "speculative": appState.resolved?.enableSpeculativeDecoding ?? false,
      ]
      harness.record("probe04_numberFidelity", report, in: self)
    }
    appState.options.enableSpeculativeDecoding = true
  }
}
