import AppIntents
import CoreSpotlight
import SwiftData
import XCTest

@testable import Agello

final class AppRouterTests: XCTestCase {
  func testDeepLinks() {
    XCTAssertEqual(AppRouter.action(for: URL(string: "agello://new")!), .newChat)
    XCTAssertEqual(AppRouter.action(for: URL(string: "AGELLO://Voice")!), .voice)
    XCTAssertEqual(AppRouter.action(for: URL(string: "agello://voice-camera")!), .voiceWithCamera)
    XCTAssertEqual(AppRouter.action(for: URL(string: "agello://camera")!), .snapAndAsk)
    // Any page can open a link: it fills the composer, it never sends.
    XCTAssertEqual(
      AppRouter.action(for: URL(string: "agello://ask?q=What%20is%20Canberra%3F")!),
      .draft("What is Canberra?"))
    XCTAssertEqual(AppRouter.action(for: URL(string: "agello://ask")!), .newChat)
    let id = UUID()
    XCTAssertEqual(AppRouter.action(for: URL(string: "agello://chat/\(id.uuidString)")!), .openChat(id))
    XCTAssertEqual(
      AppRouter.action(for: URL(string: "agello://project/\(id.uuidString)")!), .openProject(id))
    XCTAssertEqual(
      AppRouter.action(for: URL(string: "agello://document/\(id.uuidString)")!), .openDocument(id))
    XCTAssertNil(AppRouter.action(for: URL(string: "agello://chat/not-a-uuid")!))
    XCTAssertNil(AppRouter.action(for: URL(string: "agello://project/not-a-uuid")!))
    XCTAssertNil(AppRouter.action(for: URL(string: "agello://document/not-a-uuid")!))
    XCTAssertNil(AppRouter.action(for: URL(string: "https://new")!))
    XCTAssertNil(AppRouter.action(for: URL(string: "agello://unknown")!))
  }

  func testURLsRoundTrip() {
    for action: AppRouter.Action in [
      .newChat, .voice, .voiceWithCamera, .snapAndAsk, .draft("Hi & bye?"),
      .openChat(UUID()), .openProject(UUID()), .openDocument(UUID()),
    ] {
      XCTAssertEqual(AppRouter.action(for: AppRouter.url(for: action)), action)
    }
    XCTAssertEqual(AppRouter.action(for: AppRouter.url(for: .ask("Hi"))), .draft("Hi"))
  }

  @MainActor
  func testIntentsHandOffToTheApp() async throws {
    // The host app's chat screen carries requests out as they arrive, so
    // check what the router received rather than what's still pending.
    let router = AppRouter.shared
    XCTAssertEqual(AskAgelloIntent.authenticationPolicy, .requiresAuthentication)
    XCTAssertEqual(StartVoiceModeIntent.authenticationPolicy, .requiresAuthentication)
    XCTAssertEqual(NewChatIntent.authenticationPolicy, .requiresAuthentication)
    XCTAssertEqual(SnapAndAskIntent.authenticationPolicy, .requiresAuthentication)
    XCTAssertEqual(VoiceWithCameraIntent.authenticationPolicy, .requiresAuthentication)
    XCTAssertEqual(OpenChatIntent.authenticationPolicy, .requiresAuthentication)
    XCTAssertEqual(OpenProjectIntent.authenticationPolicy, .requiresAuthentication)
    XCTAssertEqual(OpenDocumentIntent.authenticationPolicy, .requiresAuthentication)

    let ask = AskAgelloIntent()
    ask.question = "Hello"
    _ = try await ask.perform()
    XCTAssertEqual(router.lastHandled, .ask("Hello"))
    _ = try await StartVoiceModeIntent().perform()
    XCTAssertEqual(router.lastHandled, .voice)
    _ = try await NewChatIntent().perform()
    XCTAssertEqual(router.lastHandled, .newChat)
    _ = try await SnapAndAskIntent().perform()
    XCTAssertEqual(router.lastHandled, .snapAndAsk)
    _ = try await VoiceWithCameraIntent().perform()
    XCTAssertEqual(router.lastHandled, .voiceWithCamera)

    let chatID = UUID()
    let openChat = OpenChatIntent()
    openChat.target = ChatEntity(id: chatID, title: "Notes", snippet: "Hi", updatedAt: .now)
    _ = try await openChat.perform()
    XCTAssertEqual(router.lastHandled, .openChat(chatID))

    let projectID = UUID()
    let openProject = OpenProjectIntent()
    openProject.target = ProjectEntity(
      id: projectID, name: "Travel", instructions: "Use trains", updatedAt: .now)
    _ = try await openProject.perform()
    XCTAssertEqual(router.lastHandled, .openProject(projectID))

    let docID = UUID()
    let openDoc = OpenDocumentIntent()
    openDoc.target = DocumentEntity(
      id: docID, name: "report.pdf", kindRaw: "pdf", pageCount: 12, snippet: "Summary",
      createdAt: .now)
    _ = try await openDoc.perform()
    XCTAssertEqual(router.lastHandled, .openDocument(docID))
  }
}

@MainActor
final class AppEntitiesTests: XCTestCase {
  private var savedContainer: ModelContainer?
  private var container: ModelContainer!

  override func setUp() async throws {
    savedContainer = AppEntityStore.container
    container = try ModelContainer(
      for: ChatStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    AppEntityStore.container = container
  }

  override func tearDown() async throws {
    AppEntityStore.container = savedContainer
    container = nil
  }

  func testChatProjectAndDocumentQueriesResolveAndMatch() async throws {
    let context = container.mainContext
    let project = Project(name: "Kyoto Trip")
    project.instructions = "Prefer bullet trains and quiet shrines."
    context.insert(project)

    let thread = ChatThread(title: "Day 1 itinerary")
    thread.projectID = project.id
    thread.append(ChatTurn(role: .user, text: "Best morning hike?"))
    thread.append(ChatTurn(role: .model, text: "Fushimi Inari before 7am."))
    context.insert(thread)

    let emptyThread = ChatThread(title: "Empty draft")
    context.insert(emptyThread)

    let doc = ChatDocument(
      name: "rail-pass.pdf", kindRaw: DocumentKind.pdf.rawValue, byteCount: 2048, pageCount: 4,
      text: "JR Pass covers Shinkansen Hikari and Sakura lines.", projectID: project.id)
    context.insert(doc)
    try context.save()

    let chatQuery = ChatEntityQuery()
    let foundChats = try await chatQuery.entities(matching: "Fushimi")
    XCTAssertEqual(foundChats.map(\.id), [thread.id])
    XCTAssertEqual(foundChats.first?.projectName, "Kyoto Trip")
    XCTAssertEqual(foundChats.first?.attributeSet.title, "Day 1 itinerary")
    let suggestedChats = try await chatQuery.suggestedEntities()
    XCTAssertEqual(suggestedChats.map(\.id), [thread.id], "Empty chats stay out of suggestions")

    let projectQuery = ProjectEntityQuery()
    let foundProjects = try await projectQuery.entities(matching: "shrines")
    XCTAssertEqual(foundProjects.map(\.id), [project.id])
    let resolvedProjects = try await projectQuery.entities(for: [project.id])
    XCTAssertEqual(resolvedProjects.first?.name, "Kyoto Trip")
    XCTAssertEqual(foundProjects.first?.attributeSet.title, "Kyoto Trip")

    let docQuery = DocumentEntityQuery()
    let foundDocs = try await docQuery.entities(matching: "Shinkansen")
    XCTAssertEqual(foundDocs.map(\.id), [doc.id])
    XCTAssertEqual(foundDocs.first?.pageCount, 4)
    XCTAssertEqual(foundDocs.first?.attributeSet.pageCount, 4)
    let resolvedDocs = try await docQuery.entities(for: [doc.id])
    XCTAssertEqual(resolvedDocs.first?.name, "rail-pass.pdf")
  }
}

@MainActor
final class SpotlightTests: XCTestCase {
  func testEntryUsesTitleQuestionAndLatestReply() throws {
    let container = try ModelContainer(
      for: ChatStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let thread = ChatThread(title: "Kyoto trip")
    container.mainContext.insert(thread)
    XCTAssertNil(SpotlightIndex.entry(for: thread), "Empty chats aren't indexed")
    thread.append(ChatTurn(role: .user, text: "Plan three days\nin Kyoto"))
    thread.append(ChatTurn(role: .model, text: ChatTurn.errorPrefix + "boom"))
    thread.append(ChatTurn(role: .model, text: "Day 1: Fushimi Inari."))
    let entry = try XCTUnwrap(SpotlightIndex.entry(for: thread))
    XCTAssertEqual(entry.id, thread.id)
    XCTAssertEqual(entry.title, "Kyoto trip")
    XCTAssertEqual(entry.snippet, "Plan three days in Kyoto — Day 1: Fushimi Inari.")
    let item = SpotlightIndex.item(for: entry)
    XCTAssertEqual(item.uniqueIdentifier, thread.id.uuidString)
    XCTAssertEqual(item.attributeSet.title, "Kyoto trip")
  }

  func testProjectAndDocumentEntriesAndActivities() throws {
    let container = try ModelContainer(
      for: ChatStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let project = Project(name: "Research")
    project.instructions = "Cite page numbers."
    container.mainContext.insert(project)

    let projectEntry = SpotlightIndex.projectEntry(for: project)
    let projectItem = SpotlightIndex.item(for: projectEntry)
    XCTAssertEqual(projectItem.domainIdentifier, SpotlightIndex.projectDomain)
    XCTAssertEqual(projectItem.attributeSet.title, "Research")

    let projectActivity = NSUserActivity(activityType: CSSearchableItemActionType)
    projectActivity.userInfo = [CSSearchableItemActivityIdentifier: projectItem.uniqueIdentifier]
    XCTAssertEqual(SpotlightIndex.action(from: projectActivity), .openProject(project.id))

    let doc = ChatDocument(
      name: "q3.pdf", kindRaw: DocumentKind.pdf.rawValue, byteCount: 4096, pageCount: 10,
      text: "Revenue grew 14% year over year.", projectID: project.id)
    container.mainContext.insert(doc)
    let docEntry = SpotlightIndex.documentEntry(for: doc)
    let docItem = SpotlightIndex.item(for: docEntry)
    XCTAssertEqual(docItem.domainIdentifier, SpotlightIndex.documentDomain)
    XCTAssertEqual(docItem.attributeSet.pageCount, 10)

    let docActivity = NSUserActivity(activityType: CSSearchableItemActionType)
    docActivity.userInfo = [CSSearchableItemActivityIdentifier: docItem.uniqueIdentifier]
    XCTAssertEqual(SpotlightIndex.action(from: docActivity), .openDocument(doc.id))
  }

  /// A launch indexes only the chats changed since the last refresh; turning Spotlight on
  /// indexes them all.
  func testLaunchIndexesOnlyChangedChats() throws {
    let container = try ModelContainer(
      for: ChatStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = container.mainContext
    let old = ChatThread(title: "Old")
    old.updatedAt = Date(timeIntervalSinceNow: -3_600)
    let recent = ChatThread(title: "Recent")
    recent.updatedAt = Date()
    context.insert(old)
    context.insert(recent)
    let since = Date(timeIntervalSinceNow: -60)
    XCTAssertEqual(SpotlightIndex.threadsToIndex(in: context, changedSince: since).map(\.title), ["Recent"])
    XCTAssertEqual(
      SpotlightIndex.threadsToIndex(in: context, changedSince: nil).map(\.title), ["Recent", "Old"])
  }

  func testResultOpensTheChat() {
    let id = UUID()
    let activity = NSUserActivity(activityType: CSSearchableItemActionType)
    activity.userInfo = [CSSearchableItemActivityIdentifier: id.uuidString]
    XCTAssertEqual(SpotlightIndex.chatID(from: activity), id)
    XCTAssertEqual(SpotlightIndex.action(from: activity), .openChat(id))
  }
}
