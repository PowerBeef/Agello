import Foundation
import SwiftData

/// Files a message reads, a reply's stream, Stop, and the move to and from the background. Part of ``AppState``, split by area (2026-11-16).
extension AppState {
  // MARK: - Files

  struct FileContextResult {
    var prompt: String
    var sources: [SourceRecord]
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
    if total <= budget {
      for document in documents {
        materials.append(.full(name: document.name, pageCount: document.pageCount, text: document.text))
        cite(document.name)
      }
    } else if FileContext.wantsSummary(question) {
      let share = budget / documents.count
      for document in documents {
        if ContextBudget.estimateTokens(document.text) <= share {
          materials.append(.full(name: document.name, pageCount: document.pageCount, text: document.text))
        } else {
          guard let summary = await summary(of: document) else { return nil }
          materials.append(
            .summary(
              name: document.name, pageCount: document.pageCount,
              text: FileContext.truncate(summary, tokens: share)))
        }
        cite(document.name)
      }
    } else {
      preparingStatus = "Searching your files…"
      let passages = FileContext.fit(
        await knowledge.search(question, in: documents, limit: 24), budget: budget)
      if Task.isCancelled { return nil }
      materials.append(.excerpts(passages.map { (label: $0.citation, text: $0.text) }))
      for passage in passages { cite(passage.citation, String(passage.text.prefix(240))) }
    }
    return FileContextResult(
      prompt: FileContext.prompt(question: question, materials: materials), sources: sources)
  }

  /// A long document's section-by-section summary, written once and cached.
  func summary(of document: ChatDocument) async -> String? {
    if let summary = document.summary { return summary }
    let chunks = document.chunks.sorted { $0.index < $1.index }.map {
      ChunkDraft(index: $0.index, text: $0.text, pageStart: $0.pageStart, pageEnd: $0.pageEnd)
    }
    let sections = FileContext.sections(chunks)
    let prompts = sections.map { FileContext.sectionPrompt($0, of: document.name) }
    let name = document.name
    let count = sections.count
    // Only long, user-requested file summaries request background GPU time.
    BackgroundWork.shared.onExpire = { [weak self] in self?.stop() }
    BackgroundWork.shared.begin(
      title: String(localized: "Summarizing \(name)"),
      subtitle: String(localized: "Reading \(count) sections"))
    preparingStatus = "Reading \(name)…"
    let result: Result<[String], Error> = await serialized {
      let result: Result<[String], Error>
      do {
        result = .success(
          try await self.engine.helperTexts(
            prompts, maxOutputTokens: FileContext.sectionSummaryTokens
          ) { done in
            await MainActor.run {
              self.preparingStatus = "Reading \(name) · part \(min(done + 1, count)) of \(count)"
              BackgroundWork.shared.sectionProgress(completed: done, total: count)
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
    document.summary = summary
    try? modelContext?.save()
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
    var lastFlush = ContinuousClock.now
    func flush(final: Bool = false) {
      let flushStarted = ContinuousClock.now
      defer { ReplyTrace.measure("chat write", since: flushStarted) }
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
        onVoiceReply?(split.answer, final)
      } else {
        reply.text = accumulator.text
      }
      reply.thought = accumulator.thought
      if reply.toolNames != accumulator.toolNames { reply.toolNames = accumulator.toolNames }
      if reply.parts.toolActivity != accumulator.toolActivity {
        var parts = reply.parts
        parts.toolActivity = accumulator.toolActivity
        reply.parts = parts
      }
      lastFlush = .now
      BackgroundWork.shared.replyProgress(characters: reply.text.count)
    }
    toolStatus = nil
    defer { toolStatus = nil }
    var finished = false
    do {
      for try await event in stream {
        switch event {
        case .chunk(let chunk):
          accumulator.append(chunk)
          if let latest = chunk.toolActivity.last { toolStatus = latest.summary }
          if ContinuousClock.now - lastFlush >= .milliseconds(100) {
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

  func stop() {
    stopCount &+= 1
    BackgroundWork.shared.end(success: false)
    preparationTask?.cancel()
    webTask?.cancel()
    Task { await engine.cancel() }
  }

  /// iOS doesn't allow GPU work in the background: stop a running reply
  /// deliberately (keeping the partial text) instead of letting Metal
  /// command buffers fail or the app be terminated.
  func enterBackground() {
    isInForeground = false
    // A continued task with background GPU access lets the reply finish.
    let continuing = BackgroundWork.shared.isActive
    GPUGate.set(continuing)
    if continuing {
      Log.lifecycle.info("background: work continues as a continued processing task")
      return
    }
    helperTimer?.cancel()
    knowledge.cancelIndexing()
    if isBusy {
      Log.lifecycle.info("background: stopping generation")
      stop()
      notice = String(localized: "Reply stopped because Agello moved to the background.")
    } else {
      // A title, memory or dictation helper: stopped, and queued work runs again on return.
      Task { await engine.cancel() }
    }
  }

  /// Back in the foreground: GPU work may start again.
  func enterForeground() {
    isInForeground = true
    GPUGate.set(true)
    knowledge.indexPendingIfAvailable()
    scheduleHelpers()
  }
}
