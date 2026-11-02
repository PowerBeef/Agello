import SwiftData
import SwiftUI

/// What the app's shell does, whatever its layout (the iPhone's drawer, the Mac's sidebar): carry
/// out requests from outside the app, start and pick chats, and hold the settings, project,
/// rename and delete state its sheets and dialogs show.
@MainActor
@Observable
final class ShellModel {
  var showSettings = false
  var openProject: Project?
  /// The chat being renamed, and the title being typed.
  var renaming: ChatThread?
  var renameText = ""
  /// The chat waiting for the delete confirmation.
  var deleting: ChatThread?

  @ObservationIgnored let appState: AppState
  @ObservationIgnored let context: ModelContext

  init(appState: AppState, context: ModelContext) {
    self.appState = appState
    self.context = context
  }

  // MARK: - Chats

  /// A new chat. Saved on the first message, so unused new chats never pile up.
  func newChat() {
    appState.newChatProjectID = nil
    appState.selectedThreadID = nil
  }

  func select(_ thread: ChatThread) {
    appState.newChatProjectID = nil
    appState.selectedThreadID = thread.id
  }

  func togglePin(_ thread: ChatThread) {
    thread.isPinned.toggle()
    try? context.save()
    Haptics.complete()
  }

  func startRename(_ thread: ChatThread) {
    renameText = thread.title
    renaming = thread
  }

  func commitRename() {
    let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let thread = renaming, !title.isEmpty else { return }
    thread.title = String(title.prefix(80))
    try? context.save()
  }

  func delete(_ thread: ChatThread) {
    appState.deleteThread(thread, in: context)
  }

  func move(_ thread: ChatThread, toProject projectID: UUID?) {
    appState.move(thread, toProject: projectID)
  }

  // MARK: - Projects

  func newProject() {
    openProject = appState.newProject(named: String(localized: "New project"), in: context)
  }

  /// A chat picked in the open project's sheet.
  func openChat(fromProject thread: ChatThread) {
    openProject = nil
    select(thread)
  }

  /// A new chat in `project`, from its sheet.
  func newChat(in project: Project) {
    openProject = nil
    appState.selectedThreadID = nil
    appState.newChatProjectID = project.id
  }

  func delete(_ project: Project) {
    appState.deleteProject(project, in: context)
  }

  // MARK: - Outside the app

  /// Items shared from other apps while Agello wasn't open.
  func answerSharedItems() {
    Task { await appState.answerSharedItems() }
  }

  /// Carry out a request from Siri, Shortcuts, widgets, Spotlight, or a link. Settings and a
  /// project close first; the shell also closes its own panels.
  func perform(_ action: AppRouter.Action) {
    showSettings = false
    openProject = nil
    switch action {
    case .newChat:
      newChat()
    case .voice:
      newChat()
      AppRouter.shared.voiceRequested = true
    case .openChat(let id):
      appState.newChatProjectID = nil
      if threadExists(id) { appState.selectedThreadID = id }
    case .ask(let question):
      guard !appState.isBusy else {
        appState.generationError = String(localized: "Finish or stop the current reply first.")
        return
      }
      newChat()
      let thread = appState.newThread(in: context)
      appState.selectedThreadID = thread.id
      Task { await appState.send(text: question, imageData: nil, audioFileURL: nil, in: thread) }
    case .draft(let text):
      newChat()
      AppRouter.shared.draftRequested = text
    }
  }

  private func threadExists(_ id: UUID) -> Bool {
    let descriptor = FetchDescriptor<ChatThread>(predicate: #Predicate { $0.id == id })
    return ((try? context.fetchCount(descriptor)) ?? 0) > 0
  }
}
