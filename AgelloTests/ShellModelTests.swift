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
    AppRouter.shared.voiceWithCameraRequested = false
    AppRouter.shared.cameraRequested = false
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
    shell.perform(.voiceWithCamera)
    XCTAssertNil(appState.selectedThreadID)
    XCTAssertTrue(AppRouter.shared.voiceWithCameraRequested)
    shell.select(thread)
    shell.perform(.snapAndAsk)
    XCTAssertNil(appState.selectedThreadID)
    XCTAssertTrue(AppRouter.shared.cameraRequested)
    shell.select(thread)
    shell.perform(.draft("Plan a trip"))
    XCTAssertNil(appState.selectedThreadID)
    XCTAssertEqual(AppRouter.shared.draftRequested, "Plan a trip")
  }

  func testOpenProjectAndOpenDocumentRouteToOwners() throws {
    shell.perform(.openProject(UUID()))
    XCTAssertNil(shell.openProject)

    let project = appState.newProject(named: "Budget", in: context)
    shell.perform(.openProject(project.id))
    XCTAssertEqual(shell.openProject?.id, project.id)

    let thread = appState.newThread(in: context)
    let chatDoc = ChatDocument(
      name: "receipt.pdf", kindRaw: DocumentKind.pdf.rawValue, byteCount: 512, pageCount: 1,
      text: "Total $42", threadID: thread.id)
    let projectDoc = ChatDocument(
      name: "plan.md", kindRaw: DocumentKind.text.rawValue, byteCount: 256, pageCount: 0,
      text: "Quarterly targets", projectID: project.id)
    context.insert(chatDoc)
    context.insert(projectDoc)
    try context.save()

    shell.perform(.openDocument(chatDoc.id))
    XCTAssertEqual(appState.selectedThreadID, thread.id)
    XCTAssertNil(shell.openProject)

    shell.perform(.openDocument(projectDoc.id))
    XCTAssertEqual(shell.openProject?.id, project.id)

    shell.perform(.openDocument(UUID()))
    XCTAssertNil(shell.openProject)
  }

  func testComposerBridgeCommandDeliveryIsIsolated() {
    let bridge = ComposerBridge()
    XCTAssertFalse(bridge.searchWeb)
    XCTAssertNil(bridge.takeRequest())
    bridge.send(.insertStarter("Explain how "))
    if case .insertStarter(let text) = bridge.takeRequest() {
      XCTAssertEqual(text, "Explain how ")
    } else {
      XCTFail("Expected insertStarter command")
    }
    XCTAssertNil(bridge.takeRequest(), "Command should be consumed once")
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
