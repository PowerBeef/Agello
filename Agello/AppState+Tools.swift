import Foundation
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

  /// Registers the fail-closed UI confirmation presenter for mutating tools (`isReadOnly == false`).
  func installToolConfirmationGate() {
    ToolConfirmationGate.installPresenter { [weak self] request in
      guard let self else {
        return .denied(reason: "Agello is unavailable; action was not executed.")
      }
      return await self.requestToolConfirmation(request)
    }
  }

  /// Presents a pre-execution confirmation card in the active chat stream and suspends
  /// until the user approves, denies, stops the reply, or backgrounds the app.
  func requestToolConfirmation(_ request: ToolConfirmationRequest) async -> ToolConfirmationDecision {
    guard isInForeground, GPUGate.isOpen else {
      return .denied(reason: "Foreground confirmation is required before running \(request.toolName).")
    }
    // Fail-close any stale request before displaying the new one.
    cancelPendingToolConfirmation(reason: "Superseded by a new action.")
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        pendingToolConfirmation = request
        pendingToolConfirmationContinuation = continuation
        Haptics.selection()
      }
    } onCancel: {
      Task { @MainActor [weak self] in
        self?.cancelPendingToolConfirmation(reason: "Cancelled before approval.")
      }
    }
  }

  /// Resolves the inline confirmation card in the chat stream when the user taps Approve or Deny.
  func resolvePendingToolConfirmation(approved: Bool) {
    guard let continuation = pendingToolConfirmationContinuation else {
      pendingToolConfirmation = nil
      return
    }
    pendingToolConfirmation = nil
    pendingToolConfirmationContinuation = nil
    continuation.resume(
      returning: approved ? .approved : .denied(reason: "Denied by the user."))
  }

  /// Cancels any pending confirmation card with a fail-closed `.denied` decision.
  func cancelPendingToolConfirmation(reason: String) {
    guard let continuation = pendingToolConfirmationContinuation else {
      pendingToolConfirmation = nil
      return
    }
    pendingToolConfirmation = nil
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
}
