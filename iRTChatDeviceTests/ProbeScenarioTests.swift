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

  private func gemmaEngine(
    maxNumTokens: Int = 8_192, gpu: Bool = true, activations: ActivationDataType? = nil,
    audio: Bool = false
  ) async throws -> Engine {
    _ = try await harness.ensureDownloaded(ModelCatalog.e4b)
    await appState.engine.unload()
    let url = try XCTUnwrap(appState.store.localURL(for: ModelCatalog.e4b))
    let engine = Engine(
      engineConfig: try EngineConfig(
        modelPath: url.path, backend: gpu ? .gpu : .cpu(), audioBackend: audio ? .cpu() : nil,
        maxNumTokens: maxNumTokens,
        cacheDir: try LiteRTChatEngine.cacheDirectory(), activationDataType: activations))
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
    // As in the app's helpers: MTP corrupts grammar-constrained decoding.
    let conversation = try await engine.createConversation(
      with: ConversationConfig(enableResponseFormat: true, enableSpeculativeDecoding: false))
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

  /// Is "March 202026 (… pp. 222–24)" generated by the model, or made by
  /// streaming? Same app prompt, raw LiteRT-LM: streamed vs whole reply,
  /// several seeds, greedy decoding, with and without the app's tools.
  func test05_DigitDuplicationRawStream() async throws {
    _ = try await harness.ensureDownloaded(ModelCatalog.embeddingGemma, timeout: 900)
    let thread = harness.newThread()
    let document = try XCTUnwrap(
      appState.knowledge.add(KnowledgeScenarioTests.report(), threadID: thread.id))
    await appState.knowledge.waitForIndexing([document])
    let question = "What was the harbour renovation budget, and when was it approved?"
    let passages = FileContext.fit(
      await appState.knowledge.search(question, in: [document], limit: 24),
      budget: FileContext.budget(window: 8_192, question: question))
    let prompt = FileContext.prompt(
      question: question, materials: [.excerpts(passages.map { (label: $0.citation, text: $0.text) })])
    XCTAssertFalse(prompt.contains("202026"), "The prompt itself is corrupted")

    let engine = try await gemmaEngine()
    let results = try await Self.runDigitVariants(engine: engine, prompt: prompt)
    harness.record(
      "probe05_digitDuplication", ["prompt": String(prompt.suffix(400)), "results": results], in: self)
  }

  /// Which condition triggers the duplication: CPU vs GPU, fewer excerpts,
  /// labels without page numbers (greedy decoding, whole replies).
  func test06_DigitDuplicationConditions() async throws {
    _ = try await harness.ensureDownloaded(ModelCatalog.embeddingGemma, timeout: 900)
    let thread = harness.newThread()
    let document = try XCTUnwrap(
      appState.knowledge.add(KnowledgeScenarioTests.report(), threadID: thread.id))
    await appState.knowledge.waitForIndexing([document])
    let question = "What was the harbour renovation budget, and when was it approved?"
    let passages = FileContext.fit(
      await appState.knowledge.search(question, in: [document], limit: 24),
      budget: FileContext.budget(window: 8_192, question: question))
    func prompt(_ passages: [Passage], numbered: Bool = false) -> String {
      FileContext.prompt(
        question: question,
        materials: [
          .excerpts(
            passages.enumerated().map {
              (label: numbered ? "Excerpt \($0.offset + 1)" : $0.element.citation, text: $0.element.text)
            })
        ])
    }
    let cases = [
      ("full", prompt(passages)), ("top3", prompt(Array(passages.prefix(3)))),
      ("top1", prompt(Array(passages.prefix(1)))), ("fullNumberedLabels", prompt(passages, numbered: true)),
    ]
    var results: [[String: String]] = []
    for gpu in [true, false] {
      let engine = try await gemmaEngine(gpu: gpu)
      for (name, text) in cases where gpu || name == "full" {
        let reply = try await Self.greedyWhole(engine: engine, prompt: text)
        results.append([
          "case": "\(gpu ? "gpu" : "cpu")_\(name)", "reply": reply,
          "corrupted": reply.contains("202026") || reply.contains("222") ? "yes" : "no",
          "promptTokensApprox": "\(ContextBudget.estimateTokens(text))",
        ])
        harness.record("probe06_digitConditions", ["results": results], in: self)
      }
      // `engine` is released here (Engine frees its native handle on deinit).
    }
  }

  /// Does float32 GPU activation fix the duplication, and what does it cost?
  func test07_GPUFloat32Activations() async throws {
    _ = try await harness.ensureDownloaded(ModelCatalog.embeddingGemma, timeout: 900)
    let thread = harness.newThread()
    let document = try XCTUnwrap(
      appState.knowledge.add(KnowledgeScenarioTests.report(), threadID: thread.id))
    await appState.knowledge.waitForIndexing([document])
    let question = "What was the harbour renovation budget, and when was it approved?"
    let passages = FileContext.fit(
      await appState.knowledge.search(question, in: [document], limit: 24),
      budget: FileContext.budget(window: 8_192, question: question))
    let prompt = FileContext.prompt(
      question: question, materials: [.excerpts(passages.map { (label: $0.citation, text: $0.text) })])
    let essay = "Write about 250 words on how lighthouses work."
    var results: [[String: String]] = []
    for activations: ActivationDataType? in [nil, .float32] {
      let name = activations == nil ? "default" : "float32"
      let engine = try await gemmaEngine(activations: activations)
      let promptStarted = Date()
      let reply = try await Self.greedyWhole(engine: engine, prompt: prompt)
      let promptSeconds = Date().timeIntervalSince(promptStarted)
      let essayStarted = Date()
      let essayReply = try await Self.greedyWhole(engine: engine, prompt: essay, maxOutputTokens: 320)
      let essaySeconds = Date().timeIntervalSince(essayStarted)
      results.append([
        "activations": name, "reply": reply,
        "corrupted": reply.contains("202026") || reply.contains("222") ? "yes" : "no",
        "fileAnswerSeconds": String(format: "%.2f", promptSeconds),
        "essaySeconds": String(format: "%.2f", essaySeconds),
        "essayChars": "\(essayReply.count)",
        "footprintGB": String(format: "%.2f", Double(MemoryProbe.footprintBytes()) / 1e9),
      ])
      harness.record("probe07_float32", ["results": results], in: self)
    }
  }

  /// Memory extraction: which prompt gets Gemma to list facts (and nothing
  /// for impersonal messages) under JSON-constrained decoding?
  func test08_MemoryExtractionPrompts() async throws {
    try await requireLoadedModel()
    let messages = [
      "I'm vegetarian and I live in Montreal. Suggest a quick dinner.",
      "My daughter Léa is 6 and loves dinosaurs. Any gift ideas?",
      "Remember that my gate code is 4521.",
      "Je travaille comme infirmière de nuit, des idées de repas faciles ?",
      "What is 2+2?",
    ]
    func variantB(_ message: String, key: String) -> String {
      """
      You keep a short memory about the user for future conversations.

      Extract lasting facts about the user from their message below: preferences, diet, where \
      they live, work, family, pets, ongoing projects, and anything they ask you to remember. \
      Write each fact as a short phrase, for example "Is vegetarian", "Lives in Montreal", \
      "Has a daughter, Léa (6)". Don't include the request or question itself. Return an empty \
      list only when the message says nothing about the user.

      Already remembered (don't repeat): (none)

      User's message: "\(message)"
      """
    }
    let variants: [(String, (String) -> String, String)] = [
      ("A_current", { HelperTasks.memoryPrompt(user: $0, existing: []) }, HelperTasks.memorySchema),
      ("B_instructionsFirst", { variantB($0, key: "memories") }, HelperTasks.memorySchema),
      (
        "C_factsKey", { variantB($0, key: "facts").replacingOccurrences(of: "memory", with: "notes") },
        #"{"type":"object","properties":{"facts":{"type":"array","items":{"type":"string"},"maxItems":3}},"required":["facts"]}"#
      ),
    ]
    var results: [[String: String]] = []
    for (name, prompt, schema) in variants {
      for message in messages {
        let started = Date()
        let output = (try? await appState.engine.helperJSON(
          prompt: prompt(message), schemaJSON: schema, maxOutputTokens: 96)).map {
            String(decoding: $0, as: UTF8.self)
          } ?? "ERROR"
        results.append([
          "variant": name, "message": String(message.prefix(40)), "output": output,
          "seconds": String(format: "%.1f", Date().timeIntervalSince(started)),
        ])
        harness.record("probe08_memoryPrompts", ["results": results], in: self)
      }
    }
  }

  /// Voice mode design: (A) audio straight to Gemma, (C) "transcript
  /// first, then answer" in the same reply; time to the first speakable
  /// answer sentence and format compliance; (B) the cost of re-reading a
  /// voice chat's history after a helper wipes the conversation.
  func test09_VoiceTurnLatency() async throws {
    let utterances = [
      ("en-US", "What's a good name for a golden retriever puppy?"),
      ("en-US", "How long should I boil an egg for a soft yolk?"),
      ("fr-CA", "Quelle est la capitale de l'Australie?"),
    ]
    var audio: [(String, String, URL)] = []
    for (language, text) in utterances {
      audio.append((language, text, try await TestMedia.spokenWAV(text, language: language)))
    }
    defer { for item in audio { try? FileManager.default.removeItem(at: item.2) } }
    let engine = try await gemmaEngine(audio: true)
    let plain = "You are a helpful voice assistant. Answer in one to three short spoken sentences, without markdown."
    let transcriptFirst =
      plain
      + " Start every reply with exactly what the user said, transcribed in their language between ⟦ and ⟧, then your answer."
    var results: [[String: String]] = []
    for (mode, system) in [("A_direct", plain), ("C_transcriptFirst", transcriptFirst)] {
      for (language, reference, url) in audio {
        let timing = try await Self.timeVoiceTurn(engine: engine, system: system, audio: url)
        results.append([
          "mode": mode, "language": language, "reference": reference, "reply": timing.text,
          "ttft": String(format: "%.2f", timing.firstToken),
          "firstSentence": String(format: "%.2f", timing.firstAnswerSentence),
          "total": String(format: "%.2f", timing.total),
        ])
        harness.record("probe09_voiceTurn", ["results": results], in: self)
      }
    }
    // (B) Re-reading history: 8 short text turns, then a short message.
    let reseed = try await Self.timeReseed(engine: engine, system: plain)
    harness.record(
      "probe09_voiceTurn",
      ["results": results, "reseed8TurnsTTFT": reseed.0, "freshTTFT": reseed.1], in: self)
  }

  struct VoiceTiming: Sendable {
    var firstToken: Double
    var firstAnswerSentence: Double
    var total: Double
    var text: String
  }

  nonisolated static func timeVoiceTurn(engine: Engine, system: String, audio: URL) async throws
    -> VoiceTiming
  {
    let config = ConversationConfig(
      systemMessage: LiteRTLM.Message(system),
      samplerConfig: try SamplerConfig(topK: 64, topP: 0.95, temperature: 0.7))
    let conversation = try await engine.createConversation(with: config)
    let started = Date()
    var first: Double?
    var sentence: Double?
    var text = ""
    for try await chunk in conversation.sendMessageStream(
      LiteRTLM.Message(contents: [.audioFile(audio.path)]), maxOutputTokens: 160)
    {
      if first == nil { first = Date().timeIntervalSince(started) }
      text += chunk.toString
      // The answer starts after the transcript, if any.
      let answer = text.components(separatedBy: "⟧").last ?? text
      if sentence == nil, text.contains("⟧") || !text.contains("⟦"),
        answer.range(of: #"[.!?](\s|$)"#, options: .regularExpression) != nil
      {
        sentence = Date().timeIntervalSince(started)
      }
    }
    let total = Date().timeIntervalSince(started)
    return VoiceTiming(firstToken: first ?? total, firstAnswerSentence: sentence ?? total, total: total, text: text)
  }

  nonisolated static func timeReseed(engine: Engine, system: String) async throws -> (Double, Double) {
    var history: [LiteRTLM.Message] = []
    for index in 0..<4 {
      history.append(LiteRTLM.Message("Tell me fact number \(index) about lighthouses, briefly.", role: .user))
      history.append(LiteRTLM.Message(
        "Lighthouses guide ships with bright lights from tall towers along dangerous coasts, and many were automated in the twentieth century.",
        role: .model))
    }
    func ttft(_ messages: [LiteRTLM.Message]) async throws -> Double {
      let conversation = try await engine.createConversation(
        with: ConversationConfig(systemMessage: LiteRTLM.Message(system), initialMessages: messages))
      let started = Date()
      for try await _ in conversation.sendMessageStream(LiteRTLM.Message("And one more?"), maxOutputTokens: 8) {
        return Date().timeIntervalSince(started)
      }
      return Date().timeIntervalSince(started)
    }
    let reseeded = try await ttft(history)
    let fresh = try await ttft([])
    return (reseeded, fresh)
  }

  nonisolated static func greedyWhole(engine: Engine, prompt: String, maxOutputTokens: Int = 160)
    async throws -> String
  {
    let config = ConversationConfig(
      systemMessage: LiteRTLM.Message(InferenceOptions().systemPrompt),
      samplerConfig: try SamplerConfig(topK: 1, topP: 1, temperature: 0))
    let conversation = try await engine.createConversation(with: config)
    return try await conversation.sendMessage(
      LiteRTLM.Message(prompt), maxOutputTokens: maxOutputTokens
    ).toString
  }

  /// Raw LiteRT-LM runs of `prompt` (off the main actor: configs aren't Sendable).
  nonisolated static func runDigitVariants(engine: Engine, prompt: String) async throws
    -> [[String: String]]
  {
    let variants: [(name: String, seed: Int, greedy: Bool, tools: Bool, stream: Bool)] = [
      ("app_seed0_stream", 0, false, true, true),
      ("app_seed0_whole", 0, false, true, false),
      ("noTools_seed0_stream", 0, false, false, true),
      ("greedy_stream", 0, true, true, true),
      ("greedy_whole", 0, true, true, false),
      ("app_seed1_stream", 1, false, true, true),
      ("app_seed2_stream", 2, false, true, true),
      ("app_seed3_stream", 3, false, true, true),
    ]
    var results: [[String: String]] = []
    for variant in variants {
      let sampler =
        variant.greedy
        ? try SamplerConfig(topK: 1, topP: 1, temperature: 0, seed: variant.seed)
        : try SamplerConfig(topK: 64, topP: 0.95, temperature: 0.7, seed: variant.seed)
      let tools: [any Tool] = variant.tools ? [CurrentDateTimeTool(), CalculatorTool()] : []
      let config = ConversationConfig(
        systemMessage: LiteRTLM.Message(InferenceOptions().systemPrompt), tools: tools,
        samplerConfig: sampler)
      let conversation = try await engine.createConversation(with: config)
      var chunks: [String] = []
      var text = ""
      if variant.stream {
        for try await chunk in conversation.sendMessageStream(
          LiteRTLM.Message(prompt), maxOutputTokens: 160)
        {
          chunks.append(chunk.toString)
          text += chunk.toString
        }
      } else {
        text = try await conversation.sendMessage(LiteRTLM.Message(prompt), maxOutputTokens: 160)
          .toString
      }
      let corrupted = text.contains("202026") || text.contains("222–24") || text.contains("222-24")
      results.append([
        "variant": variant.name, "text": text, "corrupted": corrupted ? "yes" : "no",
        "chunks": chunks.prefix(80).joined(separator: "|"),
      ])
    }
    return results
  }
}

// Probes build configurations once and hand them to the engine actor; the
// test target is strict Swift 6, where the (non-Sendable) config can't cross.
extension ConversationConfig: @retroactive @unchecked Sendable {}
