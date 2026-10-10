import XCTest

@testable import iRTChat

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
    let seconds = try await harness.ensureDownloaded(ModelCatalog.embeddingGemma, timeout: 900)
    XCTAssertNotNil(appState.knowledge.currentEmbedder() as? LiteRTEmbedder)
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

  func test02_SummarizeLongPDFThenCitedFollowUp() async throws {
    try await requireLoadedModel()
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
    // LiteRT-LM #3913: 16-bit GPU activations duplicated digits here.
    XCTAssertFalse(followUp.text.contains("202026"), followUp.text)
    XCTAssertFalse(followUp.text.contains("222"), followUp.text)
    XCTAssertEqual(followUp.reply?.stats?.backend, "GPU·FP32", "Long context should run in float32")
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
}
