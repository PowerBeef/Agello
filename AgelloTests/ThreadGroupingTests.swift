import XCTest

@testable import Agello

final class ThreadGroupingTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
  }()

  private func date(_ string: String) -> Date {
    try! Date(string, strategy: .iso8601)
  }

  func testSectionsByRecency() {
    let now = date("2026-10-09T10:00:00Z")
    let dates = [
      "2026-10-09T08:00:00Z",  // Today
      "2026-10-08T23:00:00Z",  // Yesterday
      "2026-10-05T12:00:00Z",  // 4 days
      "2026-09-20T12:00:00Z",  // 19 days
      "2026-08-01T12:00:00Z",  // August
      "2025-12-25T12:00:00Z",  // previous year
    ].map(date)
    let groups = ThreadGrouping.groups(dates, date: { $0 }, now: now, calendar: calendar)
    XCTAssertEqual(
      groups.map(\.title),
      ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "August", "December 2025"])
    XCTAssertTrue(groups.allSatisfy { $0.items.count == 1 })
  }

  func testItemsKeepTheirOrderWithinASection() {
    let now = date("2026-10-09T10:00:00Z")
    let dates = ["2026-10-09T09:00:00Z", "2026-10-09T07:00:00Z"].map(date)
    let groups = ThreadGrouping.groups(dates, date: { $0 }, now: now, calendar: calendar)
    XCTAssertEqual(groups.count, 1)
    XCTAssertEqual(groups[0].items, dates)
  }

  func testSearchMatchesTitleThenMessages() {
    XCTAssertEqual(
      ThreadGrouping.match(query: "kyoto", title: "Trip to Kyoto", messages: []),
      .init(snippet: nil))
    let hit = ThreadGrouping.match(
      query: "creme", title: "Desserts", messages: ["Hello", "Try a crème brûlée tonight"])
    XCTAssertEqual(hit?.snippet, "Try a crème brûlée tonight")
    XCTAssertNil(ThreadGrouping.match(query: "pizza", title: "Desserts", messages: ["Cake"]))
    XCTAssertEqual(
      ThreadGrouping.match(query: "  ", title: "Any", messages: []), .init(snippet: nil))
  }

  func testSnippetIsTrimmedAroundTheMatch() {
    let text = String(repeating: "a", count: 100) + " needle " + String(repeating: "b", count: 100)
    let range = text.range(of: "needle")!
    let snippet = ThreadGrouping.snippet(text, around: range, radius: 10)
    XCTAssertTrue(snippet.hasPrefix("…"))
    XCTAssertTrue(snippet.hasSuffix("…"))
    XCTAssertTrue(snippet.contains("needle"))
  }
}

final class OnboardingTests: XCTestCase {
  func testShownOnlyOnFirstLaunchWithoutAModel() {
    XCTAssertTrue(OnboardingView.shouldShow(done: false, isMock: false, downloaded: false))
    XCTAssertFalse(OnboardingView.shouldShow(done: true, isMock: false, downloaded: false))
    XCTAssertFalse(OnboardingView.shouldShow(done: false, isMock: false, downloaded: true))
    XCTAssertFalse(OnboardingView.shouldShow(done: false, isMock: true, downloaded: false))
  }
}

extension ThreadGroupingTests {
  func testPinnedItemsComeFirstInTheirOwnSection() {
    let now = date("2026-10-09T10:00:00Z")
    let items = [
      ("a", "2026-10-09T09:00:00Z", false), ("b", "2026-08-01T09:00:00Z", true),
      ("c", "2026-10-08T09:00:00Z", false),
    ].map { ($0.0, date($0.1), $0.2) }
    let groups = ThreadGrouping.groups(
      items, date: { $0.1 }, pinned: { $0.2 }, now: now, calendar: calendar)
    XCTAssertEqual(groups.map(\.title), ["Pinned", "Today", "Yesterday"])
    XCTAssertEqual(groups[0].items.map(\.0), ["b"])
  }
}
