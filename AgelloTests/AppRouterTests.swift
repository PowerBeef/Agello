import CoreSpotlight
import SwiftData
import XCTest

@testable import Agello

final class AppRouterTests: XCTestCase {
  func testDeepLinks() {
    XCTAssertEqual(AppRouter.action(for: URL(string: "agello://new")!), .newChat)
    XCTAssertEqual(AppRouter.action(for: URL(string: "AGELLO://Voice")!), .voice)
    // Any page can open a link: it fills the composer, it never sends.
    XCTAssertEqual(
      AppRouter.action(for: URL(string: "agello://ask?q=What%20is%20Canberra%3F")!),
      .draft("What is Canberra?"))
    XCTAssertEqual(AppRouter.action(for: URL(string: "agello://ask")!), .newChat)
    let id = UUID()
    XCTAssertEqual(AppRouter.action(for: URL(string: "agello://chat/\(id.uuidString)")!), .openChat(id))
    XCTAssertNil(AppRouter.action(for: URL(string: "agello://chat/not-a-uuid")!))
    XCTAssertNil(AppRouter.action(for: URL(string: "https://new")!))
    XCTAssertNil(AppRouter.action(for: URL(string: "agello://unknown")!))
  }

  func testURLsRoundTrip() {
    for action: AppRouter.Action in [.newChat, .voice, .draft("Hi & bye?"), .openChat(UUID())] {
      XCTAssertEqual(AppRouter.action(for: AppRouter.url(for: action)), action)
    }
    XCTAssertEqual(AppRouter.action(for: AppRouter.url(for: .ask("Hi"))), .draft("Hi"))
  }

  @MainActor
  func testIntentsHandOffToTheApp() async throws {
    // The host app's chat screen carries requests out as they arrive, so
    // check what the router received rather than what's still pending.
    let router = AppRouter.shared
    var ask = AskAgelloIntent()
    ask.question = "Hello"
    _ = try await ask.perform()
    XCTAssertEqual(router.lastHandled, .ask("Hello"))
    _ = try await StartVoiceModeIntent().perform()
    XCTAssertEqual(router.lastHandled, .voice)
    _ = try await NewChatIntent().perform()
    XCTAssertEqual(router.lastHandled, .newChat)
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

  func testResultOpensTheChat() {
    let id = UUID()
    let activity = NSUserActivity(activityType: CSSearchableItemActionType)
    activity.userInfo = [CSSearchableItemActivityIdentifier: id.uuidString]
    XCTAssertEqual(SpotlightIndex.chatID(from: activity), id)
  }
}
