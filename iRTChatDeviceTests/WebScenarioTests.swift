import XCTest

@testable import iRTChat

/// Live web search with the real model (needs internet): a cited answer to
/// a current-events question, a follow-up that needs planned queries, and
/// automatic mode.
final class WebScenarioTests: DeviceTestCase {

  func test01_SearchAndCite() async throws {
    try await requireLoadedModel()
    _ = try await harness.ensureDownloaded(ModelCatalog.embeddingGemma, timeout: 900)
    let thread = harness.newThread()
    let answer = await harness.ask(
      "Who won the 2026 Tour de France?", in: thread, webSearch: true)
    let sources = answer.reply?.parts.sources ?? []
    let followUp = await harness.ask("By how many minutes?", in: thread, webSearch: true)
    let followSources = followUp.reply?.parts.sources ?? []
    harness.record(
      "web01_searchAndCite",
      [
        "seconds": answer.seconds, "reply": answer.text,
        "sources": sources.map { "\($0.index) \($0.title) \($0.url ?? "")" },
        "notice": appState.generationError ?? "",
        "followUpSeconds": followUp.seconds, "followUpReply": followUp.text,
        "followUpSources": followSources.map(\.title),
        "stats": DeviceHarness.stats(answer.reply?.stats),
      ], in: self)
    XCTAssertFalse(answer.text.hasPrefix(ChatTurn.errorPrefix), answer.text)
    XCTAssertFalse(sources.isEmpty, "No sources: \(appState.generationError ?? "")")
    XCTAssertTrue(sources.allSatisfy { $0.url?.hasPrefix("https://") == true })
    XCTAssertTrue(
      answer.text.range(of: "Poga[cč]ar", options: .regularExpression) != nil, answer.text)
    XCTAssertTrue(answer.text.contains("[1]") || answer.text.contains("[2]"), "No citation: \(answer.text)")
    XCTAssertTrue(answer.reply?.parts.sources.isEmpty == false)
    XCTAssertTrue(thread.orderedTurns.first?.parts.webSearch == true)
    XCTAssertFalse(followUp.text.hasPrefix(ChatTurn.errorPrefix), followUp.text)
    XCTAssertFalse(followSources.isEmpty)
  }

  func test02_AutomaticSearch() async throws {
    try await requireLoadedModel()
    appState.webSettings.automatic = true
    defer { appState.webSettings.automatic = false }
    await appState.applyCurrentOptions()
    let reply = await harness.ask(
      "Search the web: what is the latest stable version of Swift?", in: harness.newThread())
    let tools = reply.reply?.parts.toolActivity.map(\.summary) ?? []
    let sources = reply.reply?.parts.sources ?? []
    harness.record(
      "web02_automatic",
      ["reply": reply.text, "tools": tools, "sources": sources.map(\.title), "seconds": reply.seconds],
      in: self)
    XCTAssertFalse(reply.text.hasPrefix(ChatTurn.errorPrefix), reply.text)
    XCTAssertTrue(tools.contains { $0.contains("Searched the web") }, "web_search not called: \(tools)")
    XCTAssertFalse(sources.isEmpty)
  }
}
