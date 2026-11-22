import LiteRTLM
import XCTest

@testable import Agello

/// Files on device with the real models: EmbeddingGemma indexing next to
/// E4B, retrieval quality, "summarize this 40-page PDF", and a cited
/// follow-up (the Phase 2 exit criterion).
final class KnowledgeScenarioTests: DeviceTestCase {

  /// A 40-page report (~18K tokens): routine pages plus a few distinct facts.
  static func report() -> ExtractedDocument {
    let topics = [
      "harbour maintenance", "coastal erosion", "lighthouse operations", "fisheries",
      "visitor services", "storm preparedness", "habitat restoration", "water quality",
    ]
    let facts: [Int: String] = [
      7: "The Cap Rouge lighthouse was fully automated in 1988, ending 140 years of resident keepers.",
      23: "The harbour renovation budget was 4.2 million dollars, approved by the council in March 2026.",
      35: "Survey divers counted 412 grey seals along the northern cliffs, up from 297 two years earlier.",
    ]
    let pages = (1...40).map { page -> String in
      let topic = topics[page % topics.count]
      var paragraphs = [
        "Section \(page): \(topic.capitalized).",
        "This section reviews \(topic) during the reporting period. Teams in district \(page % 5 + 1) "
          + "completed scheduled inspections, logged their findings, and filed follow-up requests "
          + "where repairs or further study were needed.",
        "Most indicators for \(topic) stayed within normal ranges. Seasonal variation was observed, "
          + "and staff recommend continuing the current monitoring programme with quarterly reviews "
          + "and an annual summary for the regional office.",
        "Coordination with neighbouring districts improved this year. Shared equipment reduced costs, "
          + "and joint training sessions helped new staff learn inspection procedures faster.",
      ]
      if let fact = facts[page] { paragraphs.insert(fact, at: 2) }
      return paragraphs.joined(separator: "\n\n")
    }
    return ExtractedDocument(name: "coastal-report.pdf", kind: .pdf, byteCount: 250_000, pages: pages)
  }

  /// Pages named by a citation: "x.pdf, p. 3" → 3...3, "pp. 22–24" → 22...24.
  static func pages(in citation: String) -> ClosedRange<Int> {
    let numbers = citation.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    guard let first = numbers.first else { return 0...0 }
    return first...(numbers.dropFirst().first ?? first)
  }

  private func freshEmbedding() async throws -> TimeInterval {
    let seconds: TimeInterval
    if KnowledgeBase.aneBundleURL() != nil {
      seconds = 0
    } else {
      seconds = try await harness.ensureDownloaded(ModelCatalog.embeddingGemma, timeout: 900)
    }
    let embedder = appState.knowledge.currentEmbedder()
    XCTAssertTrue(
      embedder is CoreAIEmbedder || embedder is LiteRTEmbedder,
      "Expected CoreAIEmbedder or LiteRTEmbedder, got \(String(describing: embedder))")
    return seconds
  }

  func test01_IndexAndRetrieveWithEmbeddingGemma() async throws {
    try await requireLoadedModel()
    let downloadSeconds = try await freshEmbedding()
    let thread = harness.newThread()
    let started = Date()
    let document = try XCTUnwrap(appState.knowledge.add(Self.report(), threadID: thread.id))
    await appState.knowledge.waitForIndexing([document])
    let indexSeconds = Date().timeIntervalSince(started)
    XCTAssertEqual(document.indexedWith, LiteRTEmbedder(modelURL: URL(filePath: "/")).identifier)

    // Each question must find the page holding its answer.
    let questions = [
      ("When was the lighthouse automated?", 7),
      ("How much money was approved for renovating the harbour?", 23),
      ("How many seals did the divers count?", 35),
    ]
    var hits: [[String: Any]] = []
    for (question, page) in questions {
      let searchStarted = Date()
      let passages = await appState.knowledge.search(question, in: [document], limit: 3)
      let pages = passages.map { ($0.pageStart ?? 0)...($0.pageEnd ?? 0) }
      let rank = pages.firstIndex { $0.contains(page) }
      hits.append([
        "question": question, "expectedPage": page, "rank": rank ?? -1,
        "citations": passages.map(\.citation),
        "searchSeconds": Date().timeIntervalSince(searchStarted),
      ])
      XCTAssertNotNil(rank, "\(question): page \(page) not in top 3 \(passages.map(\.citation))")
    }
    harness.record(
      "knowledge01_index",
      [
        "embeddingDownloadSeconds": downloadSeconds, "passages": document.chunks.count,
        "indexSeconds": indexSeconds, "hits": hits,
        "footprintGB": Double(MemoryProbe.footprintBytes()) / 1e9,
      ], in: self)

    // The chat model still works with the embedder loaded alongside it.
    let after = await harness.ask("Say 'ready'.", in: harness.newThread())
    XCTAssertFalse(after.text.isEmpty)
    XCTAssertFalse(after.text.hasPrefix(ChatTurn.errorPrefix), after.text)
  }

  /// Dense text: a Chinese report and a table of numbers. Their passages used to overflow the
  /// embedder's 1,024 tokens and fail the whole file, which was then searched by keywords
  /// (useless for Chinese) and re-embedded on every question.
  func test01b_DenseTextIsIndexed() async throws {
    try await requireLoadedModel()
    _ = try await freshEmbedding()
    let thread = harness.newThread()
    let chinese = (1...12).map { section in
      String(repeating: "第\(section)节：港口维护和海岸侵蚀的年度检查报告，记录了各区的巡查结果和后续维修请求。", count: 12)
        + (section == 7 ? "卡普鲁日灯塔于1988年实现全自动化，结束了一百四十年的驻守历史。" : "")
    }
    let table = (1...600).map { row in "\(2_000 + row) | \(row * 37 % 1_000) | \(row * 113 % 10_000) | \(row % 7)" }
      .joined(separator: "\n")
    let documents = [
      ExtractedDocument(name: "港口报告.txt", kind: .text, byteCount: 0, pages: [chinese.joined(separator: "\n\n")])
        .prepared(),
      ExtractedDocument(name: "readings.csv", kind: .text, byteCount: 0, pages: [table]).prepared(),
    ].compactMap { appState.knowledge.add($0, threadID: thread.id) }
    await appState.knowledge.waitForIndexing(documents)
    let identifier = LiteRTEmbedder(modelURL: URL(filePath: "/")).identifier
    let passages = await appState.knowledge.search("灯塔什么时候实现自动化？", in: documents, limit: 3)
    harness.record(
      "files_01b_denseText",
      [
        "indexedWith": documents.map { $0.indexedWith ?? "nil" },
        "passages": documents.map(\.chunks.count),
        "top": passages.map { String($0.text.prefix(80)) },
      ], in: self)
    XCTAssertEqual(documents.map(\.indexedWith), [identifier, identifier])
    XCTAssertTrue(passages.contains { $0.text.contains("1988") }, "\(passages.map(\.text))")
  }

  func test02_SummarizeLongPDFThenCitedFollowUp() async throws {
    try await requireLoadedModel()
    // The window of 8 GB devices, where this 40-page report doesn't fit whole and is summarized
    // by section. On 32K devices it fits (test02b).
    appState.options.maxNumTokensOverride = 16_384
    await appState.applyCurrentOptions()
    _ = try await freshEmbedding()
    let thread = harness.newThread()
    let document = try XCTUnwrap(appState.knowledge.add(Self.report(), threadID: thread.id))

    let summary = await harness.ask("Summarize this report in a few bullet points.", in: thread)
    XCTAssertTrue(summary.accepted)
    XCTAssertFalse(summary.text.hasPrefix(ChatTurn.errorPrefix), summary.text)
    XCTAssertGreaterThan(summary.text.count, 200, summary.text)
    XCTAssertNotNil(document.summary, "Section summaries weren't cached")

    let followUp = await harness.ask(
      "What was the harbour renovation budget, and when was it approved?", in: thread)
    XCTAssertFalse(followUp.text.hasPrefix(ChatTurn.errorPrefix), followUp.text)
    XCTAssertTrue(followUp.text.contains("4.2"), followUp.text)
    // LiteRT-LM #3913: the unpatched model duplicated digits here with 16-bit
    // GPU activations; the patched model is exact at the default precision.
    XCTAssertFalse(followUp.text.contains("202026"), followUp.text)
    XCTAssertFalse(followUp.text.contains("222"), followUp.text)
    XCTAssertEqual(followUp.reply?.stats?.backend, "GPU")
    let sources = followUp.reply?.parts.sources.map(\.title) ?? []
    XCTAssertTrue(
      sources.first.map { Self.pages(in: $0).contains(23) } ?? false,
      "The top source should cover page 23: \(sources)")

    // Asked again later: the cached summary makes it fast.
    let again = await harness.ask("Give me the main points again, briefly.", in: thread)
    XCTAssertFalse(again.text.hasPrefix(ChatTurn.errorPrefix), again.text)

    harness.record(
      "knowledge02_summarize",
      [
        "summarySeconds": summary.seconds, "summaryReply": String(summary.text.prefix(600)),
        "summaryStats": DeviceHarness.stats(summary.reply?.stats),
        "cachedSummaryChars": document.summary?.count ?? 0,
        "followUpSeconds": followUp.seconds, "followUpReply": followUp.text,
        "followUpSources": sources, "followUpMentionsPages": followUp.text.contains("22"),
        "againSeconds": again.seconds,
        "footprintGB": Double(MemoryProbe.footprintBytes()) / 1e9,
      ], in: self)
  }

  /// At the device's own window. On 32K devices (2026-11-09) the 40-page report fits whole: the
  /// reply answers from the file itself, with no section summaries to wait for.
  func test02b_LongPDFAtTheDeviceWindow() async throws {
    try await requireLoadedModel()
    _ = try await freshEmbedding()
    let thread = harness.newThread()
    let document = try XCTUnwrap(appState.knowledge.add(Self.report(), threadID: thread.id))
    let answer = await harness.ask(
      "What was the harbour renovation budget, and when was it approved?", in: thread)
    let sources = answer.reply?.parts.sources.map(\.title) ?? []
    harness.record(
      "knowledge02b_deviceWindow",
      [
        "window": appState.resolved?.maxNumTokens ?? 0, "seconds": answer.seconds,
        "reply": answer.text, "sources": sources,
        "cachedSummaryChars": document.summary?.count ?? 0,
        "stats": DeviceHarness.stats(answer.reply?.stats),
      ], in: self)
    XCTAssertTrue(answer.accepted, appState.generationError ?? "")
    XCTAssertFalse(answer.text.hasPrefix(ChatTurn.errorPrefix), answer.text)
    XCTAssertTrue(answer.text.contains("4.2"), answer.text)
    XCTAssertTrue(answer.text.contains("2026"), answer.text)
    XCTAssertFalse(answer.text.contains("202026"), answer.text)
    XCTAssertFalse(sources.isEmpty, "No sources for the file")
  }

  /// Search by meaning across chats: each paraphrased query (sharing no
  /// words with its chat) must rank its chat first. Records the full score
  /// matrix to calibrate the "related" threshold. Also indexes while a reply
  /// streams (embedding and chat model on the GPU at once).
  func test03_ChatsByMeaning() async throws {
    try await requireLoadedModel()
    _ = try await freshEmbedding()
    let chats: [(String, String, String)] = [
      ("Weeknight carbonara", "How do I make carbonara without cream?",
        "Whisk eggs and pecorino, toss with hot spaghetti and crispy guanciale."),
      ("Car making a grinding noise", "My car grinds when I brake, what is it?",
        "Worn brake pads are the usual cause; have the rotors checked too."),
      ("Kyoto itinerary", "Plan three days in Kyoto in spring.",
        "Day 1: Fushimi Inari and Gion; day 2: Arashiyama; day 3: temples in Higashiyama."),
      ("Filing my tax return", "When is the filing deadline and what forms do I need?",
        "Collect your T4 slips and file by April 30 to avoid penalties."),
    ]
    var threads: [ChatThread] = []
    for (title, user, reply) in chats {
      let thread = harness.newThread()
      thread.title = title
      thread.append(ChatTurn(role: .user, text: user))
      thread.append(ChatTurn(role: .model, text: reply))
      threads.append(thread)
    }

    // Index while a long reply streams.
    let streaming = Task { @MainActor in
      await self.harness.ask("Write about 200 words on how tides work.", in: self.harness.newThread())
        .text
    }
    try await Task.sleep(for: .seconds(2))
    let indexStarted = Date()
    appState.knowledge.indexChats(threads)
    await appState.knowledge.waitForChatIndexing()
    let indexSeconds = Date().timeIntervalSince(indexStarted)
    let tides = await streaming.value
    XCTAssertFalse(tides.hasPrefix(ChatTurn.errorPrefix), tides)
    XCTAssertGreaterThan(tides.count, 300, "Reply cut short while indexing")

    let queries = [
      ("Italian pasta dinner", 0), ("vehicle stopping problem", 1),
      ("Japan vacation plans", 2), ("money owed to the government", 3),
    ]
    var matrix: [[String: Any]] = []
    for (query, expected) in queries {
      let scores = await appState.knowledge.chatScores(query, in: threads)
      matrix.append([
        "query": query, "expected": chats[expected].0,
        "scores": scores.map { "\($0.thread.title): \(String(format: "%.3f", $0.score))" },
      ])
      XCTAssertEqual(scores.first?.thread.id, threads[expected].id, "\(query): \(scores.map(\.thread.title))")
    }
    harness.record(
      "knowledge03_chatsByMeaning",
      ["matrix": matrix, "indexSecondsWhileStreaming": indexSeconds, "tidesChars": tides.count],
      in: self)
  }

  private static func aneParityCorpus() -> (documents: [(title: String, text: String)], queries: [String]) {
    let documents: [(title: String, text: String)] = [
      ("notes.md", "Paris is the capital and most populous city of France, situated along the Seine River."),
      (
        "Architecture.md",
        "Global KV caches use Metal 4 sparse buffers with TrimKvMapping on reset and rewind."
      ),
      ("french.txt", "Bonjour ! Aujourd'hui nous testons l'indexation sémantique sur le Neural Engine."),
      ("cjk.txt", "東京の天気は晴れです。卡普鲁日灯塔于1988年实现全自动化，结束了一百四十年的驻守历史。"),
      (
        "code.swift",
        "actor CoreAIEmbedder: TextEmbedder {\n  func embed(query: String) async throws -> [Float] { [] }\n}"
      ),
      ("coastal-report.pdf", Self.report().pages[22]),
      ("long-report.pdf", Array(repeating: Self.report().pages[6], count: 4).joined(separator: "\n\n")),
    ]
    let queries = [
      "What is the capital of France?",
      "How much money was approved for renovating the harbour?",
      "灯塔什么时候实现自动化？",
      "CoreAIEmbedder actor Swift",
      "Italian pasta dinner without cream",
    ]
    return (documents, queries)
  }

  /// Verifies the Core AI Neural Engine embedder matches LiteRT-LM's true FP32 reference
  /// (cosine >= 0.995 across English, French, CJK, Swift code, and long PDF passages) while
  /// keeping `usesGPU == false` so retrieval never contends with E4B on Metal.
  func test04_CoreAIANEParity() async throws {
    guard let aneURL = KnowledgeBase.aneBundleURL() else {
      throw XCTSkip("Core AI ANE bundle not present in models directory")
    }
    let litertSpec = ModelCatalog.embeddingGemma
    guard appState.store.isDownloaded(litertSpec), let litertURL = appState.store.localURL(for: litertSpec)
    else {
      throw XCTSkip("LiteRT EmbeddingGemma baseline not present for parity comparison")
    }

    let ane = CoreAIEmbedder(bundleURL: aneURL)
    let gpu = LiteRTEmbedder(modelURL: litertURL)
    defer {
      Task {
        await ane.unload()
        await gpu.unload()
      }
    }

    XCTAssertFalse(ane.usesGPU)
    XCTAssertEqual(ane.identifier, gpu.identifier)
    XCTAssertEqual(ane.dimensions, gpu.dimensions)

    let (documents, queries) = Self.aneParityCorpus()
    let tok = try SentencePieceTokenizer(contentsOf: aneURL.appendingPathComponent("tokenizer.model"))
    let cjkTokens = tok.encode(
      LiteRTEmbedder.documentPrompt(title: documents[3].title, text: documents[3].text))
    let expectedCjkTokens: [Int32] = [
      3250, 236787, 505, 42838, 236761, 7090, 1109, 1816, 236787, 86459, 236945, 228212, 237048,
      240532, 237137, 3652, 236924, 238679, 238757, 240914, 237205, 239785, 240019, 237412,
      236770, 236819, 236828, 236828, 237155, 18979, 237450, 123426, 236900, 45783, 14542,
      238192, 226962, 28643, 241624, 239340, 36648, 236924,
    ]
    XCTAssertEqual(cjkTokens, expectedCjkTokens, "SentencePieceTokenizer mismatch on CJK prompt")

    _ = try await ane.embed(query: "warmup")
    _ = try await gpu.embed(query: "warmup")

    let aneStarted = Date()
    let aneVecs = try await Self.embedAll(documents: documents, queries: queries, using: ane)
    let aneSeconds = Date().timeIntervalSince(aneStarted)

    let gpuStarted = Date()
    let gpuVecs = try await Self.embedAll(documents: documents, queries: queries, using: gpu)
    let gpuSeconds = Date().timeIntervalSince(gpuStarted)

    let fp32Engine = EmbeddingEngine(
      config: EmbeddingEngineConfig(
        modelPath: litertURL.path, backend: .gpu, cacheDir: EngineCache.disabled,
        activationDataType: .float32))
    try await fp32Engine.initialize()
    let embOpts = EmbeddingOptions(normalize: true, outputSize: 768, inputOverflowStrategy: .truncate)
    let prompts =
      documents.map { LiteRTEmbedder.documentPrompt(title: $0.title, text: $0.text) }
      + queries.map { LiteRTEmbedder.queryPrompt($0, task: .search) }
    var fp32Vecs: [[Float]] = []
    for prompt in prompts {
      fp32Vecs.append(
        try await fp32Engine.computeEmbedding(contents: [.text(prompt)], options: embOpts).embedding)
    }
    await fp32Engine.close()

    let fp32Cosines = zip(aneVecs, fp32Vecs).map { VectorIndex.dot($0, $1) }
    let fp16Cosines = zip(aneVecs, gpuVecs).map { VectorIndex.dot($0, $1) }
    let minFP32 = fp32Cosines.min() ?? 0
    let avgFP32 = fp32Cosines.reduce(0, +) / Float(max(1, fp32Cosines.count))

    harness.record(
      "knowledge04_aneParity",
      [
        "count": fp32Cosines.count, "aneVsFP32Min": minFP32, "aneVsFP32Avg": avgFP32,
        "aneVsFP32": fp32Cosines.map { Double($0) },
        "aneVsLiteRTFP16": fp16Cosines.map { Double($0) },
        "aneSeconds": aneSeconds, "gpuSeconds": gpuSeconds,
      ], in: self)

    XCTAssertGreaterThanOrEqual(
      minFP32, 0.995,
      "ANE embedder cosine parity vs LiteRT FP32 dropped below 0.995: min=\(minFP32), all=\(fp32Cosines)")
  }
  private static func embedAll(
    documents: [(title: String, text: String)], queries: [String], using embedder: any TextEmbedder
  ) async throws -> [[Float]] {
    var vectors = try await embedder.embed(documents: documents)
    for query in queries { vectors.append(try await embedder.embed(query: query)) }
    return vectors
  }
}
