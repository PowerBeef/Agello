import Foundation
import LiteRTLMTools
import SwiftData

/// On-device workspace tool wiring (`search_files`, `read_document_pages`, `search_past_chats`,
/// `query_table_or_json`). Part of ``AppState``, scoped to the active chat and its project.
extension AppState {
  /// Installs the `@Sendable` handlers read by workspace tools during replies.
  func installWorkspaceTools() {
    WorkspaceTools.searchFilesHandler = { [weak self] query, fileName, limit in
      guard let self else {
        return WorkspaceTools.FileSearchResult(
          matches: [], availableFiles: [], error: "Workspace is unavailable.")
      }
      return await self.toolSearchFiles(query: query, fileName: fileName, limit: limit)
    }
    WorkspaceTools.readDocumentPagesHandler = { [weak self] fileName, startPage, endPage in
      guard let self else {
        return WorkspaceTools.DocumentPageResult(
          fileName: fileName, isPaged: false, totalUnits: 0, start: startPage, end: startPage,
          content: "", error: "Workspace is unavailable.")
      }
      return await self.toolReadDocumentPages(fileName: fileName, startPage: startPage, endPage: endPage)
    }
    WorkspaceTools.searchPastChatsHandler = { [weak self] query, limit in
      guard let self else {
        return WorkspaceTools.PastChatSearchResult(matches: [], error: "Chat history is unavailable.")
      }
      return await self.toolSearchPastChats(query: query, limit: limit)
    }
    WorkspaceTools.lookupDocumentTextHandler = { [weak self] fileName in
      guard let self else { return nil }
      return await self.toolLookupDocumentText(fileName: fileName)
    }
  }

  /// Registers the fail-closed UI confirmation presenter for mutating tools (`isReadOnly == false`),
  /// the multi-step `PlanConfirmationCard` batch handler, and the `ShortcutCallbackBroker`
  /// foreground readiness check.
  func installToolConfirmationGate() {
    ToolConfirmationGate.installPresenter { [weak self] request in
      guard let self else {
        return .denied(reason: "Agello is unavailable; action was not executed.")
      }
      return await self.requestToolConfirmation(request)
    }
    ToolManager.setBatchConfirmHandler { invocations in
      await BatchConfirmationPlanner.confirmBatch(invocations)
    }
    ShortcutCallbackBroker.shared.setAppInForeground(isInForeground)
    ShortcutCallbackBroker.shared.setForegroundReadyCheck {
      GPUGate.isOpen
    }
  }

  /// Presents a pre-execution confirmation card in the active chat stream (or Voice Mode overlay)
  /// and suspends until the user approves, denies, stops the reply, or backgrounds the app.
  func requestToolConfirmation(_ request: ToolConfirmationRequest) async -> ToolConfirmationDecision {
    guard isInForeground, GPUGate.isOpen else {
      return .denied(reason: "Foreground confirmation is required before running \(request.toolName).")
    }
    if let expectedStops = activeGenerationStopCount, stopCount != expectedStops {
      return .denied(reason: "Stopped by the user.")
    }
    guard !Task.isCancelled else {
      return .denied(reason: "Cancelled before approval.")
    }
    // Fail-close any stale request before displaying the new one.
    cancelPendingToolConfirmation(reason: "Superseded by a new action.")
    let ownerThreadID = generatingThreadID ?? preparingThreadID ?? selectedThreadID
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled
          || (activeGenerationStopCount != nil && stopCount != activeGenerationStopCount)
          || !isInForeground || !GPUGate.isOpen
        {
          continuation.resume(returning: .denied(reason: "Cancelled before approval."))
          return
        }
        pendingToolConfirmation = request
        pendingToolConfirmationThreadID = ownerThreadID
        pendingToolConfirmationContinuation = continuation
        Haptics.selection()
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancelPendingToolConfirmation(id: request.id, reason: "Cancelled before approval.")
      }
    }
  }

  /// Resolves the inline confirmation card in the chat stream when the user taps Approve or Deny.
  /// When `id` is provided, ignores taps that race with a superseded request (TOCTOU protection).
  func resolvePendingToolConfirmation(id: UUID? = nil, approved: Bool) {
    resolvePendingToolConfirmation(
      id: id, decision: approved ? .approved : .denied(reason: "Denied by the user."))
  }

  /// Resolves a multi-step `PlanConfirmationCard` with the exact step indices checked by the user.
  func resolvePendingToolConfirmation(id: UUID? = nil, approvedSteps: Set<Int>) {
    let decision: ToolConfirmationDecision =
      approvedSteps.isEmpty
      ? .denied(reason: "No steps selected by the user.")
      : .approvedSteps(approvedSteps)
    resolvePendingToolConfirmation(id: id, decision: decision)
  }

  private func resolvePendingToolConfirmation(id: UUID?, decision: ToolConfirmationDecision) {
    if let id, pendingToolConfirmation?.id != id { return }
    guard let continuation = pendingToolConfirmationContinuation else {
      pendingToolConfirmation = nil
      pendingToolConfirmationThreadID = nil
      return
    }
    pendingToolConfirmation = nil
    pendingToolConfirmationThreadID = nil
    pendingToolConfirmationContinuation = nil
    continuation.resume(returning: decision)
  }

  /// Resolves an unresolved external Shortcut wait when the user returns manually without a callback.
  func continueWithoutShortcutCallback() {
    pendingShortcutReturnName = nil
    ShortcutCallbackBroker.shared.cancelPending(reason: "User continued without waiting for Shortcut.")
  }

  /// Cancels any pending confirmation card (or only the card matching `id`) with a fail-closed
  /// `.denied` decision.
  func cancelPendingToolConfirmation(id: UUID? = nil, reason: String) {
    if let id, pendingToolConfirmation?.id != id { return }
    guard let continuation = pendingToolConfirmationContinuation else {
      pendingToolConfirmation = nil
      pendingToolConfirmationThreadID = nil
      return
    }
    pendingToolConfirmation = nil
    pendingToolConfirmationThreadID = nil
    pendingToolConfirmationContinuation = nil
    continuation.resume(returning: .denied(reason: reason))
  }

  /// Documents visible to the currently generating or selected thread (thread files + project files).
  func activeWorkspaceDocuments() -> [ChatDocument] {
    guard let context = modelContext,
      let id = generatingThreadID ?? preparingThreadID ?? selectedThreadID
    else { return [] }
    let descriptor = FetchDescriptor<ChatThread>(predicate: #Predicate { $0.id == id })
    guard let thread = (try? context.fetch(descriptor))?.first else { return [] }
    return documents(for: thread)
  }

  private func toolSearchFiles(
    query: String, fileName: String?, limit: Int
  ) async -> WorkspaceTools.FileSearchResult {
    let allDocs = activeWorkspaceDocuments()
    let available = allDocs.map(\.name)
    guard !allDocs.isEmpty else {
      return WorkspaceTools.FileSearchResult(
        matches: [], availableFiles: [], error: "No files are attached to this chat or project.")
    }
    let scope: [ChatDocument]
    if let fileName, !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard let matched = WorkspaceTools.matchDocumentName(fileName, among: allDocs, name: \.name) else {
        return WorkspaceTools.FileSearchResult(
          matches: [], availableFiles: available,
          error: "File '\(fileName)' not found. Attached files: \(available.joined(separator: ", ")).")
      }
      scope = [matched]
    } else {
      scope = allDocs
    }

    let cappedLimit = max(1, min(10, limit))
    let passages = await knowledge.search(query, in: scope, limit: cappedLimit)
    let matches = passages.map { passage in
      WorkspaceTools.FileMatch(
        fileName: passage.documentName, citation: passage.citation, excerpt: passage.text)
    }
    // Record retrieved file excerpts as reply sources.
    let baseIndex = toolSourceOffset + WebSourcesRecorder.nextIndex
    let sourceRecords = passages.enumerated().map { offset, passage in
      SourceRecord(
        index: baseIndex + offset, title: passage.citation, url: nil,
        snippet: String(passage.text.prefix(240)))
    }
    WebSourcesRecorder.record(sourceRecords)
    return WorkspaceTools.FileSearchResult(matches: matches, availableFiles: available, error: nil)
  }

  private func toolReadDocumentPages(
    fileName: String, startPage: Int, endPage: Int?
  ) async -> WorkspaceTools.DocumentPageResult {
    let allDocs = activeWorkspaceDocuments()
    guard !allDocs.isEmpty else {
      return WorkspaceTools.DocumentPageResult(
        fileName: fileName, isPaged: false, totalUnits: 0, start: startPage, end: startPage,
        content: "", error: "No files are attached to this chat or project.")
    }
    guard let doc = WorkspaceTools.matchDocumentName(fileName, among: allDocs, name: \.name) else {
      let available = allDocs.map(\.name).joined(separator: ", ")
      return WorkspaceTools.DocumentPageResult(
        fileName: fileName, isPaged: false, totalUnits: 0, start: startPage, end: startPage,
        content: "", error: "File '\(fileName)' not found. Attached files: \(available).")
    }
    let result = WorkspaceTools.sliceDocument(
      name: doc.name, text: doc.text, pageCount: doc.pageCount, startPage: startPage, endPage: endPage)
    if result.error == nil {
      let label: String
      if result.isPaged {
        label = result.start == result.end
          ? "\(doc.name), p. \(result.start)"
          : "\(doc.name), pp. \(result.start)–\(result.end)"
      } else {
        label = "\(doc.name) (lines \(result.start)–\(result.end))"
      }
      let nextIdx = toolSourceOffset + WebSourcesRecorder.nextIndex
      WebSourcesRecorder.record([
        SourceRecord(index: nextIdx, title: label, url: nil, snippet: String(result.content.prefix(240)))
      ])
    }
    return result
  }

  private func toolLookupDocumentText(fileName: String) async -> WorkspaceTools.DocumentLookupResult? {
    let allDocs = activeWorkspaceDocuments()
    guard let doc = WorkspaceTools.matchDocumentName(fileName, among: allDocs, name: \.name) else {
      return nil
    }
    return WorkspaceTools.DocumentLookupResult(fileName: doc.name, text: doc.text)
  }

  private func toolSearchPastChats(
    query: String, limit: Int
  ) async -> WorkspaceTools.PastChatSearchResult {
    guard let context = modelContext else {
      return WorkspaceTools.PastChatSearchResult(matches: [], error: "Chat history is unavailable.")
    }
    let activeID = generatingThreadID ?? preparingThreadID ?? selectedThreadID
    let descriptor = FetchDescriptor<ChatThread>(
      sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
    let candidates = ((try? context.fetch(descriptor)) ?? [])
      .filter { $0.id != activeID && !$0.turns.isEmpty }
    guard !candidates.isEmpty else {
      return WorkspaceTools.PastChatSearchResult(matches: [], error: nil)
    }

    let cappedLimit = max(1, min(8, limit))
    // Index any unindexed past chats on ANE when ready, then combine semantic + BM25 keyword scores.
    knowledge.indexChats(candidates)
    let semanticScores = await knowledge.chatScores(query, in: candidates)
    let texts = candidates.map { KnowledgeBase.searchText(for: $0) }
    let keywordScores = KeywordScorer.scores(query: query, documents: texts)

    var ranked: [(thread: ChatThread, score: Double)] = []
    if !semanticScores.isEmpty {
      let keywordByID = Dictionary(
        uniqueKeysWithValues: zip(candidates.map(\.id), keywordScores))
      for entry in semanticScores {
        let kw = keywordByID[entry.thread.id] ?? 0
        // Require either meaningful semantic similarity or keyword overlap.
        let combined = Double(entry.score) + (kw > 0 ? 0.15 * min(kw, 5.0) : 0)
        if entry.score >= 0.35 || kw > 0 {
          ranked.append((entry.thread, combined))
        }
      }
      ranked.sort { $0.score > $1.score }
    }
    // Fall back to pure keyword matches when embeddings aren't available or matched nothing.
    if ranked.isEmpty {
      ranked = zip(candidates, keywordScores)
        .filter { $0.1 > 0 }
        .sorted { $0.1 > $1.1 }
        .map { ($0.0, $0.1) }
    }

    let matches = ranked.prefix(cappedLimit).map { item -> WorkspaceTools.PastChatMatch in
      let turns = item.thread.orderedTurns
        .filter { !$0.text.isEmpty && !$0.text.hasPrefix(ChatTurn.errorPrefix) }
      let snippet = bestSnippet(in: turns, query: query)
      return WorkspaceTools.PastChatMatch(
        title: item.thread.title,
        updatedAt: PromptText.date(item.thread.updatedAt),
        excerpt: snippet)
    }
    return WorkspaceTools.PastChatSearchResult(matches: matches, error: nil)
  }

  private func bestSnippet(in turns: [ChatTurn], query: String) -> String {
    guard !turns.isEmpty else { return "" }
    let formatted = turns.map { "\($0.isUser ? "User" : "Assistant"): \($0.text)" }
    let scores = KeywordScorer.scores(query: query, documents: formatted)
    let bestIndex = scores.enumerated().max { $0.element < $1.element }?.offset ?? 0
    let start = max(0, bestIndex - 1)
    let end = min(formatted.count - 1, bestIndex + 1)
    return formatted[start...end].joined(separator: "\n")
  }

  // MARK: - Composable AppIntents (Foreground Gemma 4 E4B)

  /// Runs a foreground plain-text prompt for composable Shortcuts (`AskAgelloForTextIntent`,
  /// `SummarizeDocumentIntent`) without disturbing an active chat's KV cache when memory allows.
  func runIntentText(prompt: String, maxOutputTokens: Int = 768) async throws -> String {
    guard isInForeground, GPUGate.isOpen else {
      throw ChatError.underlying(
        message: String(localized: "Agello must be open in the foreground to run this action."))
    }
    guard !isBusy, !isTranscribing else {
      throw ChatError.underlying(message: String(localized: "Agello is busy with another reply."))
    }
    let result: Result<String, Error> = await serialized {
      guard !self.isGenerating, !self.isPreparing else {
        return .failure(ChatError.underlying(message: String(localized: "Agello is busy with another reply.")))
      }
      guard await self.loadIfNeeded() else { return .failure(ChatError.engineNotReady) }
      let outcome: Result<String, Error>
      do {
        let outputs = try await self.engine.helperTexts([prompt], maxOutputTokens: maxOutputTokens) { _ in }
        outcome = .success(outputs.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
      } catch {
        outcome = .failure(error)
      }
      await self.afterHelper()
      return outcome
    }
    return try result.get()
  }

  /// Runs a JSON-Schema constrained foreground extraction (`ExtractStructuredDataIntent`) using
  /// `helperJSON` (`enable_thinking = false` + `llguidance` + `AGELLO_JSON_MTP`).
  func runIntentStructuredJSON(
    prompt: String, schemaJSON: String, maxOutputTokens: Int = 512
  ) async throws -> String {
    guard isInForeground, GPUGate.isOpen else {
      throw ChatError.underlying(
        message: String(localized: "Agello must be open in the foreground to run this action."))
    }
    guard !isBusy, !isTranscribing else {
      throw ChatError.underlying(message: String(localized: "Agello is busy with another reply."))
    }
    let result: Result<String, Error> = await serialized {
      guard !self.isGenerating, !self.isPreparing else {
        return .failure(ChatError.underlying(message: String(localized: "Agello is busy with another reply.")))
      }
      guard await self.loadIfNeeded() else { return .failure(ChatError.engineNotReady) }
      let outcome: Result<String, Error>
      do {
        let data = try await self.engine.helperJSON(
          prompt: prompt, schemaJSON: schemaJSON, maxOutputTokens: maxOutputTokens)
        outcome = .success(String(data: data, encoding: .utf8) ?? "{}")
      } catch {
        outcome = .failure(error)
      }
      await self.afterHelper()
      return outcome
    }
    return try result.get()
  }
}
