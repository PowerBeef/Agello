import SwiftData
import XCTest

@testable import Agello

/// The shell's actions, shared by the iPhone's drawer and the Mac's sidebar: requests from
/// outside the app, picking chats, renaming.
@MainActor
final class ShellModelTests: XCTestCase {
  private static let defaultsKeys = ["selectedThreadID"]
  private var savedDefaults: [String: Any] = [:]
  private var container: ModelContainer!
  private var appState: AppState!
  private var shell: ShellModel!
  private var context: ModelContext { container.mainContext }

  override func setUp() async throws {
    for key in Self.defaultsKeys {
      savedDefaults[key] = UserDefaults.standard.object(forKey: key)
      UserDefaults.standard.removeObject(forKey: key)
    }
    container = try ModelContainer(
      for: ChatStore.schema,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    appState = AppState(useMockEngine: true)
    appState.modelContext = container.mainContext
    shell = ShellModel(appState: appState, context: container.mainContext)
  }

  override func tearDown() async throws {
    AppRouter.shared.voiceRequested = false
    AppRouter.shared.draftRequested = nil
    shell = nil
    appState = nil
    container = nil
    for key in Self.defaultsKeys {
      if let value = savedDefaults[key] {
        UserDefaults.standard.set(value, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
  }

  /// Every request closes Settings and the open project first.
  func testRequestsCloseSettingsAndTheProject() {
    shell.showSettings = true
    shell.openProject = appState.newProject(named: "Trip", in: context)
    shell.perform(.newChat)
    XCTAssertFalse(shell.showSettings)
    XCTAssertNil(shell.openProject)
  }

  /// A Spotlight result or a link opens a chat that exists, and nothing else.
  func testOpenChatSelectsOnlyAKnownChat() {
    shell.perform(.openChat(UUID()))
    XCTAssertNil(appState.selectedThreadID)
    let thread = appState.newThread(in: context)
    appState.newChatProjectID = UUID()
    shell.perform(.openChat(thread.id))
    XCTAssertEqual(appState.selectedThreadID, thread.id)
    XCTAssertNil(appState.newChatProjectID)
  }

  func testVoiceAndDraftRequestsStartANewChat() {
    let thread = appState.newThread(in: context)
    shell.select(thread)
    shell.perform(.voice)
    XCTAssertNil(appState.selectedThreadID)
    XCTAssertTrue(AppRouter.shared.voiceRequested)
    shell.select(thread)
    shell.perform(.draft("Plan a trip"))
    XCTAssertNil(appState.selectedThreadID)
    XCTAssertEqual(AppRouter.shared.draftRequested, "Plan a trip")
  }

  /// "Ask Agello" from Siri or Shortcuts sends the question in a chat of its own.
  func testAskSendsTheQuestionInANewChat() async throws {
    shell.perform(.ask("What's 2 + 2?"))
    let id = try XCTUnwrap(appState.selectedThreadID)
    let thread = try XCTUnwrap(try context.fetch(FetchDescriptor<ChatThread>()).first { $0.id == id })
    // The send runs in a task of its own: wait for the mock's reply.
    for _ in 0..<200 where thread.orderedTurns.count < 2 || appState.isGenerating {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(thread.orderedTurns.first?.text, "What's 2 + 2?")
  }

  func testNewChatInAProjectFromItsSheet() {
    let project = appState.newProject(named: "Trip", in: context)
    shell.openProject = project
    shell.select(appState.newThread(in: context))
    shell.newChat(in: project)
    XCTAssertNil(shell.openProject)
    XCTAssertNil(appState.selectedThreadID)
    XCTAssertEqual(appState.newChatProjectID, project.id)
  }

  /// Titles are trimmed and kept to 80 characters; a blank one changes nothing.
  func testRenameTrimsAndKeepsEightyCharacters() {
    let thread = appState.newThread(in: context)
    thread.title = "Old"
    shell.startRename(thread)
    XCTAssertEqual(shell.renameText, "Old")
    shell.renameText = "   "
    shell.commitRename()
    XCTAssertEqual(thread.title, "Old")
    shell.renameText = "  " + String(repeating: "a", count: 100) + "  "
    shell.commitRename()
    XCTAssertEqual(thread.title, String(repeating: "a", count: 80))
  }
}
