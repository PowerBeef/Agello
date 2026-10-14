import Foundation

/// Drawer sections by recency (Today, Yesterday, Previous 7 Days,
/// Previous 30 Days, then one per month) and chat search. Pure: unit-tested.
enum ThreadGrouping {
  struct Group<Item>: Identifiable {
    var title: String
    var items: [Item]
    var id: String { title }
  }

  /// Groups `items` (already sorted newest first) by `date`; pinned items
  /// come first in their own section.
  static func groups<Item>(
    _ items: [Item], date: (Item) -> Date, pinned: (Item) -> Bool = { _ in false },
    now: Date = .now, calendar: Calendar = .current
  ) -> [Group<Item>] {
    let pinnedItems = items.filter(pinned)
    var groups: [Group<Item>] =
      pinnedItems.isEmpty ? [] : [Group(title: String(localized: "Pinned"), items: pinnedItems)]
    for item in items where !pinned(item) {
      let title = section(for: date(item), now: now, calendar: calendar)
      if groups.last?.title == title {
        groups[groups.count - 1].items.append(item)
      } else if let index = groups.firstIndex(where: { $0.title == title }) {
        groups[index].items.append(item)
      } else {
        groups.append(Group(title: title, items: [item]))
      }
    }
    return groups
  }

  static func section(for date: Date, now: Date, calendar: Calendar) -> String {
    let today = calendar.startOfDay(for: now)
    let day = calendar.startOfDay(for: date)
    let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
    switch days {
    case ..<1: return String(localized: "Today")
    case 1: return String(localized: "Yesterday")
    case 2..<7: return String(localized: "Previous 7 Days")
    case 7..<30: return String(localized: "Previous 30 Days")
    default:
      let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
      var style = Date.FormatStyle(
        locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar,
        timeZone: calendar.timeZone
      ).month(.wide)
      if !sameYear { style = style.year() }
      return date.formatted(style)
    }
  }

  /// A search hit: the matching text around the query, or nil when only
  /// the title matched.
  struct Match: Equatable {
    var snippet: String?
  }

  /// Case- and diacritic-insensitive search of a chat's title and messages.
  static func match(query: String, title: String, messages: [String]) -> Match? {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return Match(snippet: nil) }
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    if title.range(of: query, options: options) != nil { return Match(snippet: nil) }
    for message in messages {
      if let range = message.range(of: query, options: options) {
        return Match(snippet: snippet(message, around: range))
      }
    }
    return nil
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
