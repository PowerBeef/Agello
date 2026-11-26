import SwiftData
import SwiftUI

/// What the app's shell does, whatever its layout (the iPhone's drawer): carry
/// out requests from outside the app, start and pick chats, and hold the settings, project,
/// rename and delete state its sheets and dialogs show.
@MainActor
@Observable
final class ShellModel {
  var showSettings = false
  var openProject: Project?
  /// Decided once at launch by `ContentView`, so finishing the download doesn't dismiss the
  /// welcome screen before "Start chatting".
  var presentOnboarding = false
  /// The chat being renamed, and the title being typed.
  var renaming: ChatThread?
  var renameText = ""
  /// The chat waiting for the delete confirmation.
  var deleting: ChatThread?
  /// Incremented whenever an external request must dismiss child covers (Voice Mode, Camera,
  /// Document Scanner) before presenting a follow-up modal.
  var dismissCoversToken = 0
  /// Whether a composer capture cover (`CameraPicker` / `DocumentScanner`) is active.
  var isPresentingCaptureCover = false

  @ObservationIgnored let appState: AppState
  @ObservationIgnored let context: ModelContext
  /// Queued follow-up presentation executed once active sheets/covers finish dismissing.
  @ObservationIgnored private var pendingAfterDismiss: (@MainActor () -> Void)?

  var hasPendingPresentation: Bool { pendingAfterDismiss != nil }

  init(appState: AppState, context: ModelContext) {
    self.appState = appState
    self.context = context
  }

  /// Called from `.sheet(..., onDismiss:)` and cover dismissals once a modal finishes tearing
  /// down, running any queued follow-up presentation cleanly.
  func handleModalDismissed() {
    guard !showSettings, openProject == nil, !presentOnboarding,
      !appState.voiceModeActive, !isPresentingCaptureCover
    else { return }
    guard let pending = pendingAfterDismiss else { return }
    pendingAfterDismiss = nil
    pending()
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
    thread.updatedAt = Date()
    try? context.save()
    SpotlightIndex.index([thread])
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

  /// Carry out a request from Siri, Shortcuts, widgets, Spotlight, or a link. Settings, a
  /// project, onboarding, dialogs, and active covers close first; follow-up sheets or covers
  /// wait for dismissal via `handleModalDismissed()` instead of racing SwiftUI presentation.
  func perform(_ action: AppRouter.Action) {
    renaming = nil
    deleting = nil
    pendingAfterDismiss = nil

    let wasPresentingVoice = appState.voiceModeActive
    let wasPresentingCapture = isPresentingCaptureCover
    let wasPresentingModal =
      showSettings || openProject != nil || presentOnboarding
      || wasPresentingVoice || wasPresentingCapture

    showSettings = false
    openProject = nil
    presentOnboarding = false
    if wasPresentingVoice || wasPresentingCapture {
      dismissCoversToken &+= 1
    }

    func afterModalDismissal(_ request: @escaping @MainActor () -> Void) {
      guard wasPresentingModal else {
        request()
        return
      }
      pendingAfterDismiss = request
    }

    switch action {
    case .newChat:
      newChat()
    case .voice:
      newChat()
      afterModalDismissal { AppRouter.shared.voiceRequested = true }
    case .voiceWithCamera:
      newChat()
      afterModalDismissal { AppRouter.shared.voiceWithCameraRequested = true }
    case .snapAndAsk:
      newChat()
      afterModalDismissal { AppRouter.shared.cameraRequested = true }
    case .openChat(let id):
      appState.newChatProjectID = nil
      if threadExists(id) {
        appState.selectedThreadID = id
      } else {
        appState.notice = String(localized: "That chat is no longer available.")
      }
    case .openProject(let id):
      if let project = project(withID: id) {
        afterModalDismissal { [weak self] in self?.openProject = project }
      } else {
        appState.notice = String(localized: "That project is no longer available.")
      }
    case .openDocument(let id):
      if let document = document(withID: id) {
        if let threadID = document.threadID, threadExists(threadID) {
          appState.newChatProjectID = nil
          appState.selectedThreadID = threadID
        } else if let projectID = document.projectID, let project = project(withID: projectID) {
          afterModalDismissal { [weak self] in self?.openProject = project }
        } else {
          appState.notice = String(localized: "That document is no longer available.")
        }
      } else {
        appState.notice = String(localized: "That document is no longer available.")
      }
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
      afterModalDismissal { AppRouter.shared.draftRequested = text }
    case .runRecipe(let id):
      guard let recipe = AutomationRegistry.shared.recipe(id: id) else {
        appState.notice = String(localized: "That recipe is no longer available.")
        return
      }
      newChat()
      afterModalDismissal { AppRouter.shared.draftRequested = recipe.prompt }
    }
  }

  private func threadExists(_ id: UUID) -> Bool {
    var descriptor = FetchDescriptor<ChatThread>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return ((try? context.fetchCount(descriptor)) ?? 0) > 0
  }

  private func project(withID id: UUID) -> Project? {
    var descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return try? context.fetch(descriptor).first
  }

  private func document(withID id: UUID) -> ChatDocument? {
    var descriptor = FetchDescriptor<ChatDocument>(predicate: #Predicate { $0.id == id })
    descriptor.fetchLimit = 1
    return try? context.fetch(descriptor).first
  }
}
