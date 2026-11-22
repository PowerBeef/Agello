import Foundation
import SwiftData

/// Chats, memory and projects. Part of ``AppState``, split by area (2026-11-16).
extension AppState {
  // MARK: - Threads

  func newThread(in context: ModelContext) -> ChatThread {
    let thread = ChatThread(modelID: store.activeModelID)
    context.insert(thread)
    try? context.save()
    // The native conversation is re-pointed when the chat is opened
    // (``activate(_:)``), not here.
    return thread
  }

  /// Delete saved chats without messages (a rejected first message), except the open one and
  /// a busy one: a new chat has no turns until its first message is prepared (2026-11-16).
  func pruneEmptyThreads() {
    guard let context = modelContext,
      let threads = try? context.fetch(FetchDescriptor<ChatThread>())
    else { return }
    let busy: Set<UUID> = Set([selectedThreadID, preparingThreadID, generatingThreadID].compactMap { $0 })
    let empty = threads.filter { $0.turns.isEmpty && !busy.contains($0.id) }
    guard !empty.isEmpty else { return }
    for thread in empty {
      if conversationThreadID == thread.id { conversationThreadID = nil }
      knowledge.deleteDocuments(threadID: thread.id)
      context.delete(thread)
    }
    try? context.save()
  }

  // MARK: - Memory

  /// The memories added to the system prompt: the chat's own choice (``selectMemories``) when it
  /// has one, else the most recent.
  func memoryTexts() -> [String] {
    if let memorySelection, memorySelection.threadID == selectedThreadID { return memorySelection.texts }
    return recentMemoryTexts(limit: SystemPrompt.memoryLimit)
  }

  private func recentMemoryTexts(limit: Int) -> [String] {
    var descriptor = FetchDescriptor<MemoryItem>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
    descriptor.fetchLimit = limit
    return ((try? modelContext?.fetch(descriptor)) ?? []).map(\.text)
  }

  /// With more memories than the system prompt holds, `thread` gets the most recent
  /// (``SystemPrompt/recentMemories``) and then those closest in meaning to its first message,
  /// chosen once so the chat's system prompt, and its cache, stay put while it goes on. Without
  /// the embedder (not downloaded, or in the background) the most recent are used.
  func selectMemories(for thread: ChatThread, firstMessage: String) async {
    guard memoryEnabled, memorySelection?.threadID != thread.id, GPUGate.isOpen else { return }
    let all = recentMemoryTexts(limit: SystemPrompt.memoryCandidateLimit)
    guard all.count > SystemPrompt.memoryLimit else { return }
    let recent = Array(all.prefix(SystemPrompt.recentMemories))
    let older = Array(all.dropFirst(SystemPrompt.recentMemories))
    let query = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let ranked = await knowledge.rank(older, against: query) else { return }
    memorySelection = (thread.id, recent + ranked.prefix(SystemPrompt.memoryLimit - recent.count))
  }

  /// Memories were added, edited or deleted (or memory was switched): the
  /// open conversation picks them up before the next message.
  func memoriesChanged() {
    memorySelection = nil
    conversationThreadID = nil
  }

  /// Save lasting facts from the user's message (memory on, and only when the message is
  /// about the user). Returns false when it must be tried again later.
  @discardableResult
  func learnMemories(from message: String, reply: ChatTurn, in thread: ChatThread) async -> Bool {
    guard memoryEnabled, HelperTasks.shouldLookForMemories(message), !reply.text.isEmpty,
      !reply.text.hasPrefix(ChatTurn.errorPrefix), let context = modelContext
    else { return true }
    let all = ((try? context.fetch(FetchDescriptor<MemoryItem>())) ?? []).map(\.text)
    let prompt = HelperTasks.memoryPrompt(user: message, existing: all)
    let outcome: HelperOutcome<Data> = await runHelper { engine in
      try await engine.helperJSON(
        prompt: prompt, schemaJSON: HelperTasks.memorySchema,
        maxOutputTokens: HelperTasks.memoryMaxOutputTokens)
    }
    guard case .finished(let output) = outcome else { return false }
    guard let output else { return true }
    let learned = HelperTasks.newMemories(HelperTasks.parseMemories(output), existing: all)
    guard !learned.isEmpty else { return true }
    for text in learned { context.insert(MemoryItem(text: text, sourceThreadID: thread.id)) }
    var parts = reply.parts
    parts.toolActivity.append(
      ToolActivityRecord(name: "memory", summary: learned.joined(separator: " · ")))
    reply.parts = parts
    try? context.save()
    Log.engine.info("memory: saved \(learned.count)")
    memoriesChanged()
    return true
  }

  // MARK: - Projects

  func projectContext(for threadID: UUID) -> ProjectContext? {
    guard let context = modelContext else { return nil }
    let thread = try? context.fetch(
      FetchDescriptor<ChatThread>(predicate: #Predicate { $0.id == threadID })
    ).first
    // A new chat started from a project page isn't saved yet.
    guard let projectID = thread?.projectID ?? (thread == nil ? newChatProjectID : nil) else {
      return nil
    }
    guard
      let project = try? context.fetch(
        FetchDescriptor<Project>(predicate: #Predicate { $0.id == projectID })
      ).first
    else { return nil }
    return ProjectContext(id: project.id, name: project.name, instructions: project.instructions)
  }

  /// A project's instructions or name changed: its open chat picks them up
  /// before the next message.
  func projectInstructionsChanged(_ projectID: UUID) {
    if activeProject?.id == projectID { conversationThreadID = nil }
  }

  @discardableResult
  func newProject(named name: String, in context: ModelContext) -> Project {
    let project = Project(name: name)
    context.insert(project)
    try? context.save()
    SpotlightIndex.indexProjects([project])
    return project
  }

  /// Move a chat into a project (or out, with nil).
  func move(_ thread: ChatThread, toProject projectID: UUID?) {
    thread.projectID = projectID
    try? modelContext?.save()
    if conversationThreadID == thread.id { conversationThreadID = nil }
  }

  /// Delete a project with its chats and files.
  func deleteProject(_ project: Project, in context: ModelContext) {
    let projectID = project.id
    let chats = (try? context.fetch(
      FetchDescriptor<ChatThread>(predicate: #Predicate { $0.projectID == projectID }))) ?? []
    for thread in chats {
      // The chat replying now stays, out of the project, rather than pointing at nothing.
      if generatingThreadID == thread.id || preparingThreadID == thread.id {
        thread.projectID = nil
      } else {
        deleteThread(thread, in: context)
      }
    }
    for document in knowledge.documents(projectID: projectID) { knowledge.delete(document) }
    if newChatProjectID == projectID { newChatProjectID = nil }
    if activeProject?.id == projectID {
      activeProject = nil
      conversationThreadID = nil
    }
    SpotlightIndex.removeProjects([projectID])
    context.delete(project)
    try? context.save()
  }

  func deleteThread(_ thread: ChatThread, in context: ModelContext) {
    // As in the interface: a busy chat's message would land in a deleted chat.
    guard thread.id != preparingThreadID, thread.id != generatingThreadID else { return }
    if selectedThreadID == thread.id { selectedThreadID = nil }
    if conversationThreadID == thread.id { conversationThreadID = nil }
    knowledge.deleteDocuments(threadID: thread.id)
    SpotlightIndex.remove([thread.id])
    context.delete(thread)
    try? context.save()
  }
}
