import Foundation
import LiteRTLMTools

// MARK: - Consolidated Calendar Tools (Read vs Mutating)

/// Reads Calendar events or computes free daytime slots. Read-only.
struct ReadCalendarTool: Tool {
  static let name = "read_calendar"
  static let isReadOnly = true
  static let description =
    "Read on-device Calendar events or find free slots. Omit startDate/endDate when searching events by query (-7d to +30d)."

  @ToolParam(description: "Read mode.", allowedValues: ["events", "free_slots"])
  var mode: String = "events"

  @ToolParam(description: "Optional range start (YYYY-MM-DD or ISO-8601).")
  var startDate: String? = nil

  @ToolParam(description: "Optional range end (YYYY-MM-DD or ISO-8601).")
  var endDate: String? = nil

  @ToolParam(description: "Optional title, location, or notes filter (events mode).")
  var query: String? = nil

  @ToolParam(description: "Minimum slot length in minutes for free_slots mode (default 30).")
  var minDurationMinutes: Int = 30

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    let normalizedMode = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard let range = PersonalToolsLogic.resolveCalendarRange(
      startDate: startDate, endDate: endDate, query: normalizedMode == "free_slots" ? nil : query)
    else {
      return ["error": "Invalid date range. Use YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS."]
    }
    let backend = PersonalTools.activeBackend
    if normalizedMode == "free_slots" {
      switch await backend.searchCalendarEvents(start: range.start, end: range.end, query: nil) {
      case .error(let message):
        ToolActivity.record(Self.name, summary: "Calendar unavailable")
        return ["error": ToolOutput.text(message)]
      case .success(let events):
        let slots = PersonalToolsLogic.computeFreeSlots(
          busyEvents: events, windowStart: range.start, windowEnd: range.end,
          minDurationMinutes: minDurationMinutes)
        ToolActivity.record(Self.name, summary: "Found \(slots.count) free calendar slots")
        return [
          "mode": "free_slots",
          "count": slots.count,
          "slots": ToolBudget.fit(PersonalToolsLogic.formatFreeSlots(slots), limits),
        ]
      }
    }

    let cleanQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasQuery = !(cleanQuery?.isEmpty ?? true)
    switch await backend.searchCalendarEvents(start: range.start, end: range.end, query: cleanQuery) {
    case .error(let message):
      ToolActivity.record(Self.name, summary: "Calendar unavailable")
      return ["error": ToolOutput.text(message)]
    case .success(var events):
      let spanSeconds = range.end.timeIntervalSince(range.start)
      if events.isEmpty, hasQuery, spanSeconds <= 36 * 3_600 {
        let wide = PersonalToolsLogic.widenedCalendarRange()
        if case .success(let widened) = await backend.searchCalendarEvents(
          start: wide.start, end: wide.end, query: cleanQuery)
        {
          events = widened
        }
      }
      ToolActivity.record(Self.name, summary: "Checked calendar (\(events.count) events)")
      for event in events.prefix(3) {
        ToolCardRecorder.record(
          .calendarEvent(
            CalendarEventCard(
              status: .found,
              eventIdentifier: event.eventIdentifier,
              title: event.title,
              startDate: event.startDate,
              endDate: event.endDate,
              isAllDay: event.isAllDay,
              location: event.location,
              calendarName: event.calendarName)))
      }
      let body = PersonalToolsLogic.formatEvents(events)
      return [
        "mode": "events",
        "count": events.count,
        "events": UntrustedContext.wrapFitted(body, source: Self.name, limits: limits),
      ]
    }
  }
}

/// Creates, updates, or deletes a Calendar event ONLY after deterministic pre-execution confirmation.
/// Update and delete require an opaque `id` returned by `read_calendar` and perform an
/// authoritative EventKit lookup before displaying the confirmation card.
struct ManageCalendarEventTool: Tool {
  static let name = "manage_calendar_event"
  static let isReadOnly = false
  static let description =
    "Create, update, or delete a Calendar event (always confirms first; update/delete require id from read_calendar)."

  @ToolParam(description: "Mutation action.", allowedValues: ["create", "update", "delete"])
  var action: String

  @ToolParam(description: "Opaque event id from read_calendar (required for update/delete).")
  var id: String? = nil

  @ToolParam(description: "Event title (required for create; optional for update).")
  var title: String? = nil

  @ToolParam(description: "Start date/time (YYYY-MM-DDTHH:MM:SS).")
  var startDate: String? = nil

  @ToolParam(description: "End date/time (YYYY-MM-DDTHH:MM:SS).")
  var endDate: String? = nil

  @ToolParam(description: "Optional location.")
  var location: String? = nil

  @ToolParam(description: "Optional notes.")
  var notes: String? = nil

  @ToolParam(description: "Optional alert minutes before start (e.g. 15).")
  var alarmMinutesBefore: Int? = nil

  @ToolParam(
    description: "Optional repeat rule.",
    allowedValues: ["none", "daily", "weekly", "monthly", "yearly"])
  var recurrence: String? = nil

  func run() async throws -> Any {
    guard ToolBudget.claim() != nil else { return ToolBudget.limitReachedResult }
    switch action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "create": return await runCreate()
    case "update": return await runUpdate()
    case "delete": return await runDelete()
    default: return ["error": "Invalid action. Use 'create', 'update', or 'delete'."]
    }
  }

  private func runCreate() async -> Any {
    let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !cleanTitle.isEmpty else { return ["error": "Event title is required for create."] }
    guard let rawStart = startDate, let rawEnd = endDate,
      let start = PersonalToolsLogic.parseDate(rawStart, endOfDay: false),
      let end = PersonalToolsLogic.parseDate(rawEnd, endOfDay: false),
      end > start
    else {
      return ["error": "Invalid startDate/endDate. Use YYYY-MM-DDTHH:MM:SS with endDate after startDate."]
    }
    let cleanRecurrence = recurrence?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var params: [ToolConfirmationRequest.Parameter] = [
      .init(name: "title", value: cleanTitle),
      .init(name: "start", value: PersonalToolsLogic.formatISO(start)),
      .init(name: "end", value: PersonalToolsLogic.formatISO(end)),
    ]
    if let location, !location.isEmpty { params.append(.init(name: "location", value: location)) }
    if let alarmMinutesBefore, alarmMinutesBefore >= 0 {
      params.append(.init(name: "alert", value: "\(alarmMinutesBefore) min before"))
    }
    if let cleanRecurrence, !cleanRecurrence.isEmpty, cleanRecurrence != "none" {
      params.append(.init(name: "repeat", value: cleanRecurrence))
    }
    if let notes, !notes.isEmpty { params.append(.init(name: "notes", value: String(notes.prefix(200)))) }

    let request = ToolConfirmationRequest(
      toolName: Self.name,
      title: String(localized: "Create calendar event"),
      summary: "Add “\(cleanTitle)” to your Calendar.",
      parameters: params,
      risk: .standard)
    guard case .approved = await ToolConfirmationGate.confirm(request) else {
      ToolActivity.record(Self.name, summary: "Cancelled creating “\(cleanTitle)”")
      return ["executed": false, "status": "cancelled", "message": "Denied by user."]
    }

    switch await PersonalTools.activeBackend.createCalendarEvent(
      title: cleanTitle, start: start, end: end, location: location, notes: notes,
      alarmMinutesBefore: alarmMinutesBefore, recurrence: cleanRecurrence)
    {
    case .error(let message):
      ToolActivity.record(Self.name, summary: "Couldn't create event “\(cleanTitle)”")
      return ["executed": false, "error": ToolOutput.text(message)]
    case .success(let saved):
      ToolActivity.record(Self.name, summary: "Created event “\(saved.title)”")
      recordEventCard(saved, status: .created)
      return eventReceipt(saved, status: "created")
    }
  }

  private func runUpdate() async -> Any {
    guard let targetID = id?.trimmingCharacters(in: .whitespacesAndNewlines), !targetID.isEmpty else {
      return ["error": "Provide id from read_calendar before updating an event."]
    }
    let existing: CalendarEventSummary
    switch await PersonalTools.activeBackend.fetchCalendarEvent(identifier: targetID) {
    case .error(let message): return ["executed": false, "error": ToolOutput.text(message)]
    case .success(let found): existing = found
    }

    var mutation = CalendarEventMutation()
    if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      mutation.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let startDate, !startDate.isEmpty {
      guard let parsed = PersonalToolsLogic.parseDate(startDate, endOfDay: false) else {
        return ["error": "Invalid startDate format."]
      }
      mutation.startDate = parsed
    }
    if let endDate, !endDate.isEmpty {
      guard let parsed = PersonalToolsLogic.parseDate(endDate, endOfDay: false) else {
        return ["error": "Invalid endDate format."]
      }
      mutation.endDate = parsed
    }
    let effectiveStart = mutation.startDate ?? existing.startDate
    let effectiveEnd = mutation.endDate ?? existing.endDate
    guard effectiveEnd > effectiveStart else {
      return ["error": "Updated endDate must be after startDate."]
    }
    mutation.location = location
    mutation.notes = notes
    mutation.alarmMinutesBefore = alarmMinutesBefore
    mutation.recurrence = recurrence?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    var params: [ToolConfirmationRequest.Parameter] = [
      .init(name: "event", value: existing.title),
      .init(name: "was", value: PersonalToolsLogic.formatISO(existing.startDate)),
    ]
    if let newTitle = mutation.title, newTitle != existing.title {
      params.append(.init(name: "new title", value: newTitle))
    }
    if mutation.startDate != nil || mutation.endDate != nil {
      params.append(
        .init(
          name: "new time",
          value: "\(PersonalToolsLogic.formatISO(effectiveStart)) – \(PersonalToolsLogic.formatISO(effectiveEnd))"))
    }
    if let loc = mutation.location, !loc.isEmpty { params.append(.init(name: "location", value: loc)) }

    let request = ToolConfirmationRequest(
      toolName: Self.name,
      title: String(localized: "Update calendar event"),
      summary: "Update “\(existing.title)” in your Calendar.",
      parameters: params,
      risk: .standard)
    guard case .approved = await ToolConfirmationGate.confirm(request) else {
      ToolActivity.record(Self.name, summary: "Cancelled updating “\(existing.title)”")
      return ["executed": false, "status": "cancelled", "message": "Denied by user."]
    }

    switch await PersonalTools.activeBackend.updateCalendarEvent(identifier: targetID, mutation: mutation) {
    case .error(let message):
      ToolActivity.record(Self.name, summary: "Couldn't update “\(existing.title)”")
      return ["executed": false, "error": ToolOutput.text(message)]
    case .success(let saved):
      ToolActivity.record(Self.name, summary: "Updated event “\(saved.title)”")
      recordEventCard(saved, status: .updated)
      return eventReceipt(saved, status: "updated")
    }
  }

  private func runDelete() async -> Any {
    guard let targetID = id?.trimmingCharacters(in: .whitespacesAndNewlines), !targetID.isEmpty else {
      return ["error": "Provide id from read_calendar before deleting an event."]
    }
    let existing: CalendarEventSummary
    switch await PersonalTools.activeBackend.fetchCalendarEvent(identifier: targetID) {
    case .error(let message): return ["executed": false, "error": ToolOutput.text(message)]
    case .success(let found): existing = found
    }

    var params: [ToolConfirmationRequest.Parameter] = [
      .init(name: "event", value: existing.title),
      .init(name: "start", value: PersonalToolsLogic.formatISO(existing.startDate)),
      .init(name: "end", value: PersonalToolsLogic.formatISO(existing.endDate)),
    ]
    if let cal = existing.calendarName, !cal.isEmpty {
      params.append(.init(name: "calendar", value: cal))
    }

    let request = ToolConfirmationRequest(
      toolName: Self.name,
      title: String(localized: "Delete calendar event"),
      summary: "Permanently remove “\(existing.title)” from your Calendar.",
      parameters: params,
      risk: .destructive)
    guard case .approved = await ToolConfirmationGate.confirm(request) else {
      ToolActivity.record(Self.name, summary: "Cancelled deleting “\(existing.title)”")
      return ["executed": false, "status": "cancelled", "message": "Denied by user."]
    }

    switch await PersonalTools.activeBackend.deleteCalendarEvent(identifier: targetID) {
    case .error(let message):
      ToolActivity.record(Self.name, summary: "Couldn't delete “\(existing.title)”")
      return ["executed": false, "error": ToolOutput.text(message)]
    case .success(let removed):
      ToolActivity.record(Self.name, summary: "Deleted event “\(removed.title)”")
      recordEventCard(removed, status: .deleted)
      return eventReceipt(removed, status: "deleted")
    }
  }

  private func recordEventCard(_ event: CalendarEventSummary, status: CalendarEventCard.Status) {
    ToolCardRecorder.record(
      .calendarEvent(
        CalendarEventCard(
          status: status,
          eventIdentifier: event.eventIdentifier,
          title: event.title,
          startDate: event.startDate,
          endDate: event.endDate,
          isAllDay: event.isAllDay,
          location: event.location,
          calendarName: event.calendarName)))
  }

  private func eventReceipt(_ event: CalendarEventSummary, status: String) -> [String: Any] {
    [
      "executed": true,
      "status": status,
      "id": ToolOutput.text(event.eventIdentifier ?? "", maxChars: 120),
      "title": ToolOutput.text(event.title),
      "start": PersonalToolsLogic.formatISO(event.startDate),
      "end": PersonalToolsLogic.formatISO(event.endDate),
      "calendar": ToolOutput.text(event.calendarName ?? "Default", maxChars: 80),
    ]
  }
}

// MARK: - Consolidated Reminder Mutation Tool

/// Creates, completes, reopens, updates, or deletes a Reminder after explicit user confirmation.
struct ManageReminderTool: Tool {
  static let name = "manage_reminder"
  static let isReadOnly = false
  static let description =
    "Create, complete, reopen, update, or delete a Reminder (always confirms first; non-create actions require id from list_reminders)."

  @ToolParam(
    description: "Mutation action.",
    allowedValues: ["create", "complete", "reopen", "update", "delete"])
  var action: String

  @ToolParam(description: "Opaque reminder id from list_reminders (required unless creating).")
  var id: String? = nil

  @ToolParam(description: "Reminder title (required for create; optional for update).")
  var title: String? = nil

  @ToolParam(description: "Optional due date/time (YYYY-MM-DD or ISO-8601).")
  var dueDate: String? = nil

  @ToolParam(description: "Optional Reminders list name.")
  var listName: String? = nil

  @ToolParam(description: "Optional notes.")
  var notes: String? = nil

  @ToolParam(description: "Optional priority (0=none, 1=high, 5=medium, 9=low).")
  var priority: Int? = nil

  func run() async throws -> Any {
    guard ToolBudget.claim() != nil else { return ToolBudget.limitReachedResult }
    switch action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "create": return await runCreate()
    case "complete": return await runToggle(completed: true)
    case "reopen": return await runToggle(completed: false)
    case "update": return await runUpdate()
    case "delete": return await runDelete()
    default:
      return ["error": "Invalid action. Use 'create', 'complete', 'reopen', 'update', or 'delete'."]
    }
  }

  private func runCreate() async -> Any {
    let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !cleanTitle.isEmpty else { return ["error": "Reminder title is required for create."] }
    var parsedDue: Date?
    if let dueDate, !dueDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard let parsed = PersonalToolsLogic.parseDate(dueDate, endOfDay: false) else {
        return ["error": "Invalid dueDate. Use YYYY-MM-DD or YYYY-MM-DDTHH:MM:SS."]
      }
      parsedDue = parsed
    }
    var params: [ToolConfirmationRequest.Parameter] = [.init(name: "title", value: cleanTitle)]
    if let parsedDue { params.append(.init(name: "due", value: PersonalToolsLogic.formatISO(parsedDue))) }
    if let listName, !listName.isEmpty { params.append(.init(name: "list", value: listName)) }
    if let notes, !notes.isEmpty { params.append(.init(name: "notes", value: String(notes.prefix(200)))) }

    let request = ToolConfirmationRequest(
      toolName: Self.name,
      title: String(localized: "Create reminder"),
      summary: "Add “\(cleanTitle)” to Reminders.",
      parameters: params,
      risk: .standard)
    guard case .approved = await ToolConfirmationGate.confirm(request) else {
      ToolActivity.record(Self.name, summary: "Cancelled reminder “\(cleanTitle)”")
      return ["executed": false, "status": "cancelled", "message": "Denied by user."]
    }

    switch await PersonalTools.activeBackend.createReminder(
      title: cleanTitle, dueDate: parsedDue, listName: listName, notes: notes, priority: priority)
    {
    case .error(let message):
      ToolActivity.record(Self.name, summary: "Couldn't create reminder “\(cleanTitle)”")
      return ["executed": false, "error": ToolOutput.text(message)]
    case .success(let saved):
      ToolActivity.record(Self.name, summary: "Created reminder “\(saved.title)”")
      recordReminderCard(saved, status: .created)
      return reminderReceipt(saved, status: "created")
    }
  }

  private func runToggle(completed: Bool) async -> Any {
    guard let targetID = id?.trimmingCharacters(in: .whitespacesAndNewlines), !targetID.isEmpty else {
      return ["error": "Provide id from list_reminders."]
    }
    let existing: ReminderSummary
    switch await PersonalTools.activeBackend.fetchReminder(identifier: targetID) {
    case .error(let message): return ["executed": false, "error": ToolOutput.text(message)]
    case .success(let found): existing = found
    }

    let verb = completed ? String(localized: "Complete reminder") : String(localized: "Reopen reminder")
    let request = ToolConfirmationRequest(
      toolName: Self.name,
      title: verb,
      summary: completed ? "Mark “\(existing.title)” as completed." : "Mark “\(existing.title)” incomplete.",
      parameters: [.init(name: "reminder", value: existing.title)],
      risk: .standard)
    guard case .approved = await ToolConfirmationGate.confirm(request) else {
      ToolActivity.record(Self.name, summary: "Cancelled updating reminder")
      return ["executed": false, "status": "cancelled", "message": "Denied by user."]
    }

    switch await PersonalTools.activeBackend.setReminderCompleted(identifier: targetID, completed: completed) {
    case .error(let message): return ["executed": false, "error": ToolOutput.text(message)]
    case .success(let saved):
      ToolActivity.record(
        Self.name, summary: completed ? "Completed “\(saved.title)”" : "Reopened “\(saved.title)”")
      recordReminderCard(saved, status: completed ? .completed : .updated)
      return reminderReceipt(saved, status: completed ? "completed" : "reopened")
    }
  }

  private func runUpdate() async -> Any {
    guard let targetID = id?.trimmingCharacters(in: .whitespacesAndNewlines), !targetID.isEmpty else {
      return ["error": "Provide id from list_reminders before updating a reminder."]
    }
    let existing: ReminderSummary
    switch await PersonalTools.activeBackend.fetchReminder(identifier: targetID) {
    case .error(let message): return ["executed": false, "error": ToolOutput.text(message)]
    case .success(let found): existing = found
    }

    var mutation = ReminderMutation()
    if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      mutation.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let dueDate, !dueDate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard let parsed = PersonalToolsLogic.parseDate(dueDate, endOfDay: false) else {
        return ["error": "Invalid dueDate format."]
      }
      mutation.dueDate = parsed
    }
    mutation.listName = listName
    mutation.notes = notes
    mutation.priority = priority

    var params: [ToolConfirmationRequest.Parameter] = [.init(name: "reminder", value: existing.title)]
    if let newTitle = mutation.title, newTitle != existing.title {
      params.append(.init(name: "new title", value: newTitle))
    }
    if let due = mutation.dueDate {
      params.append(.init(name: "due", value: PersonalToolsLogic.formatISO(due)))
    }
    if let listName, !listName.isEmpty { params.append(.init(name: "list", value: listName)) }

    let request = ToolConfirmationRequest(
      toolName: Self.name,
      title: String(localized: "Update reminder"),
      summary: "Update “\(existing.title)” in Reminders.",
      parameters: params,
      risk: .standard)
    guard case .approved = await ToolConfirmationGate.confirm(request) else {
      ToolActivity.record(Self.name, summary: "Cancelled updating reminder")
      return ["executed": false, "status": "cancelled", "message": "Denied by user."]
    }

    switch await PersonalTools.activeBackend.updateReminder(identifier: targetID, mutation: mutation) {
    case .error(let message): return ["executed": false, "error": ToolOutput.text(message)]
    case .success(let saved):
      ToolActivity.record(Self.name, summary: "Updated reminder “\(saved.title)”")
      recordReminderCard(saved, status: .updated)
      return reminderReceipt(saved, status: "updated")
    }
  }

  private func runDelete() async -> Any {
    guard let targetID = id?.trimmingCharacters(in: .whitespacesAndNewlines), !targetID.isEmpty else {
      return ["error": "Provide id from list_reminders before deleting a reminder."]
    }
    let existing: ReminderSummary
    switch await PersonalTools.activeBackend.fetchReminder(identifier: targetID) {
    case .error(let message): return ["executed": false, "error": ToolOutput.text(message)]
    case .success(let found): existing = found
    }

    var params: [ToolConfirmationRequest.Parameter] = [.init(name: "reminder", value: existing.title)]
    if let due = existing.dueDate {
      params.append(.init(name: "due", value: PersonalToolsLogic.formatISO(due)))
    }
    let request = ToolConfirmationRequest(
      toolName: Self.name,
      title: String(localized: "Delete reminder"),
      summary: "Permanently remove “\(existing.title)” from Reminders.",
      parameters: params,
      risk: .destructive)
    guard case .approved = await ToolConfirmationGate.confirm(request) else {
      ToolActivity.record(Self.name, summary: "Cancelled deleting reminder")
      return ["executed": false, "status": "cancelled", "message": "Denied by user."]
    }

    switch await PersonalTools.activeBackend.deleteReminder(identifier: targetID) {
    case .error(let message): return ["executed": false, "error": ToolOutput.text(message)]
    case .success(let removed):
      ToolActivity.record(Self.name, summary: "Deleted reminder “\(removed.title)”")
      recordReminderCard(removed, status: .deleted)
      return reminderReceipt(removed, status: "deleted")
    }
  }

  private func recordReminderCard(_ item: ReminderSummary, status: ReminderCard.Status) {
    ToolCardRecorder.record(
      .reminder(
        ReminderCard(
          status: status,
          reminderIdentifier: item.reminderIdentifier,
          title: item.title,
          dueDate: item.dueDate,
          listName: item.listName,
          isCompleted: item.isCompleted)))
  }

  private func reminderReceipt(_ item: ReminderSummary, status: String) -> [String: Any] {
    [
      "executed": true,
      "status": status,
      "id": ToolOutput.text(item.reminderIdentifier ?? "", maxChars: 120),
      "title": ToolOutput.text(item.title),
      "completed": item.isCompleted,
      "due": item.dueDate.map { PersonalToolsLogic.formatISO($0) } ?? "",
      "list": ToolOutput.text(item.listName ?? "Default", maxChars: 80),
    ]
  }
}

// MARK: - Dedicated WeatherKit Tool

/// Fetches live Apple Weather conditions, forecast, and severe alerts (works with Web Search OFF).
struct GetWeatherTool: Tool {
  static let name = "get_weather"
  static let isReadOnly = true
  static let description =
    "Get live Apple Weather conditions, hourly/daily forecast, and severe alerts for a city or the user's current location."

  @ToolParam(description: "City or place name; omit or 'here' for current location.")
  var place: String? = nil

  @ToolParam(description: "Forecast detail.", allowedValues: ["current", "hourly", "daily", "alerts"])
  var scope: String = "current"

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    let normalizedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch await PersonalTools.activeBackend.fetchWeather(place: place, scope: normalizedScope) {
    case .error(let message):
      ToolActivity.record(Self.name, summary: "Weather unavailable")
      return ["error": ToolOutput.text(message)]
    case .success(let weather):
      ToolActivity.record(Self.name, summary: "Checked weather for \(weather.locationName)")
      ToolCardRecorder.record(.weather(weather.card))
      return [
        "location": ToolOutput.text(weather.locationName, maxChars: 120),
        "alerts_count": weather.card.alerts.count,
        "report": UntrustedContext.wrapFitted(weather.description, source: Self.name, limits: limits),
      ]
    }
  }
}

// MARK: - iOS 27 AlarmKit Tools

/// Lists active Agello timers and alarms scheduled via AlarmKit. Read-only.
struct ListAlarmsTool: Tool {
  static let name = "list_alarms"
  static let isReadOnly = true
  static let description = "List active on-device timers and alarms scheduled by Agello."

  func run() async throws -> Any {
    guard let limits = ToolBudget.claim() else { return ToolBudget.limitReachedResult }
    switch await PersonalTools.activeBackend.listAlarms() {
    case .error(let message):
      ToolActivity.record(Self.name, summary: "Alarms unavailable")
      return ["error": ToolOutput.text(message)]
    case .success(let alarms):
      ToolActivity.record(Self.name, summary: "Checked alarms (\(alarms.count))")
      for alarm in alarms.prefix(3) {
        ToolCardRecorder.record(
          .alarm(
            AlarmCard(
              alarmID: alarm.alarmID, kind: alarm.kind, label: alarm.label,
              fireDate: alarm.fireDate, hour: alarm.hour, minute: alarm.minute,
              weekdays: alarm.weekdays, durationSeconds: alarm.durationSeconds, state: alarm.state)))
      }
      return [
        "count": alarms.count,
        "alarms": ToolBudget.fit(PersonalToolsLogic.formatAlarms(alarms), limits),
      ]
    }
  }
}

/// Schedules or cancels native iOS 27 AlarmKit timers and alarms after explicit confirmation.
struct ManageAlarmTool: Tool {
  static let name = "manage_alarm"
  static let isReadOnly = false
  static let description =
    "Set a countdown timer, schedule a daily/weekly alarm, or cancel an active alarm by id (always confirms first)."

  @ToolParam(description: "Alarm action.", allowedValues: ["set_timer", "set_alarm", "cancel"])
  var action: String

  @ToolParam(description: "Timer or alarm label, e.g. 'Pasta' or 'Wake up'.")
  var label: String? = nil

  @ToolParam(description: "Countdown duration in seconds (for set_timer, e.g. 600 for 10 min).")
  var durationSeconds: Double? = nil

  @ToolParam(description: "Alarm hour in 24-hour time 0-23 (for set_alarm).")
  var hour: Int? = nil

  @ToolParam(description: "Alarm minute 0-59 (for set_alarm).")
  var minute: Int? = nil

  @ToolParam(description: "Optional repeat weekdays for set_alarm, e.g. ['mon','tue','wed','thu','fri'].")
  var weekdays: [String]? = nil

  @ToolParam(description: "Opaque alarm id from list_alarms (required for cancel).")
  var id: String? = nil

  func run() async throws -> Any {
    guard ToolBudget.claim() != nil else { return ToolBudget.limitReachedResult }
    switch action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "set_timer": return await runTimer()
    case "set_alarm": return await runAlarm()
    case "cancel": return await runCancel()
    default: return ["error": "Invalid action. Use 'set_timer', 'set_alarm', or 'cancel'."]
    }
  }

  private func runTimer() async -> Any {
    guard let secs = durationSeconds, secs.isFinite, secs >= 5, secs <= 24 * 3_600 else {
      return ["error": "Provide durationSeconds between 5 and 86400 (24 hours)."]
    }
    let cleanLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = (cleanLabel?.isEmpty == false) ? cleanLabel! : String(localized: "Timer")
    let formatted = PersonalToolsLogic.formatDuration(secs)
    let request = ToolConfirmationRequest(
      toolName: Self.name,
      title: String(localized: "Start timer"),
      summary: "Start a \(formatted) timer “\(title)”.",
      parameters: [
        .init(name: "label", value: title),
        .init(name: "duration", value: formatted),
      ],
      risk: .standard)
    guard case .approved = await ToolConfirmationGate.confirm(request) else {
      ToolActivity.record(Self.name, summary: "Cancelled timer “\(title)”")
      return ["executed": false, "status": "cancelled", "message": "Denied by user."]
    }

    switch await PersonalTools.activeBackend.scheduleTimer(label: title, durationSeconds: secs) {
    case .error(let message): return ["executed": false, "error": ToolOutput.text(message)]
    case .success(let saved):
      ToolActivity.record(Self.name, summary: "Started \(formatted) timer")
      recordAlarmCard(saved)
      return [
        "executed": true,
        "status": "scheduled",
        "id": saved.alarmID,
        "kind": "timer",
        "label": ToolOutput.text(saved.label),
        "duration_seconds": secs,
      ]
    }
  }

  private func runAlarm() async -> Any {
    guard let hour, (0...23).contains(hour), let minute, (0...59).contains(minute) else {
      return ["error": "Provide hour (0-23) and minute (0-59) for set_alarm."]
    }
    let cleanLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
    let title = (cleanLabel?.isEmpty == false) ? cleanLabel! : String(localized: "Alarm")
    let days = PersonalToolsLogic.normalizeWeekdays(weekdays)
    let timeText = String(format: "%02d:%02d", hour, minute)
    var params: [ToolConfirmationRequest.Parameter] = [
      .init(name: "label", value: title),
      .init(name: "time", value: timeText),
    ]
    if !days.isEmpty { params.append(.init(name: "repeats", value: days.joined(separator: ", "))) }

    let request = ToolConfirmationRequest(
      toolName: Self.name,
      title: String(localized: "Set alarm"),
      summary: "Schedule alarm “\(title)” for \(timeText).",
      parameters: params,
      risk: .standard)
    guard case .approved = await ToolConfirmationGate.confirm(request) else {
      ToolActivity.record(Self.name, summary: "Cancelled alarm “\(title)”")
      return ["executed": false, "status": "cancelled", "message": "Denied by user."]
    }

    switch await PersonalTools.activeBackend.scheduleAlarm(
      label: title, hour: hour, minute: minute, weekdays: days)
    {
    case .error(let message): return ["executed": false, "error": ToolOutput.text(message)]
    case .success(let saved):
      ToolActivity.record(Self.name, summary: "Set alarm for \(timeText)")
      recordAlarmCard(saved)
      return [
        "executed": true,
        "status": "scheduled",
        "id": saved.alarmID,
        "kind": "alarm",
        "label": ToolOutput.text(saved.label),
        "time": timeText,
        "weekdays": days,
      ]
    }
  }

  private func runCancel() async -> Any {
    guard let targetID = id?.trimmingCharacters(in: .whitespacesAndNewlines), !targetID.isEmpty else {
      return ["error": "Provide id from list_alarms before cancelling an alarm."]
    }
    let existing: AlarmSummary
    switch await PersonalTools.activeBackend.listAlarms() {
    case .error(let message): return ["executed": false, "error": ToolOutput.text(message)]
    case .success(let all):
      guard let found = all.first(where: { $0.alarmID == targetID }) else {
        return ["executed": false, "error": "No active alarm or timer found with that id."]
      }
      existing = found
    }

    let request = ToolConfirmationRequest(
      toolName: Self.name,
      title: String(localized: "Cancel \(existing.kind.rawValue)"),
      summary: "Cancel “\(existing.label)”.",
      parameters: [
        .init(name: "label", value: existing.label),
        .init(name: "kind", value: existing.kind.rawValue),
      ],
      risk: .destructive)
    guard case .approved = await ToolConfirmationGate.confirm(request) else {
      ToolActivity.record(Self.name, summary: "Kept “\(existing.label)”")
      return ["executed": false, "status": "cancelled", "message": "Denied by user."]
    }

    switch await PersonalTools.activeBackend.cancelAlarm(identifier: targetID) {
    case .error(let message): return ["executed": false, "error": ToolOutput.text(message)]
    case .success(let cancelled):
      ToolActivity.record(Self.name, summary: "Cancelled “\(cancelled.label)”")
      recordAlarmCard(cancelled)
      return ["executed": true, "status": "cancelled", "id": cancelled.alarmID, "label": cancelled.label]
    }
  }

  private func recordAlarmCard(_ alarm: AlarmSummary) {
    ToolCardRecorder.record(
      .alarm(
        AlarmCard(
          alarmID: alarm.alarmID, kind: alarm.kind, label: alarm.label,
          fireDate: alarm.fireDate, hour: alarm.hour, minute: alarm.minute,
          weekdays: alarm.weekdays, durationSeconds: alarm.durationSeconds, state: alarm.state)))
  }
}
