import Foundation

/// Drawer sections by recency (Today, Yesterday, Previous 7 Days,
/// Previous 30 Days, then one per month) and chat search. Pure: unit-tested.
enum ThreadGrouping {
  struct Group<Item>: Identifiable {
    var title: String
    var items: [Item]
    var id: String { title }
  }

  private struct FormatStyleKey: Hashable, Sendable {
    let calendarIdentifier: Calendar.Identifier
    let localeIdentifier: String
    let timeZoneIdentifier: String
    let includeYear: Bool
  }

  private final class FormatStyleCache: @unchecked Sendable {
    private let lock = NSLock()
    private var styles: [FormatStyleKey: Date.FormatStyle] = [:]

    func style(for calendar: Calendar, includeYear: Bool) -> Date.FormatStyle {
      let locale = calendar.locale ?? .autoupdatingCurrent
      let key = FormatStyleKey(
        calendarIdentifier: calendar.identifier,
        localeIdentifier: locale.identifier,
        timeZoneIdentifier: calendar.timeZone.identifier,
        includeYear: includeYear)
      return lock.withLock {
        if let cached = styles[key] { return cached }
        var style = Date.FormatStyle(
          locale: locale, calendar: calendar, timeZone: calendar.timeZone
        ).month(.wide)
        if includeYear { style = style.year() }
        if styles.count >= 16 { styles.removeAll(keepingCapacity: true) }
        styles[key] = style
        return style
      }
    }
  }

  private static let formatStyleCache = FormatStyleCache()

  /// Groups `items` (already sorted newest first) by `date`; pinned items
  /// come first in their own section.
  static func groups<Item>(
    _ items: [Item], date: (Item) -> Date, pinned: (Item) -> Bool = { _ in false },
    now: Date = .now, calendar: Calendar = .current
  ) -> [Group<Item>] {
    let pinnedItems = items.filter(pinned)
    var groups: [Group<Item>] =
      pinnedItems.isEmpty ? [] : [Group(title: String(localized: "Pinned"), items: pinnedItems)]
    var indexByTitle: [String: Int] = [:]
    let today = calendar.startOfDay(for: now)
    let nowYear = calendar.component(.year, from: now)
    for item in items where !pinned(item) {
      let title = section(for: date(item), today: today, nowYear: nowYear, calendar: calendar)
      if let index = indexByTitle[title] {
        groups[index].items.append(item)
      } else {
        indexByTitle[title] = groups.count
        groups.append(Group(title: title, items: [item]))
      }
    }
    return groups
  }

  static func section(for date: Date, now: Date, calendar: Calendar) -> String {
    section(
      for: date,
      today: calendar.startOfDay(for: now),
      nowYear: calendar.component(.year, from: now),
      calendar: calendar)
  }

  private static func section(
    for date: Date, today: Date, nowYear: Int, calendar: Calendar
  ) -> String {
    let day = calendar.startOfDay(for: date)
    let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
    switch days {
    case ..<1: return String(localized: "Today")
    case 1: return String(localized: "Yesterday")
    case 2..<7: return String(localized: "Previous 7 Days")
    case 7..<30: return String(localized: "Previous 30 Days")
    default:
      let sameYear = calendar.component(.year, from: date) == nowYear
      let style = formatStyleCache.style(for: calendar, includeYear: !sameYear)
      return date.formatted(style)
    }
  }

  /// A search hit: the matching text around the query, or nil when only
  /// the title matched.
  struct Match: Equatable {
    var snippet: String?
  }

  /// Case- and diacritic-insensitive search of a chat's title, reading `messages` lazily only
  /// when the title does not already match (avoids faulting SwiftData turns on title hits).
  static func match(query: String, title: String, messages: () -> [String]) -> Match? {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return Match(snippet: nil) }
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    if title.range(of: query, options: options) != nil { return Match(snippet: nil) }
    for message in messages() {
      if let range = message.range(of: query, options: options) {
        return Match(snippet: snippet(message, around: range))
      }
    }
    return nil
  }

  /// Case- and diacritic-insensitive search of a chat's title and messages.
  static func match(query: String, title: String, messages: [String]) -> Match? {
    match(query: query, title: title, messages: { messages })
  }

  static func snippet(_ text: String, around range: Range<String.Index>, radius: Int = 40)
    -> String
  {
    let start = text.index(range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex)
      ?? text.startIndex
    let end = text.index(range.upperBound, offsetBy: radius, limitedBy: text.endIndex)
      ?? text.endIndex
    var snippet = text[start..<end]
      .replacingOccurrences(of: "\n", with: " ")
      .trimmingCharacters(in: .whitespaces)
    if start > text.startIndex { snippet = "…" + snippet }
    if end < text.endIndex { snippet += "…" }
    return snippet
  }
}
