import Foundation
import Synchronization

// MARK: - Opt-in personal tools settings

/// Opt-in toggles for native iOS personal context tools. Every toggle defaults to `false`
/// so personal data is never exposed to the model without explicit user opt-in.
struct PersonalToolsSettings: Codable, Equatable, Sendable {
  var calendar = false
  var reminders = false
  var contacts = false
  var maps = false

  init(calendar: Bool = false, reminders: Bool = false, contacts: Bool = false, maps: Bool = false) {
    self.calendar = calendar
    self.reminders = reminders
    self.contacts = contacts
    self.maps = maps
  }

  /// Tolerant decoding so saved preferences never reset when keys are added.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    calendar = try container.decodeIfPresent(Bool.self, forKey: .calendar) ?? false
    reminders = try container.decodeIfPresent(Bool.self, forKey: .reminders) ?? false
    contacts = try container.decodeIfPresent(Bool.self, forKey: .contacts) ?? false
    maps = try container.decodeIfPresent(Bool.self, forKey: .maps) ?? false
  }

  var anyEnabled: Bool { calendar || reminders || contacts || maps }

  var enabledCount: Int {
    [calendar, reminders, contacts, maps].filter { $0 }.count
  }

  var toolSetKey: String {
    "cal=\(calendar),rem=\(reminders),con=\(contacts),map=\(maps)"
  }
}

// MARK: - Personal context models & backend seam

struct CalendarEventSummary: Equatable, Sendable {
  var title: String
  var startDate: Date
  var endDate: Date
  var isAllDay: Bool
  var location: String?
  var calendarName: String?
  var notes: String?
}

struct FreeSlotSummary: Equatable, Sendable {
  var startDate: Date
  var endDate: Date

  var durationMinutes: Int {
    max(0, Int(endDate.timeIntervalSince(startDate) / 60.0))
  }
}

struct ReminderSummary: Equatable, Sendable {
  var title: String
  var dueDate: Date?
  var isCompleted: Bool
  var listName: String?
  var priority: Int
  var notes: String?
}

struct ContactSummary: Equatable, Sendable {
  var fullName: String
  var organization: String?
  var phones: [String]
  var emails: [String]
}

struct PlaceSummary: Equatable, Sendable {
  var name: String
  var address: String?
  var phone: String?
  var category: String?
  var latitude: Double
  var longitude: Double
  var mapsURL: String?
}

struct TravelEstimateSummary: Equatable, Sendable {
  var origin: String
  var destination: String
  var transport: String
  var distanceMeters: Double
  var expectedTravelSeconds: Double
}

enum PersonalToolResult<Value: Sendable>: Sendable {
  case success(Value)
  case error(String)
}

/// Platform/test backend executing personal-context operations (`EventKit`, `Contacts`, `MapKit`).
protocol PersonalContextBackend: Sendable {
  func searchCalendarEvents(
    start: Date, end: Date, query: String?
  ) async -> PersonalToolResult<[CalendarEventSummary]>

  func createCalendarEvent(
    title: String, start: Date, end: Date, location: String?, notes: String?
  ) async -> PersonalToolResult<CalendarEventSummary>

  func listReminders(
    includeCompleted: Bool, query: String?
  ) async -> PersonalToolResult<[ReminderSummary]>

  func createReminder(
    title: String, dueDate: Date?, notes: String?
  ) async -> PersonalToolResult<ReminderSummary>

  func searchContacts(
    query: String, limit: Int
  ) async -> PersonalToolResult<[ContactSummary]>

  func searchPlaces(
    query: String, near: String?, limit: Int
  ) async -> PersonalToolResult<[PlaceSummary]>

  func estimateTravelTime(
    origin: String?, destination: String, transport: String
  ) async -> PersonalToolResult<TravelEstimateSummary>
}

/// Active personal-context backend dispatcher (platform implementation or injected test backend).
enum PersonalTools {
  private static let overrideBackend = Mutex<(any PersonalContextBackend)?>(nil)

  static func setTestBackend(_ backend: (any PersonalContextBackend)?) {
    overrideBackend.withLock { $0 = backend }
  }

  static var activeBackend: any PersonalContextBackend {
    overrideBackend.withLock { $0 } ?? PersonalContextService.shared
  }
}

// MARK: - Pure date, slot, and formatting logic

enum PersonalToolsLogic {
  /// Parses ISO-8601 dates (`2026-11-22T14:30:00Z`, `2026-11-22T14:30:00-05:00`, `2026-11-22T14:30:00`),
  /// space-separated timestamps (`2026-11-22 14:30`), or date-only (`2026-11-22`, interpreted in
  /// `timeZone` at start or end of day when `endOfDay` is true).
  static func parseDate(
    _ raw: String, endOfDay: Bool = false, timeZone: TimeZone = .current
  ) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Full ISO-8601 with timezone offset or Z.
    let isoFrac = ISO8601DateFormatter()
    isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = isoFrac.date(from: trimmed) { return date }

    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: trimmed) { return date }

    // Local date-time without timezone suffix.
    let formats = [
      "yyyy-MM-dd'T'HH:mm:ss",
      "yyyy-MM-dd'T'HH:mm",
      "yyyy-MM-dd HH:mm:ss",
      "yyyy-MM-dd HH:mm",
    ]
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    for format in formats {
      formatter.dateFormat = format
      if let date = formatter.date(from: trimmed) { return date }
    }

    // Date-only `yyyy-MM-dd`.
    formatter.dateFormat = "yyyy-MM-dd"
    if let dayStart = formatter.date(from: trimmed) {
      guard endOfDay else { return dayStart }
      var cal = Calendar(identifier: .gregorian)
      cal.timeZone = timeZone
      return cal.date(byAdding: DateComponents(day: 1, second: -1), to: dayStart) ?? dayStart
    }
    return nil
  }

  /// Formats a date cleanly in ISO-8601 local time (for deterministic tool outputs and confirmation cards).
  static func formatISO(_ date: Date, timeZone: TimeZone = .current) -> String {
    let iso = ISO8601DateFormatter()
    iso.timeZone = timeZone
    iso.formatOptions = [.withInternetDateTime]
    return iso.string(from: date)
  }

  /// Computes available free time intervals of at least `minDurationMinutes` between `windowStart`
  /// and `windowEnd`, clamped to reasonable daytime hours (`workdayStartHour..<workdayEndHour`) per day.
  static func computeFreeSlots(
    busyEvents: [CalendarEventSummary],
    windowStart: Date,
    windowEnd: Date,
    minDurationMinutes: Int = 30,
    workdayStartHour: Int = 8,
    workdayEndHour: Int = 20,
    timeZone: TimeZone = .current
  ) -> [FreeSlotSummary] {
    guard windowEnd > windowStart else { return [] }
    let minSeconds = TimeInterval(max(5, minDurationMinutes) * 60)

    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone

    // Build clamped, merged busy intervals.
    let rawBusy: [(Date, Date)] = busyEvents.compactMap { event in
      let start = max(windowStart, event.startDate)
      let end = min(windowEnd, event.endDate)
      return end > start ? (start, end) : nil
    }.sorted { $0.0 < $1.0 }

    var merged: [(Date, Date)] = []
    for interval in rawBusy {
      if let last = merged.last, interval.0 <= last.1 {
        merged[merged.count - 1].1 = max(last.1, interval.1)
      } else {
        merged.append(interval)
      }
    }

    // Walk day-by-day across the requested window within daytime bounds.
    var slots: [FreeSlotSummary] = []
    var dayCursor = cal.startOfDay(for: windowStart)
    let lastDay = cal.startOfDay(for: windowEnd)

    while dayCursor <= lastDay {
      guard
        let workStart = cal.date(bySettingHour: workdayStartHour, minute: 0, second: 0, of: dayCursor),
        let workEnd = cal.date(bySettingHour: workdayEndHour, minute: 0, second: 0, of: dayCursor)
      else { break }

      let segStart = max(windowStart, workStart)
      let segEnd = min(windowEnd, workEnd)
      if segEnd > segStart {
        var cursor = segStart
        for (busyStart, busyEnd) in merged {
          if busyEnd <= cursor { continue }
          if busyStart >= segEnd { break }
          if busyStart > cursor {
            let gap = busyStart.timeIntervalSince(cursor)
            if gap >= minSeconds {
              slots.append(FreeSlotSummary(startDate: cursor, endDate: busyStart))
            }
          }
          cursor = max(cursor, min(busyEnd, segEnd))
        }
        if segEnd.timeIntervalSince(cursor) >= minSeconds {
          slots.append(FreeSlotSummary(startDate: cursor, endDate: segEnd))
        }
      }

      guard let nextDay = cal.date(byAdding: .day, value: 1, to: dayCursor) else { break }
      dayCursor = nextDay
    }
    return slots
  }

  static func formatEvents(_ events: [CalendarEventSummary], timeZone: TimeZone = .current) -> String {
    guard !events.isEmpty else { return "No calendar events found in that range." }
    return events.map { event in
      let when = event.isAllDay
        ? "\(formatISO(event.startDate, timeZone: timeZone)) (all day)"
        : "\(formatISO(event.startDate, timeZone: timeZone)) to \(formatISO(event.endDate, timeZone: timeZone))"
      var parts = ["- \(event.title) | \(when)"]
      if let loc = event.location, !loc.isEmpty { parts.append("location: \(loc)") }
      if let cal = event.calendarName, !cal.isEmpty { parts.append("calendar: \(cal)") }
      if let notes = event.notes, !notes.isEmpty {
        parts.append("notes: \(String(notes.prefix(240)))")
      }
      return parts.joined(separator: " | ")
    }.joined(separator: "\n")
  }

  static func formatFreeSlots(_ slots: [FreeSlotSummary], timeZone: TimeZone = .current) -> String {
    guard !slots.isEmpty else { return "No free slots found matching the requested duration." }
    return slots.prefix(20).map { slot in
      "- \(formatISO(slot.startDate, timeZone: timeZone)) to \(formatISO(slot.endDate, timeZone: timeZone)) (\(slot.durationMinutes) min)"
    }.joined(separator: "\n")
  }

  static func formatReminders(_ reminders: [ReminderSummary], timeZone: TimeZone = .current) -> String {
    guard !reminders.isEmpty else { return "No reminders found." }
    return reminders.prefix(30).map { item in
      var parts = ["- [\(item.isCompleted ? "x" : " ")] \(item.title)"]
      if let due = item.dueDate { parts.append("due: \(formatISO(due, timeZone: timeZone))") }
      if let list = item.listName, !list.isEmpty { parts.append("list: \(list)") }
      if let notes = item.notes, !notes.isEmpty { parts.append("notes: \(String(notes.prefix(180)))") }
      return parts.joined(separator: " | ")
    }.joined(separator: "\n")
  }

  static func formatContacts(_ contacts: [ContactSummary]) -> String {
    guard !contacts.isEmpty else { return "No matching contacts found." }
    return contacts.map { c in
      var parts = ["- \(c.fullName)"]
      if let org = c.organization, !org.isEmpty { parts.append("org: \(org)") }
      if !c.phones.isEmpty { parts.append("phone: \(c.phones.joined(separator: ", "))") }
      if !c.emails.isEmpty { parts.append("email: \(c.emails.joined(separator: ", "))") }
      return parts.joined(separator: " | ")
    }.joined(separator: "\n")
  }

  static func formatPlaces(_ places: [PlaceSummary]) -> String {
    guard !places.isEmpty else { return "No matching places found." }
    return places.enumerated().map { idx, place in
      var parts = ["\(idx + 1). \(place.name)"]
      if let cat = place.category, !cat.isEmpty { parts.append("(\(cat))") }
      if let addr = place.address, !addr.isEmpty { parts.append("— \(addr)") }
      if let phone = place.phone, !phone.isEmpty { parts.append("| \(phone)") }
      parts.append(String(format: "| coords: %.5f, %.5f", place.latitude, place.longitude))
      if let url = place.mapsURL { parts.append("| \(url)") }
      return parts.joined(separator: " ")
    }.joined(separator: "\n")
  }

  static func formatTravel(_ estimate: TravelEstimateSummary) -> String {
    let km = estimate.distanceMeters / 1_000.0
    let mins = max(1, Int((estimate.expectedTravelSeconds / 60.0).rounded()))
    return "\(estimate.transport.capitalized) from \(estimate.origin) to \(estimate.destination): "
      + String(format: "%.1f km, about %d min.", km, mins)
  }
}
