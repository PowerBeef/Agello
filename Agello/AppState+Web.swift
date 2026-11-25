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
    let plan = await planSearch(question: question, history: history).plan
    lastWebPlan = plan
    if !plan.needsSearch { return .notNeeded }
    let queries = plan.queries.isEmpty ? [WebContext.directQuery(question, history: history)] : plan.queries
    if Task.isCancelled { return .cancelled }
    BackgroundWork.shared.stepProgress(
      completed: 1, total: 4, subtitle: String(localized: "Searching sources…"))
    let window = resolved?.maxNumTokens ?? 8_192
    do {
      let findings = try await webResearch.research(
        queries: queries, question: question,
        rankingQueries: [question] + plan.queries, topic: plan.topic,
        language: WebClient.wikipediaLanguage(for: question), settings: webSettings,
        budgetTokens: WebContext.budget(
          window: window, question: question, alongsideFileTokens: fileTokens, forRequest: plan.isRequest),
        firstIndex: firstIndex
      ) { status in
        self.preparingStatus = status
        BackgroundWork.shared.stepProgress(completed: 2, total: 4, subtitle: status)
      }
      BackgroundWork.shared.stepProgress(
        completed: 3, total: 4, subtitle: String(localized: "Writing answer…"))
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

  /// The plan for a Search message, and the planner's raw outputs. A follow-up that asks how two
  /// figures differ, planned as answered or as arithmetic, is planned again as a question or a
  /// request (``WebContext/replansAsQuestion(kind:question:history:)``). Without any output, the
  /// plan searches the message as typed.
  func planSearch(
    question: String, history: [(role: ChatRole, text: String)]
  ) async -> (plan: WebContext.Plan, outputs: [Data]) {
    let prompt = WebContext.queryPrompt(question: question, history: history)
    var outputs: [Data] = []
    for schema in [WebContext.querySchema, WebContext.searchingQuerySchema] {
      let output: Data? = await serialized {
        let output = try? await self.engine.helperJSON(
          prompt: prompt, schemaJSON: schema, maxOutputTokens: WebContext.queryMaxOutputTokens)
        await self.afterHelper()
        return output
      }
      guard let output else { break }
      outputs.append(output)
      let plan = WebContext.parsePlan(output)
      if schema == WebContext.searchingQuerySchema
        || !WebContext.replansAsQuestion(kind: plan.kind, question: question, history: history)
      {
        return (plan, outputs)
      }
    }
    return (outputs.last.map(WebContext.parsePlan) ?? WebContext.Plan(queries: [], isRequest: false), outputs)
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
      for card in findings.actionCards { ToolCardRecorder.record(card) }
      return findings.sources.isEmpty ? "No results." : WebContext.sourcesBlock(findings.sources)
    } catch {
      return "Web search failed: \(error.localizedDescription)"
    }
  }
}
