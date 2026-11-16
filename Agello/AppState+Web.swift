import Foundation
import SwiftData

/// Web search before a reply and the automatic web_search tool. Part of ``AppState``, split by area (2026-11-16).
extension AppState {
  /// Plan queries (what the message needs, follow-ups resolved from the conversation), then
  /// research them: passages rank by their best match to the message or a planned need, and a
  /// request leaves more room for the work.
  func searchWeb(
    question: String, history: [(role: ChatRole, text: String)], firstIndex: Int,
    fileTokens: Int = 0
  ) async -> WebOutcome {
    preparingStatus = String(localized: "Planning the search…")
    let prompt = WebContext.queryPrompt(question: question, history: history)
    let output: Data? = await serialized {
      let output = try? await self.engine.helperJSON(
        prompt: prompt, schemaJSON: WebContext.querySchema,
        maxOutputTokens: WebContext.queryMaxOutputTokens)
      await self.afterHelper()
      return output
    }
    let plan = output.map(WebContext.parsePlan) ?? WebContext.Plan(queries: [], isRequest: false)
    lastWebPlan = plan
    if !plan.needsSearch { return .notNeeded }
    let queries = plan.queries.isEmpty ? [WebContext.directQuery(question, history: history)] : plan.queries
    if Task.isCancelled { return .cancelled }
    let window = resolved?.maxNumTokens ?? 8_192
    do {
      let findings = try await webResearch.research(
        queries: queries, question: question,
        rankingQueries: [question] + plan.queries, topic: plan.topic,
        language: WebClient.wikipediaLanguage(for: question), settings: webSettings,
        budgetTokens: WebContext.budget(
          window: window, question: question, alongsideFileTokens: fileTokens, forRequest: plan.isRequest),
        firstIndex: firstIndex
      ) { status in self.preparingStatus = status }
      return findings.sources.isEmpty
        ? .failed(String(localized: "The web search found nothing useful. Answered without it."))
        : .found(findings)
    } catch is CancellationError {
      return .cancelled
    } catch {
      if Task.isCancelled { return .cancelled }
      return .failed(
        String(localized: "Web search failed: \(error.localizedDescription) Answered without it."))
    }
  }

  /// The automatic `web_search` tool's work (runs during a reply).
  func installWebSearchTool() {
    WebSearchTool.handler = { [weak self] query, topic, maxTokens in
      await self?.toolSearch(query, topic: topic, maxTokens: maxTokens) ?? "Web search is unavailable."
    }
  }

  func toolSearch(_ query: String, topic: SearchTopic, maxTokens: Int) async -> String {
    guard webSettings.allowed else { return "Web search is turned off." }
    do {
      let findings = try await webResearch.research(
        queries: [query], question: query, topic: topic,
        language: WebClient.wikipediaLanguage(for: query), settings: webSettings,
        // Room for the sources block's own lines.
        budgetTokens: max(200, maxTokens - 40),
        firstIndex: toolSourceOffset + WebSourcesRecorder.nextIndex
      ) { _ in }
      WebSourcesRecorder.record(findings.sources.map(\.record))
      return findings.sources.isEmpty ? "No results." : WebContext.sourcesBlock(findings.sources)
    } catch {
      return "Web search failed: \(error.localizedDescription)"
    }
  }
}
