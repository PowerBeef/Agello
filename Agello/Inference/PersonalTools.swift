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
  var weather = false
  var alarms = false
  var photos = false

  init(
    calendar: Bool = false, reminders: Bool = false, contacts: Bool = false, maps: Bool = false,
    weather: Bool = false, alarms: Bool = false, photos: Bool = false
  ) {
    self.calendar = calendar
    self.reminders = reminders
    self.contacts = contacts
    self.maps = maps
    self.weather = weather
    self.alarms = alarms
    self.photos = photos
  }

  /// Tolerant decoding so saved preferences never reset when keys are added.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    calendar = try container.decodeIfPresent(Bool.self, forKey: .calendar) ?? false
    reminders = try container.decodeIfPresent(Bool.self, forKey: .reminders) ?? false
    contacts = try container.decodeIfPresent(Bool.self, forKey: .contacts) ?? false
    maps = try container.decodeIfPresent(Bool.self, forKey: .maps) ?? false
    weather = try container.decodeIfPresent(Bool.self, forKey: .weather) ?? false
    alarms = try container.decodeIfPresent(Bool.self, forKey: .alarms) ?? false
    photos = try container.decodeIfPresent(Bool.self, forKey: .photos) ?? false
  }

  var anyEnabled: Bool { calendar || reminders || contacts || maps || weather || alarms || photos }

  var enabledCount: Int {
    [calendar, reminders, contacts, maps, weather, alarms, photos].filter { $0 }.count
  }

  var toolSetKey: String {
    "cal=\(calendar),rem=\(reminders),con=\(contacts),map=\(maps),wx=\(weather),alm=\(alarms),pho=\(photos)"
  }

  /// Returns a copy with all personal-context domains disabled (used by Focus Filters).
  var suppressed: PersonalToolsSettings {
    PersonalToolsSettings()
  }
}

/// Active iOS Focus Filter overrides (0 LLM tool tokens). Written by `AgelloFocusFilter`
/// (`SetFocusFilterIntent`) and observed by `AppState` when resolving `effectiveOptions`.
struct FocusFilterOverrides: Codable, Equatable, Sendable {
  var hidePersonalTools = false
  var defaultProjectID: UUID? = nil

  static let userDefaultsKey = "focusFilterOverrides"
  static let didChangeNotification = Notification.Name("com.patricedery.agello.focusFilterDidChange")

  static func load() -> FocusFilterOverrides {
    guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
      let decoded = try? JSONDecoder().decode(FocusFilterOverrides.self, from: data)
    else { return FocusFilterOverrides() }
    return decoded
  }

  static func save(_ overrides: FocusFilterOverrides) {
    if let data = try? JSONEncoder().encode(overrides) {
      UserDefaults.standard.set(data, forKey: userDefaultsKey)
    }
    NotificationCenter.default.post(name: didChangeNotification, object: nil)
  }
}

// MARK: - Personal context models & backend seam

struct CalendarEventSummary: Equatable, Sendable {
  var eventIdentifier: String? = nil
  var title: String
  var startDate: Date
  var endDate: Date
  var isAllDay: Bool
  var location: String? = nil
  var calendarName: String? = nil
  var notes: String? = nil
}

struct FreeSlotSummary: Equatable, Sendable {
  var startDate: Date
  var endDate: Date

  var durationMinutes: Int {
    max(0, Int(endDate.timeIntervalSince(startDate) / 60.0))
  }
}

struct ReminderSummary: Equatable, Sendable {
  var reminderIdentifier: String? = nil
  var title: String
  var dueDate: Date? = nil
  var isCompleted: Bool
  var listName: String? = nil
  var priority: Int = 0
  var notes: String? = nil
}

struct ContactSummary: Equatable, Sendable {
  var contactIdentifier: String? = nil
  var fullName: String
  var organization: String? = nil
  var phones: [String]
  var emails: [String]
  var postalAddress: String? = nil
  var birthday: String? = nil
}

struct PlaceSummary: Equatable, Sendable {
  var name: String
  var address: String? = nil
  var phone: String? = nil
  var category: String? = nil
  var latitude: Double
  var longitude: Double
  var mapsURL: String? = nil
  var distanceMeters: Double? = nil
  var websiteURL: String? = nil
  var mapItemIdentifier: String? = nil
}

struct TravelEstimateSummary: Equatable, Sendable {
  var origin: String
  var destination: String
  var transport: String
  var distanceMeters: Double
  var expectedTravelSeconds: Double
  var originLatitude: Double? = nil
  var originLongitude: Double? = nil
  var originIsCurrentLocation: Bool = false
  var destinationAddress: String? = nil
  var destinationLatitude: Double? = nil
  var destinationLongitude: Double? = nil
  var destinationMapItemIdentifier: String? = nil
  var routeName: String? = nil
  var steps: [RouteCard.Step] = []
}

struct WeatherSummary: Equatable, Sendable {
  var locationName: String
  var description: String
  var card: WeatherCard
}

struct AlarmSummary: Equatable, Sendable {
  var alarmID: String
  var kind: AlarmCard.Kind
  var label: String
  var fireDate: Date? = nil
  var hour: Int? = nil
  var minute: Int? = nil
  var weekdays: [String] = []
  var durationSeconds: Double? = nil
  var state: AlarmCard.State = .scheduled
}

struct PhotoSearchMatch: Equatable, Sendable {
  var localIdentifier: String
  var creationDate: Date?
  var locationName: String? = nil
  var isFavorite: Bool = false
  var width: Int = 0
  var height: Int = 0
  var ocrText: String? = nil
}

/// Optional options when creating or updating a Calendar event.
struct CalendarEventMutation: Equatable, Sendable {
  var title: String? = nil
  var startDate: Date? = nil
  var endDate: Date? = nil
  var location: String? = nil
  var notes: String? = nil
  var alarmMinutesBefore: Int? = nil
  /// `"none"`, `"daily"`, `"weekly"`, `"monthly"`, or `"yearly"`.
  var recurrence: String? = nil
}

/// Optional options when creating or updating a Reminder.
struct ReminderMutation: Equatable, Sendable {
  var title: String? = nil
  var dueDate: Date? = nil
  var clearDueDate: Bool = false
  var listName: String? = nil
  var notes: String? = nil
  var priority: Int? = nil
  var isCompleted: Bool? = nil
}

enum PersonalToolResult<Value: Sendable>: Sendable {
  case success(Value)
  case error(String)
}

/// Platform/test backend executing personal-context operations (`EventKit`, `Contacts`, `MapKit`,
/// `WeatherKit`, `AlarmKit`).
protocol PersonalContextBackend: Sendable {
  func searchCalendarEvents(
    start: Date, end: Date, query: String?
  ) async -> PersonalToolResult<[CalendarEventSummary]>

  func fetchCalendarEvent(identifier: String) async -> PersonalToolResult<CalendarEventSummary>

  func createCalendarEvent(
    title: String, start: Date, end: Date, location: String?, notes: String?
  ) async -> PersonalToolResult<CalendarEventSummary>

  func createCalendarEvent(
    title: String, start: Date, end: Date, location: String?, notes: String?,
    alarmMinutesBefore: Int?, recurrence: String?
  ) async -> PersonalToolResult<CalendarEventSummary>

  func updateCalendarEvent(
    identifier: String, mutation: CalendarEventMutation
  ) async -> PersonalToolResult<CalendarEventSummary>

  func deleteCalendarEvent(identifier: String) async -> PersonalToolResult<CalendarEventSummary>

  func listReminders(
    includeCompleted: Bool, query: String?
  ) async -> PersonalToolResult<[ReminderSummary]>

  func fetchReminder(identifier: String) async -> PersonalToolResult<ReminderSummary>

  func createReminder(
    title: String, dueDate: Date?, notes: String?
  ) async -> PersonalToolResult<ReminderSummary>

  func createReminder(
    title: String, dueDate: Date?, listName: String?, notes: String?, priority: Int?
  ) async -> PersonalToolResult<ReminderSummary>

  func setReminderCompleted(
    identifier: String, completed: Bool
  ) async -> PersonalToolResult<ReminderSummary>

  func updateReminder(
    identifier: String, mutation: ReminderMutation
  ) async -> PersonalToolResult<ReminderSummary>

  func deleteReminder(identifier: String) async -> PersonalToolResult<ReminderSummary>

  func searchContacts(
    query: String, limit: Int
  ) async -> PersonalToolResult<[ContactSummary]>

  func searchPlaces(
    query: String, near: String?, limit: Int
  ) async -> PersonalToolResult<[PlaceSummary]>

  func estimateTravelTime(
    origin: String?, destination: String, transport: String
  ) async -> PersonalToolResult<TravelEstimateSummary>

  func fetchWeather(place: String?, scope: String) async -> PersonalToolResult<WeatherSummary>

  func listAlarms() async -> PersonalToolResult<[AlarmSummary]>

  func scheduleTimer(label: String, durationSeconds: Double) async -> PersonalToolResult<AlarmSummary>

  func scheduleAlarm(
    label: String, hour: Int, minute: Int, weekdays: [String]
  ) async -> PersonalToolResult<AlarmSummary>

  func cancelAlarm(identifier: String) async -> PersonalToolResult<AlarmSummary>

  func pauseAlarm(identifier: String) async -> PersonalToolResult<AlarmSummary>

  func resumeAlarm(identifier: String) async -> PersonalToolResult<AlarmSummary>

  func searchPhotos(
    query: String?, start: Date?, end: Date?, favoritesOnly: Bool, includeOCR: Bool, limit: Int
  ) async -> PersonalToolResult<[PhotoSearchMatch]>
}

extension PersonalContextBackend {
  func fetchCalendarEvent(identifier: String) async -> PersonalToolResult<CalendarEventSummary> {
    .error("Calendar event lookup is unavailable on this backend.")
  }

  func createCalendarEvent(
    title: String, start: Date, end: Date, location: String?, notes: String?,
    alarmMinutesBefore: Int?, recurrence: String?
  ) async -> PersonalToolResult<CalendarEventSummary> {
    await createCalendarEvent(title: title, start: start, end: end, location: location, notes: notes)
  }

  func updateCalendarEvent(
    identifier: String, mutation: CalendarEventMutation
  ) async -> PersonalToolResult<CalendarEventSummary> {
    .error("Updating calendar events is unavailable on this backend.")
  }

  func deleteCalendarEvent(identifier: String) async -> PersonalToolResult<CalendarEventSummary> {
    .error("Deleting calendar events is unavailable on this backend.")
  }

  func fetchReminder(identifier: String) async -> PersonalToolResult<ReminderSummary> {
    .error("Reminder lookup is unavailable on this backend.")
  }

  func createReminder(
    title: String, dueDate: Date?, listName: String?, notes: String?, priority: Int?
  ) async -> PersonalToolResult<ReminderSummary> {
    await createReminder(title: title, dueDate: dueDate, notes: notes)
  }

  func setReminderCompleted(
    identifier: String, completed: Bool
  ) async -> PersonalToolResult<ReminderSummary> {
    .error("Updating reminders is unavailable on this backend.")
  }

  func updateReminder(
    identifier: String, mutation: ReminderMutation
  ) async -> PersonalToolResult<ReminderSummary> {
    .error("Updating reminders is unavailable on this backend.")
  }

  func deleteReminder(identifier: String) async -> PersonalToolResult<ReminderSummary> {
    .error("Deleting reminders is unavailable on this backend.")
  }

  func fetchWeather(place: String?, scope: String) async -> PersonalToolResult<WeatherSummary> {
    .error("Weather lookup is unavailable on this backend.")
  }

  func listAlarms() async -> PersonalToolResult<[AlarmSummary]> {
    .error("Alarms and timers are only available on iOS.")
  }

  func scheduleTimer(label: String, durationSeconds: Double) async -> PersonalToolResult<AlarmSummary> {
    .error("Alarms and timers are only available on iOS.")
  }

  func scheduleAlarm(
    label: String, hour: Int, minute: Int, weekdays: [String]
  ) async -> PersonalToolResult<AlarmSummary> {
    .error("Alarms and timers are only available on iOS.")
  }

  func cancelAlarm(identifier: String) async -> PersonalToolResult<AlarmSummary> {
    .error("Alarms and timers are only available on iOS.")
  }

  func pauseAlarm(identifier: String) async -> PersonalToolResult<AlarmSummary> {
    .error("Alarms and timers are only available on iOS.")
  }

  func resumeAlarm(identifier: String) async -> PersonalToolResult<AlarmSummary> {
    .error("Alarms and timers are only available on iOS.")
  }

  func searchPhotos(
    query: String?, start: Date?, end: Date?, favoritesOnly: Bool, includeOCR: Bool, limit: Int
  ) async -> PersonalToolResult<[PhotoSearchMatch]> {
    .error("Photos search is only available on iOS.")
  }
}

/// Tracks verified phone numbers and email addresses fetched from on-device Contacts during the
/// current reply so `prepare_message` can deterministically flag unverified/external recipients.
enum TurnContactRoster {
  private static let verified = Mutex<Set<String>>([])

  static func reset() {
    verified.withLock { $0.removeAll(keepingCapacity: true) }
  }

  static func register(_ contacts: [ContactSummary]) {
    verified.withLock { set in
      for contact in contacts {
        for phone in contact.phones {
          let norm = normalizePhone(phone)
          if !norm.isEmpty { set.insert(norm) }
        }
        for email in contact.emails {
          let norm = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          if !norm.isEmpty { set.insert(norm) }
        }
      }
    }
  }

  /// Registers raw email addresses or phone numbers typed directly by the user in their prompt
  /// so user-authored recipients are not falsely flagged as unverified.
  static func registerUserText(_ text: String) {
    let emails = extractMatches(
      in: text, pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#)
    let phones = extractMatches(
      in: text, pattern: #"(?:\+?\d[\d\s().-]{6,}\d)"#)
    verified.withLock { set in
      for email in emails { set.insert(email.lowercased()) }
      for phone in phones {
        let norm = normalizePhone(phone)
        if norm.count >= 7 { set.insert(norm) }
      }
    }
  }

  static func unverifiedRecipients(from recipients: [String]) -> [String] {
    verified.withLock { known in
      recipients.filter { recipient in
        let trimmed = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.contains("@") {
          return !known.contains(trimmed.lowercased())
        }
        let norm = normalizePhone(trimmed)
        return norm.isEmpty || !known.contains(norm)
      }
    }
  }

  private static func normalizePhone(_ raw: String) -> String {
    raw.filter(\.isNumber)
  }

  private static func extractMatches(in text: String, pattern: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap { match in
      Range(match.range, in: text).map { String(text[$0]) }
    }
  }
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
      if let id = event.eventIdentifier, !id.isEmpty { parts.append("id: \(id)") }
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
      if let id = item.reminderIdentifier, !id.isEmpty { parts.append("id: \(id)") }
      if let due = item.dueDate { parts.append("due: \(formatISO(due, timeZone: timeZone))") }
      if let list = item.listName, !list.isEmpty { parts.append("list: \(list)") }
      if let notes = item.notes, !notes.isEmpty { parts.append("notes: \(String(notes.prefix(180)))") }
      return parts.joined(separator: " | ")
    }.joined(separator: "\n")
  }

  static func formatAlarms(_ alarms: [AlarmSummary], timeZone: TimeZone = .current) -> String {
    guard !alarms.isEmpty else { return "No active alarms or timers found." }
    return alarms.prefix(20).map { alarm in
      var parts = ["- \(alarm.label) (\(alarm.kind.rawValue), \(alarm.state.rawValue))"]
      parts.append("id: \(alarm.alarmID)")
      if let hour = alarm.hour, let minute = alarm.minute {
        parts.append(String(format: "time: %02d:%02d", hour, minute))
      } else if let fire = alarm.fireDate {
        parts.append("ends: \(formatISO(fire, timeZone: timeZone))")
      } else if let secs = alarm.durationSeconds {
        parts.append("duration: \(formatDuration(secs))")
      }
      if !alarm.weekdays.isEmpty {
        parts.append("repeats: \(alarm.weekdays.joined(separator: ", "))")
      }
      return parts.joined(separator: " | ")
    }.joined(separator: "\n")
  }

  static func formatDuration(_ seconds: Double) -> String {
    let total = max(1, Int(seconds.rounded()))
    let hours = total / 3_600
    let mins = (total % 3_600) / 60
    let secs = total % 60
    if hours > 0 {
      return mins > 0 ? "\(hours)h \(mins)m" : "\(hours)h"
    }
    if mins > 0 {
      return secs > 0 ? "\(mins)m \(secs)s" : "\(mins) min"
    }
    return "\(secs)s"
  }

  /// Normalizes weekday names/abbreviations (`"mon"`, `"Monday"`, `"lundi"`, etc.) into canonical
  /// short English tokens (`mon`..`sun`) for AlarmKit scheduling and display.
  static func normalizeWeekdays(_ raw: [String]?) -> [String] {
    guard let raw else { return [] }
    let table: [(String, [String])] = [
      ("mon", ["mon", "monday", "lun", "lundi", "lunes", "montag"]),
      ("tue", ["tue", "tues", "tuesday", "mar", "mardi", "martes", "dienstag"]),
      ("wed", ["wed", "wednesday", "mer", "mercredi", "miercoles", "miércoles", "mittwoch"]),
      ("thu", ["thu", "thur", "thurs", "thursday", "jeu", "jeudi", "jueves", "donnerstag"]),
      ("fri", ["fri", "friday", "ven", "vendredi", "viernes", "freitag"]),
      ("sat", ["sat", "saturday", "sam", "samedi", "sabado", "sábado", "samstag"]),
      ("sun", ["sun", "sunday", "dim", "dimanche", "domingo", "sonntag"]),
    ]
    var seen = Set<String>()
    var ordered: [String] = []
    for item in raw {
      let token = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if token == "weekdays" || token == "weekday" {
        for day in ["mon", "tue", "wed", "thu", "fri"] where seen.insert(day).inserted { ordered.append(day) }
        continue
      }
      if token == "weekend" || token == "weekends" {
        for day in ["sat", "sun"] where seen.insert(day).inserted { ordered.append(day) }
        continue
      }
      if token == "daily" || token == "everyday" || token == "every day" {
        for day in ["mon", "tue", "wed", "thu", "fri", "sat", "sun"] where seen.insert(day).inserted {
          ordered.append(day)
        }
        continue
      }
      if let match = table.first(where: { $0.1.contains(token) })?.0, seen.insert(match).inserted {
        ordered.append(match)
      }
    }
    return ordered
  }

  /// Resolves an optional Calendar search date range cleanly:
  /// - Both given: parses both bounds.
  /// - Both omitted with a non-empty `query`: searches `-7d ... +30d` around `now` so searching
  ///   for an upcoming event by name ("Team Lunch") finds it without guessing today-only.
  /// - Both omitted without a `query`: searches `startOfDay(now) ... +7d`.
  /// - Only one bound given: fills the counterpart (`+7d` or `-7d`).
  static func resolveCalendarRange(
    startDate: String?, endDate: String?, query: String?,
    now: Date = .now, timeZone: TimeZone = .current
  ) -> (start: Date, end: Date)? {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    let todayStart = cal.startOfDay(for: now)
    let hasQuery = !(query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

    let rawStart = startDate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let rawEnd = endDate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    let start: Date
    let end: Date
    if rawStart.isEmpty && rawEnd.isEmpty {
      if hasQuery {
        start = cal.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart
        end = cal.date(byAdding: DateComponents(day: 31, second: -1), to: todayStart) ?? now
      } else {
        start = todayStart
        end = cal.date(byAdding: DateComponents(day: 8, second: -1), to: todayStart) ?? now
      }
    } else if !rawStart.isEmpty && !rawEnd.isEmpty {
      guard let s = parseDate(rawStart, endOfDay: false, timeZone: timeZone),
        let e = parseDate(rawEnd, endOfDay: true, timeZone: timeZone),
        e >= s
      else { return nil }
      start = s
      end = e
    } else if !rawStart.isEmpty {
      guard let s = parseDate(rawStart, endOfDay: false, timeZone: timeZone) else { return nil }
      start = s
      let spanDays = hasQuery ? 30 : 7
      end = cal.date(byAdding: DateComponents(day: spanDays, second: -1), to: cal.startOfDay(for: s)) ?? s
    } else {
      guard let e = parseDate(rawEnd, endOfDay: true, timeZone: timeZone) else { return nil }
      end = e
      start = cal.date(byAdding: .day, value: -7, to: cal.startOfDay(for: e)) ?? e
    }
    return (start, end)
  }

  /// Broad window (`-7d ... +30d`) used for single-pass auto-widening when a narrow same-day
  /// query returns zero events.
  static func widenedCalendarRange(now: Date = .now, timeZone: TimeZone = .current) -> (start: Date, end: Date) {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = timeZone
    let todayStart = cal.startOfDay(for: now)
    let start = cal.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart
    let end = cal.date(byAdding: DateComponents(day: 31, second: -1), to: todayStart) ?? now
    return (start, end)
  }

  static func formatContacts(_ contacts: [ContactSummary]) -> String {
    guard !contacts.isEmpty else { return "No matching contacts found." }
    return contacts.map { c in
      var parts = ["- \(c.fullName)"]
      if let org = c.organization, !org.isEmpty { parts.append("org: \(org)") }
      if !c.phones.isEmpty { parts.append("phone: \(c.phones.joined(separator: ", "))") }
      if !c.emails.isEmpty { parts.append("email: \(c.emails.joined(separator: ", "))") }
      if let address = c.postalAddress, !address.isEmpty { parts.append("address: \(address)") }
      if let bday = c.birthday, !bday.isEmpty { parts.append("birthday: \(bday)") }
      return parts.joined(separator: " | ")
    }.joined(separator: "\n")
  }

  /// Compact model-facing place list: includes human distance, address, phone, and website while
  /// omitting raw GPS coordinates and verbose Maps URLs (the inline `PlacesCard` handles Apple Maps
  /// launches deterministically).
  static func formatPlaces(_ places: [PlaceSummary]) -> String {
    guard !places.isEmpty else { return "No matching places found." }
    return places.enumerated().map { idx, place in
      var parts = ["\(idx + 1). \(place.name)"]
      if let cat = place.category, !cat.isEmpty { parts.append("(\(cat))") }
      if let meters = place.distanceMeters {
        parts.append("— \(formatDistance(meters)) away")
      }
      if let addr = place.address, !addr.isEmpty { parts.append("| \(addr)") }
      if let phone = place.phone, !phone.isEmpty { parts.append("| \(phone)") }
      if let site = place.websiteURL, !site.isEmpty { parts.append("| \(site)") }
      return parts.joined(separator: " ")
    }.joined(separator: "\n")
  }

  static func formatDistance(_ meters: Double) -> String {
    if meters < 1_000 {
      return "\(max(1, Int(meters.rounded()))) m"
    }
    return String(format: "%.1f km", meters / 1_000.0)
  }

  static func formatTravel(_ estimate: TravelEstimateSummary, includeSteps: Bool = true) -> String {
    let dist = formatDistance(estimate.distanceMeters)
    let mins = max(1, Int((estimate.expectedTravelSeconds / 60.0).rounded()))
    var header = "\(estimate.transport.capitalized) from \(estimate.origin) to \(estimate.destination): \(dist), about \(mins) min"
    if let routeName = estimate.routeName, !routeName.isEmpty {
      header += " via \(routeName)"
    }
    header += "."
    guard includeSteps, !estimate.steps.isEmpty else { return header }
    let stepsText = estimate.steps.prefix(15).enumerated().map { idx, step in
      let stepDist = step.distanceMeters >= 20 ? " (\(formatDistance(step.distanceMeters)))" : ""
      return "\(idx + 1). \(step.instruction)\(stepDist)"
    }.joined(separator: "\n")
    return "\(header)\nTurn-by-turn steps:\n\(stepsText)"
  }

  static func formatPhotos(_ photos: [PhotoSearchMatch], timeZone: TimeZone = .current) -> String {
    guard !photos.isEmpty else { return "No matching photos found." }
    return photos.enumerated().map { idx, photo in
      var parts = ["\(idx + 1)."]
      if let date = photo.creationDate {
        parts.append(formatISO(date, timeZone: timeZone))
      } else {
        parts.append("Unknown date")
      }
      if photo.isFavorite { parts.append("[favorite]") }
      if let loc = photo.locationName, !loc.isEmpty { parts.append("at \(loc)") }
      if photo.width > 0, photo.height > 0 { parts.append("(\(photo.width)×\(photo.height))") }
      var line = parts.joined(separator: " ")
      if let ocr = photo.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty {
        line += "\n   OCR text: \(String(ocr.prefix(600)))"
      }
      return line
    }.joined(separator: "\n")
  }
}
