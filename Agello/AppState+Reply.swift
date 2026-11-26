import Foundation
import SwiftData

/// Files a message reads, a reply's stream, Stop, and the move to and from the background. Part of ``AppState``, split by area (2026-11-16).
extension AppState {
  // MARK: - Files

  struct FileContextResult {
    var prompt: String
    var sources: [SourceRecord]
    /// Whole files or summaries the conversation can keep: their key (``FileContext/heldKey(_:)``)
    /// and the prompt a follow-up sends while it holds them. nil for excerpts.
    var followUp: (key: String, prompt: String)?
  }

  /// The chat's own files, then its project's.
  func documents(for thread: ChatThread) -> [ChatDocument] {
    var documents = knowledge.documents(threadID: thread.id)
    if let projectID = thread.projectID { documents += knowledge.documents(projectID: projectID) }
    return documents
  }

  /// What the model reads for `question`: whole files when they fit half
  /// the context window; otherwise a section summary of long files (for
  /// "summarize"-style questions, cached on the document) or the most
  /// relevant excerpts with page labels. nil when stopped.
  func assembleFileContext(question: String, documents: [ChatDocument]) async
    -> FileContextResult?
  {
    let window = resolved?.maxNumTokens ?? 8_192
    let budget = FileContext.budget(window: window, question: question)
    var materials: [FileContext.Material] = []
    var sources: [SourceRecord] = []
    func cite(_ title: String, _ snippet: String? = nil) {
      sources.append(
        SourceRecord(index: sources.count + 1, title: title, url: nil, snippet: snippet))
    }

    let total = documents.reduce(0) { $0 + ContextBudget.estimateTokens($1.text) }
    var docNames: [String] = []
    if total <= budget {
      for document in documents {
        guard !document.isDeleted, document.modelContext != nil else { continue }
        materials.append(.full(name: document.name, pageCount: document.pageCount, text: document.text))
        cite(document.name)
        docNames.append(document.name)
      }
    } else if FileContext.wantsSummary(question) {
      let share = budget / documents.count
      let longDocuments = documents.filter {
        !$0.isDeleted && $0.modelContext != nil && ContextBudget.estimateTokens($0.text) > share && $0.summary == nil
      }
      if longDocuments.count > 1 {
        beginBackgroundWork(
          title: String(localized: "Synthesizing \(longDocuments.count) documents"),
          subtitle: String(localized: "Reading \(longDocuments[0].name)"),
          totalSteps: longDocuments.count)
      }
      var longIndex = 0
      for document in documents {
        guard !document.isDeleted, document.modelContext != nil else { continue }
        let docName = document.name
        let docPages = document.pageCount
        if ContextBudget.estimateTokens(document.text) <= share {
          materials.append(.full(name: docName, pageCount: docPages, text: document.text))
        } else {
          let needsWork = document.summary == nil
          let docIndex = needsWork ? longIndex : 0
          let docTotal = max(1, longDocuments.count)
          if needsWork { longIndex += 1 }
          guard let summary = await summary(
            of: document, documentIndex: docIndex, documentCount: docTotal)
          else { return nil }
          materials.append(
            .summary(
              name: docName, pageCount: docPages,
              text: FileContext.truncate(summary, tokens: share)))
        }
        cite(docName)
        docNames.append(docName)
      }
    } else {
      if documents.count > 1 {
        beginBackgroundWork(
          title: String(localized: "Researching \(documents.count) documents"),
          subtitle: String(localized: "Searching your files…"),
          totalSteps: 3)
      }
      preparingStatus = "Searching your files…"
      let liveDocs = documents.filter { !$0.isDeleted && $0.modelContext != nil }
      docNames = liveDocs.map(\.name)
      let passages = FileContext.fit(
        await knowledge.search(question, in: liveDocs, limit: 24), budget: budget)
      if Task.isCancelled { return nil }
      if documents.count > 1 {
        BackgroundWork.shared.stepProgress(
          completed: 2, total: 3, subtitle: String(localized: "Synthesizing findings…"))
      }
      materials.append(.excerpts(passages.map { (label: $0.citation, text: $0.text) }))
      for passage in passages { cite(passage.citation, String(passage.text.prefix(240))) }
    }
    return FileContextResult(
      prompt: FileContext.prompt(question: question, materials: materials), sources: sources,
      followUp: FileContext.heldKey(materials).map {
        ($0, FileContext.followUpPrompt(question: question, names: docNames))
      })
  }

  /// A long document's section-by-section summary, written once and cached.
  func summary(
    of document: ChatDocument, documentIndex: Int = 0, documentCount: Int = 1
  ) async -> String? {
    guard !document.isDeleted, document.modelContext != nil else { return nil }
    if let summary = document.summary { return summary }
    let chunks = document.chunks.sorted { $0.index < $1.index }.map {
      ChunkDraft(index: $0.index, text: $0.text, pageStart: $0.pageStart, pageEnd: $0.pageEnd)
    }
    let sections = FileContext.sections(chunks)
    let name = document.name
    let prompts = sections.map { FileContext.sectionPrompt($0, of: name) }
    let count = sections.count
    // Long document synthesis requests background GPU + inference time.
    if documentCount == 1 {
      beginBackgroundWork(
        title: String(localized: "Summarizing \(name)"),
        subtitle: String(localized: "Reading \(count) sections"),
        totalSteps: count)
    } else {
      configureBackgroundWorkHandlers()
      BackgroundWork.shared.update(
        subtitle: BackgroundWorkPlan.documentSubtitle(
          name: name, documentIndex: documentIndex, documentCount: documentCount,
          section: 1, totalSections: count))
    }
    preparingStatus =
      documentCount > 1
      ? "Document \(documentIndex + 1) of \(documentCount) · Reading \(name)…"
      : "Reading \(name)…"
    let result: Result<[String], Error> = await serialized {
      let result: Result<[String], Error>
      do {
        result = .success(
          try await self.engine.helperTexts(
            prompts, maxOutputTokens: FileContext.sectionSummaryTokens
          ) { done in
            await MainActor.run {
              self.preparingStatus = BackgroundWorkPlan.documentSubtitle(
                name: name, documentIndex: documentIndex, documentCount: documentCount,
                section: min(done + 1, count), totalSections: count)
              BackgroundWork.shared.documentSectionProgress(
                documentIndex: documentIndex, documentCount: documentCount,
                sectionCompleted: done, sectionTotal: count, documentName: name)
            }
          })
      } catch {
        result = .failure(error)
      }
      await self.afterHelper()
      return result
    }
    let outputs: [String]
    switch result {
    case .success(let value):
      outputs = value
    case .failure(let error):
      // Stopped: nothing to explain. Otherwise say why the files weren't read.
      if !Task.isCancelled, !(error is CancellationError), error as? ChatError != .generationCancelled {
        let reason = (error as? ChatError)?.displayMessage ?? error.localizedDescription
        generationError = String(localized: "Couldn't summarize \(name): \(reason)")
      }
      return nil
    }
    guard !Task.isCancelled, outputs.count == sections.count else { return nil }
    let summary = FileContext.joinSummaries(outputs, sections: sections)
    if !document.isDeleted, document.modelContext != nil {
      document.summary = summary
      try? modelContext?.save()
    }
    return summary
  }

  func consume(
    _ stream: AsyncThrowingStream<ChatEvent, Error>, into reply: ChatTurn, context: ModelContext,
    voiceTurn: ChatTurn? = nil
  ) async {
    // Stream into a plain accumulator and publish to the SwiftData model at
    // ~10 Hz: per-token model writes re-render (and re-parse markdown for)
    // the whole bubble 40-100 times a second.
    var accumulator = StreamAccumulator()
    // Preserve pre-send cards (e.g. Search ON Apple Maps) across mid-stream flushes.
    let initialActionCards = reply.parts.actionCards
    var lastFlush = ContinuousClock.now
    func flush(final: Bool = false) {
      let flushStarted = ContinuousClock.now
      defer { ReplyTrace.measure("chat write", since: flushStarted) }
      var voiceAnswerToNotify: String?
      if let voiceTurn {
        // "⟦what the user said⟧ answer": the transcript becomes the user's
        // message; the answer is shown and spoken.
        let split = VoiceText.split(accumulator.text)
        if let heard = split.heard, voiceTurn.text != heard {
          voiceTurn.text = heard
          if let thread = voiceTurn.thread, thread.title == Self.title(prompt: "", hasImage: voiceTurn.imageData != nil),
            thread.orderedTurns.first?.id == voiceTurn.id
          {
            thread.title = Self.title(prompt: heard, hasImage: false)
          }
        }
        reply.text = split.answer
        voiceAnswerToNotify = split.answer
      } else {
        reply.text = accumulator.text
      }
      reply.thought = accumulator.thought
      if reply.toolNames != accumulator.toolNames { reply.toolNames = accumulator.toolNames }
      let mergedCards = ActionCards.merge(initialActionCards, accumulator.actionCards)
      let currentParts = reply.parts
      if currentParts.toolActivity != accumulator.toolActivity || currentParts.actionCards != mergedCards {
        var parts = currentParts
        parts.toolActivity = accumulator.toolActivity
        parts.actionCards = mergedCards
        reply.parts = parts
      }
      if let voiceAnswerToNotify {
        onVoiceReply?(voiceAnswerToNotify, final)
      }
      lastFlush = .now
      BackgroundWork.shared.replyProgress(characters: reply.text.count)
    }
    toolStatus = nil
    defer { toolStatus = nil }
    var finished = false
    var toolSteps = 0
    do {
      for try await event in stream {
        switch event {
        case .chunk(let chunk):
          accumulator.append(chunk)
          if let latest = chunk.toolActivity.last, toolStatus != latest.summary {
            toolStatus = latest.summary
            toolSteps += 1
            if !BackgroundWork.shared.isPendingOrActive, options.enableThinking {
              beginBackgroundWork(
                title: String(localized: "Researching"),
                subtitle: latest.summary,
                totalSteps: 4)
            }
            BackgroundWork.shared.stepProgress(
              completed: toolSteps, total: max(toolSteps + 1, 4), subtitle: latest.summary)
          }
          if ContinuousClock.now - lastFlush >= ThermalPolicy.current.streamFlushInterval {
            flush()
            stopIfMemoryIsExhausted()
          }
        case .finished(let stats):
          reply.stats = stats
          if stats.reachedLimit == true { notice = GenerationStats.reachedLimitNotice }
          finished = true
        }
      }
      guard finished else {
        // The stream ended without finishing: this task was cancelled (voice mode closed,
        // the reply abandoned), which cancels the native conversation too.
        throw ChatError.generationCancelled
      }
      flush(final: true)
      try? context.save()
      Haptics.replyFinished(spoken: !voiceModeActive)
    } catch let error as ChatError {
      flush(final: true)
      switch error {
      case .generationCancelled, .replyTruncated:
        if case .replyTruncated = error { generationError = error.displayMessage }
        if reply.text.isEmpty {
          reply.thread?.removeLeaf(reply)
          context.delete(reply)
        } else if generationError != nil {
          reply.markIncomplete()  // cut short by the context or low memory, not by Stop
        }
        try? context.save()
        // LiteRT-LM leaves a cancelled conversation unusable: rebuild it from
        // the thread's history (incl. the partial reply) before the next send.
        conversationThreadID = nil
      case .contextFull, .messageTooLong:
        // Refused before any native work: the conversation is as it was.
        reply.text = reply.text.isEmpty ? ChatTurn.errorPrefix + error.displayMessage : reply.text
        try? context.save()
        Haptics.error()
      default:
        replyFailed(reply, error: error, message: error.displayMessage)
        try? context.save()
        Haptics.error()
        // The engine stopped a stream that failed mid-way: rebuild before the next send.
        conversationThreadID = nil
      }
    } catch {
      flush(final: true)
      replyFailed(reply, error: error, message: error.localizedDescription)
      try? context.save()
      Haptics.error()
      conversationThreadID = nil
    }
  }

  /// A failed reply keeps its text, marked incomplete and said so; with none, the error replaces it.
  func replyFailed(_ reply: ChatTurn, error: any Error, message: String) {
    Log.generation.error("reply failed: \(LogText.errorKind(error), privacy: .public)")
    guard !reply.text.isEmpty else { return reply.text = ChatTurn.errorPrefix + message }
    generationError = ChatError.stoppedEarly.displayMessage
    reply.markIncomplete()
  }

  func configureBackgroundWorkHandlers() {
    BackgroundWork.shared.onExpire = { [weak self] in await self?.stopAndDrain() }
    BackgroundWork.shared.onSubmissionFailure = { [weak self] in
      await self?.handleBackgroundWorkSubmissionFailure()
    }
  }

  func beginBackgroundWork(title: String, subtitle: String, totalSteps: Int = 1) {
    configureBackgroundWorkHandlers()
    BackgroundWork.shared.begin(title: title, subtitle: subtitle, totalSteps: totalSteps)
  }

  /// If `BGTaskScheduler` asynchronously rejects our continued task after the app already moved
  /// into the background, immediately close `GPUGate` and drain GPU under a short UIKit assertion.
  func handleBackgroundWorkSubmissionFailure() async {
    guard !isInForeground else { return }
    GPUGate.set(false)
    let drainGuard = BackgroundTaskGuard.begin(name: "AgelloGPUDrain")
    notice = String(localized: "Reply stopped because Agello moved to the background.")
    await stopAndDrain()
    drainGuard.end()
  }

  func stop() {
    cancelPendingToolConfirmation(reason: "Stopped by the user.")
    if BackgroundWork.shared.isPendingOrActive {
      stopCount &+= 1
      drainingBackgroundWork = true
      preparationTask?.cancel()
      webTask?.cancel()
      Task { await self.stopAndDrain() }
      return
    }
    stopCount &+= 1
    BackgroundWork.shared.end(success: false)
    preparationTask?.cancel()
    webTask?.cancel()
    Task { await engine.cancel() }
  }

  /// Cancels active work and waits for in-flight GPU work to drain before completing any
  /// continued processing task (keeps `.gpu` entitlement held during drain).
  func stopAndDrain() async {
    cancelPendingToolConfirmation(reason: "Stopped by the user.")
    ToolConfirmationGate.clearBatchGrants()
    pendingShortcutReturnName = nil
    ShortcutCallbackBroker.shared.cancelPending(reason: "Stopped by the user.")
    stopCount &+= 1
    drainingBackgroundWork = true
    if !isInForeground { GPUGate.set(false) }
    defer {
      drainingBackgroundWork = false
      BackgroundWork.shared.end(success: false)
      if !isInForeground { GPUGate.set(false) }
    }
    preparationTask?.cancel()
    webTask?.cancel()
    await engine.cancelAndDrain()
  }

  /// iOS doesn't allow GPU work in the background: stop a running reply
  /// deliberately (keeping the partial text) and drain native GPU threads
  /// under a UIKit background task assertion instead of letting Metal
  /// command buffers fail or the app be terminated.
  func enterBackground() {
    isInForeground = false
    ShortcutCallbackBroker.shared.setAppInForeground(false)
    applyOptionsTask?.cancel()
    cancelPendingToolConfirmation(reason: "Cancelled because Agello moved to the background.")
    // Outbound Shortcuts Bridge: user just approved an allowlisted Shortcut and iOS is switching
    // to Shortcuts. Close GPUGate immediately (zero background GPU submissions) while keeping the
    // parked generation alive (C++ engine is idle inside ToolManager.execute) until x-callback return.
    if ShortcutCallbackBroker.shared.hasPendingCallback {
      GPUGate.set(false)
      helperTimer?.cancel()
      if knowledge.usesGPUEmbedder { knowledge.cancelIndexing() }
      let handoffGuard = BackgroundTaskGuard.begin(name: "AgelloShortcutHandoff")
      Task {
        try? await Task.sleep(for: .milliseconds(400))
        handoffGuard.end()
      }
      Log.lifecycle.info("background: parked awaiting verified Shortcut callback (GPUGate closed)")
      return
    }
    // A continued task with background GPU access (submitted or running) lets the reply finish.
    let continuing = BackgroundWork.shared.isPendingOrActive
    GPUGate.set(continuing)
    if continuing {
      Log.lifecycle.info("background: work continues as a continued processing task")
      return
    }
    let drainGuard = BackgroundTaskGuard.begin(name: "AgelloGPUDrain")
    helperTimer?.cancel()
    if knowledge.usesGPUEmbedder { knowledge.cancelIndexing() }
    if isBusy {
      Log.lifecycle.info("background: stopping generation and draining GPU")
      stopCount &+= 1
      preparationTask?.cancel()
      webTask?.cancel()
      notice = String(localized: "Reply stopped because Agello moved to the background.")
    }
    // Cancels and drains either an active reply or a running helper before releasing the assertion.
    Task {
      await self.engine.cancelAndDrain()
      drainGuard.end()
    }
  }

  /// Back in the foreground: GPU work may start again.
  func enterForeground() {
    isInForeground = true
    ShortcutCallbackBroker.shared.setAppInForeground(true)
    GPUGate.set(true)
    // Flush any verified Shortcut callback buffered while the app was `.inactive` during onOpenURL.
    ShortcutCallbackBroker.shared.flushBufferedForForeground()
    if let pending = ShortcutCallbackBroker.shared.pendingSummary {
      let reqID = pending.requestID
      let name = pending.shortcutName
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(1_500))
        guard let self, self.isInForeground,
          ShortcutCallbackBroker.shared.pendingSummary?.requestID == reqID
        else { return }
        self.pendingShortcutReturnName = name
      }
    } else {
      pendingShortcutReturnName = nil
    }
    if pendingOptionsApply, !isBusy, !isBenchmarking {
      pendingOptionsApply = false
      Task { await self.applyCurrentOptions() }
    }
    knowledge.indexPendingIfAvailable()
    scheduleHelpers()
  }

  /// When `fitContext` trims older turns from the conversation, semantically recalls relevant
  /// earlier exchanges within the recall budget and verifies the combined prompt still fits.
  func promptWithEvictedRecall(
    promptToFit: String, query: String, imageData: Data?, audioFileURL: URL?,
    history: [(role: ChatRole, text: String)]
  ) async -> String {
    guard let window = resolved?.maxNumTokens else { return promptToFit }
    let evicted = await engine.lastEvictedHistory
    let recallBudget = ContextBudget.recallBudget(maxNumTokens: window)
    guard
      let recall = await knowledge.recallEvictedTurns(evicted, for: query, budget: recallBudget)
    else { return promptToFit }
    let candidate = ContextBudget.promptWithRecall(recall, prompt: promptToFit)
    let retrimmed = try? await engine.fitContext(
      text: candidate, imageData: imageData, audioFileURL: audioFileURL, history: history)
    return retrimmed == false ? candidate : promptToFit
  }
}
