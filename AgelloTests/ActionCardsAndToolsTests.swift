@_spi(Testing) import LiteRTLMTools
import SwiftData
import Synchronization
import XCTest

@testable import Agello

/// Unit tests for Phase A Rich Action Cards, `LossyArray` forward-compatibility, `ToolCardRecorder`
/// ring-buffer bounds, `NativeActionURLs`, `ToolManager` scalar coercion & `@ToolParam(allowedValues:)`,
/// `ContextBudget` schema token accounting, multilingual POI filters, Calendar auto-widening, and
/// `PrepareMessageTool` recipient provenance.
final class ActionCardsAndToolsTests: XCTestCase {
  override func tearDown() {
    ToolBudget.reset()
    ToolCardRecorder.reset()
    ToolConfirmationGate.setTestHandler(nil)
    PersonalTools.setTestBackend(nil)
    TurnContactRoster.reset()
    super.tearDown()
  }

  // MARK: - ActionCards & LossyArray persistence

  func testMessagePartsActionCardsRoundTripAndForwardCompat() throws {
    let now = Date(timeIntervalSince1970: 1_795_564_800)
    let cards: [ActionCardRecord] = [
      ActionCardRecord(
        payload: .places(
          PlacesCard(
            query: "gas station",
            areaLabel: nil,
            places: [
              PlacesCard.PlaceItem(
                name: "Esso", category: "gas station", address: "123 Rue Peel",
                phone: "+1 514-555-0100", websiteURL: "https://esso.ca",
                latitude: 45.5017, longitude: -73.5673, distanceMeters: 645,
                mapItemIdentifier: "I12345")
            ]))),
      ActionCardRecord(
        payload: .route(
          RouteCard(
            originName: "Current location", originLatitude: 45.5017, originLongitude: -73.5673,
            originIsCurrentLocation: true, destinationName: "Bistro Peel",
            destinationAddress: "456 Rue Peel", destinationLatitude: 45.5025,
            destinationLongitude: -73.5690, destinationMapItemIdentifier: nil,
            transport: "driving", distanceMeters: 1_200, expectedTravelSeconds: 240,
            routeName: "Rue Peel",
            steps: [.init(id: 0, instruction: "Head north on Rue Peel", distanceMeters: 400)]))),
      ActionCardRecord(
        payload: .calendarEvent(
          CalendarEventCard(
            status: .created, eventIdentifier: "ev-1", title: "Team Lunch",
            startDate: now, endDate: now.addingTimeInterval(3_600), isAllDay: false,
            location: "Bistro Peel", calendarName: "Work"))),
      ActionCardRecord(
        payload: .reminder(
          ReminderCard(
            status: .created, reminderIdentifier: "rem-1", title: "Call John",
            dueDate: now, listName: "Reminders", isCompleted: false))),
      ActionCardRecord(
        payload: .contact(
          ContactCard(
            contactIdentifier: "c-1", fullName: "John Appleseed", organization: "Apple",
            phones: ["+1 888-555-5512"], emails: ["john@example.com"],
            postalAddress: "1 Infinite Loop, Cupertino, CA"))),
      ActionCardRecord(
        payload: .messageDraft(
          MessageDraftCard(
            channel: .sms, recipients: ["+1 888-555-5512"], subject: nil,
            body: "See you at 12:30!", unverifiedRecipients: []))),
    ]

    let original = MessageParts(
      toolActivity: [.init(name: "search_places", summary: "Searched Maps")],
      sources: [.init(index: 1, title: "Esso", url: "https://maps.apple.com/?q=Esso", snippet: "Peel")],
      actionCards: cards)
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(MessageParts.self, from: encoded)
    XCTAssertEqual(decoded, original)

    // Inject a future unknown card kind AND a malformed element into `actionCards`:
    // existing sources, toolActivity, and known cards must still decode cleanly.
    let forwardJSON = """
      {
        "toolActivity": [{"name": "search_places", "summary": "OK"}],
        "sources": [{"index": 1, "title": "Esso", "url": "https://maps.apple.com/?q=Esso"}],
        "actionCards": [
          {"id": "00000000-0000-0000-0000-000000000001", "payload": {"kind": "futureAlarmV9", "data": {"foo": 1}}},
          {"badObject": 42},
          {"id": "00000000-0000-0000-0000-000000000002",
           "payload": {"kind": "reminder",
                       "data": {"status": "found", "title": "Call Mom", "isCompleted": false}}}
        ]
      }
      """
    let tolerant = try JSONDecoder().decode(MessageParts.self, from: Data(forwardJSON.utf8))
    XCTAssertEqual(tolerant.sources.count, 1)
    XCTAssertEqual(tolerant.toolActivity.count, 1)
    let renderable = tolerant.actionCards.filter(\.isRenderable)
    XCTAssertEqual(renderable.count, 1)
    if case .reminder(let rem) = renderable.first?.payload {
      XCTAssertEqual(rem.title, "Call Mom")
    } else {
      XCTFail("Expected reminder card")
    }
  }

  func testActionCardsMergeDeduplicatesAndCapsAtSix() {
    let initial = [
      ActionCardRecord(
        payload: .places(
          PlacesCard(
            query: "gas", areaLabel: nil,
            places: [.init(name: "Esso", latitude: 45.5, longitude: -73.5)])))
    ]
    let dup = ActionCardRecord(
      payload: .places(
        PlacesCard(
          query: "gas", areaLabel: "Downtown",
          places: [.init(name: "Esso", latitude: 45.5, longitude: -73.5, distanceMeters: 500)])))
    let extras = (0..<8).map { i in
      ActionCardRecord(
        payload: .reminder(
          ReminderCard(status: .found, title: "Item \(i)", isCompleted: false)))
    }
    let merged = ActionCards.merge(initial, [dup] + extras)
    XCTAssertEqual(merged.count, ActionCards.maxPerTurn)
    if case .places(let updated) = merged.first?.payload {
      XCTAssertEqual(updated.areaLabel, "Downtown", "Later duplicate should replace earlier card")
    } else {
      XCTFail("Expected places card first")
    }
  }

  func testToolCardRecorderRingBufferIsBounded() {
    let startCursor = ToolCardRecorder.cursor
    for i in 0..<100 {
      ToolCardRecorder.record(
        .reminder(ReminderCard(status: .found, title: "Task \(i)", isCompleted: false)))
    }
    let recent = ToolCardRecorder.records(since: startCursor)
    XCTAssertEqual(recent.count, ToolCardRecorder.capacity)
    if case .reminder(let firstKept) = recent.first?.payload,
      case .reminder(let lastKept) = recent.last?.payload
    {
      XCTAssertEqual(firstKept.title, "Task 36")
      XCTAssertEqual(lastKept.title, "Task 99")
    } else {
      XCTFail("Expected reminder cards")
    }
  }

  // MARK: - NativeActionURLs (App Store 2.5.1 hygiene)

  func testNativeActionURLsSanitizeAndBlockUnsafeSchemes() {
    XCTAssertEqual(NativeActionURLs.phone("+1 (514) 555-0199")?.absoluteString, "tel:+15145550199")
    XCTAssertNil(NativeActionURLs.phone("12"))
    XCTAssertEqual(NativeActionURLs.sms(recipient: "514-555-0199")?.scheme, "sms")
    XCTAssertEqual(NativeActionURLs.facetime("john@example.com")?.absoluteString, "facetime:john@example.com")
    XCTAssertEqual(
      NativeActionURLs.mailto(recipients: ["john@example.com"], subject: "Hi")?.scheme, "mailto")
    XCTAssertNil(NativeActionURLs.mailto(recipients: ["not an email"]))
    XCTAssertEqual(NativeActionURLs.website("https://example.org")?.host(), "example.org")
    XCTAssertNil(NativeActionURLs.website("javascript:alert(1)"))
    XCTAssertNil(NativeActionURLs.website("calshow:12345"))

    let cycling = NativeActionURLs.appleMapsDirections(
      destinationName: "Bistro", destinationLatitude: 45.5, destinationLongitude: -73.5,
      transport: "cycling")
    XCTAssertTrue(cycling?.absoluteString.contains("dirflg=c") ?? false)

    let ics = NativeActionURLs.icsString(
      for: CalendarEventCard(
        status: .created, eventIdentifier: "id-1", title: "Lunch; Team, Inc.",
        startDate: Date(timeIntervalSince1970: 1_795_564_800),
        endDate: Date(timeIntervalSince1970: 1_795_568_400),
        isAllDay: false, location: "Montreal, QC", calendarName: nil))
    XCTAssertTrue(ics.contains("BEGIN:VEVENT"))
    XCTAssertTrue(ics.contains(#"SUMMARY:Lunch\; Team\, Inc."#))

    let vcf = NativeActionURLs.vCardString(
      for: ContactCard(
        fullName: "John Appleseed", organization: "Apple", phones: ["+15145550100"],
        emails: ["john@example.com"], postalAddress: "1 Infinite Loop"))
    XCTAssertTrue(vcf.contains("BEGIN:VCARD"))
    XCTAssertTrue(vcf.contains("TEL;TYPE=CELL:+15145550100"))
  }

  // MARK: - ToolManager scalar coercion & @ToolParam(allowedValues:) (B7 & B8)

  func testToolParamEnumAndScalarCoercion() async throws {
    let tools: [any Tool] = [
      EstimateTravelTimeTool(),
      ListRemindersTool(),
      ConvertUnitsTool(),
      PrepareMessageTool(),
    ]
    let manager = ToolManager(tools: tools)
    XCTAssertTrue(manager.toolsJsonDescription.contains(#""enum""#))
    XCTAssertTrue(manager.toolsJsonDescription.contains("cycling"))

    // Stringified Double & Bool coercion via ToolManager.execute
    let converted = try await manager.execute(
      name: ConvertUnitsTool.name,
      arguments: ["value": "44", "fromUnit": "km", "toUnit": "mi"]) as? [String: Any]
    let miles = try XCTUnwrap(converted?["result"] as? Double)
    XCTAssertEqual(miles, 27.3403, accuracy: 0.01)

    XCTAssertEqual(ToolManager.coerceArgument("5", expectedType: "integer") as? Int, 5)
    XCTAssertEqual(ToolManager.coerceArgument("5.0", expectedType: "integer") as? Int, 5)
    XCTAssertEqual(ToolManager.coerceArgument("true", expectedType: "boolean") as? Bool, true)
    XCTAssertEqual(ToolManager.coerceArgument("false", expectedType: "boolean") as? Bool, false)
    XCTAssertEqual(ToolManager.coerceArgument("12.5", expectedType: "number") as? Double, 12.5)
  }

  func testActiveToolsGatesQueryTableAndContextBudgetMeasuresSchemaTokens() {
    var noFiles = InferenceOptions()
    noFiles.workspaceFileTools = false
    let baseTools = ActiveTools.make(toolsEnabled: true, options: noFiles)
    XCTAssertFalse(baseTools.contains { type(of: $0).name == QueryTableOrJsonTool.name })

    var withFiles = InferenceOptions()
    withFiles.workspaceFileTools = true
    let fileTools = ActiveTools.make(toolsEnabled: true, options: withFiles)
    XCTAssertTrue(fileTools.contains { type(of: $0).name == QueryTableOrJsonTool.name })

    let schemaJSON = ToolManager(tools: fileTools).toolsJsonDescription
    let schemaTokens = ContextBudget.estimateToolSchemaTokens(schemaJSON)
    XCTAssertGreaterThan(schemaTokens, 500)
    XCTAssertEqual(ContextBudget.estimateToolSchemaTokens("[]"), 0)
    let exactPreamble = ContextBudget.preambleTokens(
      systemPrompt: SystemPrompt.base, toolCount: fileTools.count, toolSchemaTokens: schemaTokens)
    let emptyPreamble = ContextBudget.preambleTokens(
      systemPrompt: SystemPrompt.base, toolCount: 0, toolSchemaTokens: 0)
    XCTAssertEqual(exactPreamble - emptyPreamble, schemaTokens)
  }

  // MARK: - Multilingual POI category inference & cycling (B3 & B4)

  func testMultilingualPOICategoryInferenceAndCycling() {
    XCTAssertEqual(LanguageSupport.placePOICategory(for: "nearest gas station"), "gasStation")
    XCTAssertEqual(LanguageSupport.placePOICategory(for: "station-service la plus proche"), "gasStation")
    XCTAssertEqual(LanguageSupport.placePOICategory(for: "pharmacie"), "pharmacy")
    XCTAssertEqual(LanguageSupport.placePOICategory(for: "coffee shop"), "cafe")
    XCTAssertEqual(LanguageSupport.placePOICategory(for: "borne de recharge"), "evCharger")
    XCTAssertEqual(LanguageSupport.placePOICategory(for: "ガソリンスタンド"), "gasStation")
    // Specific brand names must stay unfiltered.
    XCTAssertNil(LanguageSupport.placePOICategory(for: "Walmart"))
    XCTAssertNil(LanguageSupport.placePOICategory(for: "Starbucks"))

    XCTAssertEqual(LanguageSupport.normalizeTransportMode("cycling"), "cycling")
    XCTAssertEqual(LanguageSupport.normalizeTransportMode("vélo"), "cycling")
    XCTAssertEqual(LanguageSupport.normalizeTransportMode("Fahrrad"), "cycling")
    XCTAssertEqual(LanguageSupport.normalizeTransportMode("自転車"), "cycling")
  }

  // MARK: - Calendar default range & auto-widening (B6) + PrepareMessage provenance

  private struct PhaseAMockState: Sendable {
    var events: [CalendarEventSummary] = []
    var reminders: [ReminderSummary] = []
    var contacts: [ContactSummary] = []
    var alarms: [AlarmSummary] = []
    var weather: WeatherSummary?
  }

  private final class PhaseAMockBackend: PersonalContextBackend, @unchecked Sendable {
    let state = Mutex<PhaseAMockState>(PhaseAMockState())

    init(
      events: [CalendarEventSummary] = [], reminders: [ReminderSummary] = [],
      contacts: [ContactSummary] = [], alarms: [AlarmSummary] = [], weather: WeatherSummary? = nil
    ) {
      state.withLock {
        $0.events = events
        $0.reminders = reminders
        $0.contacts = contacts
        $0.alarms = alarms
        $0.weather = weather
      }
    }

    func searchCalendarEvents(
      start: Date, end: Date, query: String?
    ) async -> PersonalToolResult<[CalendarEventSummary]> {
      let matched = state.withLock { $0.events }.filter { event in
        let inWindow = event.endDate >= start && event.startDate <= end
        guard inWindow else { return false }
        guard let q = query, !q.isEmpty else { return true }
        return event.title.localizedCaseInsensitiveContains(q)
      }
      return .success(matched)
    }

    func fetchCalendarEvent(identifier: String) async -> PersonalToolResult<CalendarEventSummary> {
      guard let event = state.withLock({ $0.events.first { $0.eventIdentifier == identifier } }) else {
        return .error("Calendar event not found for that id.")
      }
      return .success(event)
    }

    func createCalendarEvent(
      title: String, start: Date, end: Date, location: String?, notes: String?
    ) async -> PersonalToolResult<CalendarEventSummary> {
      let created = CalendarEventSummary(
        eventIdentifier: "ev-new", title: title, startDate: start, endDate: end, isAllDay: false,
        location: location, calendarName: "Test", notes: notes)
      state.withLock { $0.events.append(created) }
      return .success(created)
    }

    func updateCalendarEvent(
      identifier: String, mutation: CalendarEventMutation
    ) async -> PersonalToolResult<CalendarEventSummary> {
      state.withLock { s in
        guard let idx = s.events.firstIndex(where: { $0.eventIdentifier == identifier }) else {
          return .error("Not found")
        }
        if let title = mutation.title { s.events[idx].title = title }
        if let start = mutation.startDate { s.events[idx].startDate = start }
        if let end = mutation.endDate { s.events[idx].endDate = end }
        if let loc = mutation.location { s.events[idx].location = loc }
        return .success(s.events[idx])
      }
    }

    func deleteCalendarEvent(identifier: String) async -> PersonalToolResult<CalendarEventSummary> {
      state.withLock { s in
        guard let idx = s.events.firstIndex(where: { $0.eventIdentifier == identifier }) else {
          return .error("Not found")
        }
        return .success(s.events.remove(at: idx))
      }
    }

    func listReminders(
      includeCompleted: Bool, query: String?
    ) async -> PersonalToolResult<[ReminderSummary]> {
      .success(state.withLock { $0.reminders }.filter { includeCompleted || !$0.isCompleted })
    }

    func fetchReminder(identifier: String) async -> PersonalToolResult<ReminderSummary> {
      guard let item = state.withLock({ $0.reminders.first { $0.reminderIdentifier == identifier } }) else {
        return .error("Reminder not found for that id.")
      }
      return .success(item)
    }

    func createReminder(
      title: String, dueDate: Date?, notes: String?
    ) async -> PersonalToolResult<ReminderSummary> {
      let item = ReminderSummary(
        reminderIdentifier: "rem-new", title: title, dueDate: dueDate, isCompleted: false,
        listName: "Test", notes: notes)
      state.withLock { $0.reminders.append(item) }
      return .success(item)
    }

    func setReminderCompleted(
      identifier: String, completed: Bool
    ) async -> PersonalToolResult<ReminderSummary> {
      state.withLock { s in
        guard let idx = s.reminders.firstIndex(where: { $0.reminderIdentifier == identifier }) else {
          return .error("Not found")
        }
        s.reminders[idx].isCompleted = completed
        return .success(s.reminders[idx])
      }
    }

    func deleteReminder(identifier: String) async -> PersonalToolResult<ReminderSummary> {
      state.withLock { s in
        guard let idx = s.reminders.firstIndex(where: { $0.reminderIdentifier == identifier }) else {
          return .error("Not found")
        }
        return .success(s.reminders.remove(at: idx))
      }
    }

    func searchContacts(query: String, limit: Int) async -> PersonalToolResult<[ContactSummary]> {
      .success(state.withLock { $0.contacts }.filter { $0.fullName.localizedCaseInsensitiveContains(query) })
    }

    func searchPlaces(
      query: String, near: String?, limit: Int
    ) async -> PersonalToolResult<[PlaceSummary]> { .success([]) }

    func estimateTravelTime(
      origin: String?, destination: String, transport: String
    ) async -> PersonalToolResult<TravelEstimateSummary> { .error("unused") }

    func fetchWeather(place: String?, scope: String) async -> PersonalToolResult<WeatherSummary> {
      guard let w = state.withLock({ $0.weather }) else { return .error("No weather fixture") }
      return .success(w)
    }

    func listAlarms() async -> PersonalToolResult<[AlarmSummary]> {
      .success(state.withLock { $0.alarms })
    }

    func scheduleTimer(label: String, durationSeconds: Double) async -> PersonalToolResult<AlarmSummary> {
      let item = AlarmSummary(
        alarmID: "alm-timer-1", kind: .timer, label: label,
        fireDate: Date().addingTimeInterval(durationSeconds), durationSeconds: durationSeconds,
        state: .countdown)
      state.withLock { $0.alarms.append(item) }
      return .success(item)
    }

    func scheduleAlarm(
      label: String, hour: Int, minute: Int, weekdays: [String]
    ) async -> PersonalToolResult<AlarmSummary> {
      let item = AlarmSummary(
        alarmID: "alm-wake-1", kind: .alarm, label: label, hour: hour, minute: minute,
        weekdays: weekdays, state: .scheduled)
      state.withLock { $0.alarms.append(item) }
      return .success(item)
    }

    func cancelAlarm(identifier: String) async -> PersonalToolResult<AlarmSummary> {
      state.withLock { s in
        guard let idx = s.alarms.firstIndex(where: { $0.alarmID == identifier }) else {
          return .error("Not found")
        }
        var cancelled = s.alarms.remove(at: idx)
        cancelled.state = .cancelled
        return .success(cancelled)
      }
    }
  }

  func testSearchCalendarDefaultsAndAutoWidenFindsTomorrowEvent() async throws {
    let tomorrowStart = Date().addingTimeInterval(26 * 3_600)
    let event = CalendarEventSummary(
      eventIdentifier: "ev-lunch", title: "Team Lunch",
      startDate: tomorrowStart, endDate: tomorrowStart.addingTimeInterval(3_600),
      isAllDay: false, location: "Bistro")
    PersonalTools.setTestBackend(PhaseAMockBackend(events: [event]))

    // 1. Omitted dates with query -> defaults to -7d...+30d and finds tomorrow's event + emits card.
    let c1 = ToolCardRecorder.cursor
    var tool = ReadCalendarTool()
    tool.mode = "events"
    tool.query = "Team Lunch"
    let out1 = try await tool.run() as? [String: Any]
    XCTAssertEqual(out1?["count"] as? Int, 1)
    let cards1 = ToolCardRecorder.records(since: c1)
    XCTAssertEqual(cards1.count, 1)

    // 2. Narrow today-only dates with query -> auto-widens once and still finds tomorrow's event.
    let todayStr = String(PersonalToolsLogic.formatISO(Date()).prefix(10))
    var narrow = ReadCalendarTool()
    narrow.mode = "events"
    narrow.startDate = todayStr
    narrow.endDate = todayStr
    narrow.query = "Team Lunch"
    let out2 = try await narrow.run() as? [String: Any]
    XCTAssertEqual(out2?["count"] as? Int, 1)
  }

  // MARK: - Phase B: Authoritative EventKit CRUD, Weather, AlarmKit, ThermalPolicy, Focus Filter

  func testManageCalendarDeleteRejectsFakeIDAndShowsAuthoritativeDestructiveConfirmation() async throws {
    let start = Date().addingTimeInterval(3_600)
    let realEvent = CalendarEventSummary(
      eventIdentifier: "ev-real-42", title: "Board Review",
      startDate: start, endDate: start.addingTimeInterval(3_600), isAllDay: false, calendarName: "Work")
    let backend = PhaseAMockBackend(events: [realEvent])
    PersonalTools.setTestBackend(backend)

    // Fake ID must fail before confirmation is ever presented.
    let promptCount = Mutex(0)
    ToolConfirmationGate.setTestHandler { _ in
      promptCount.withLock { $0 += 1 }
      return .approved
    }
    var fakeDelete = ManageCalendarEventTool()
    fakeDelete.action = "delete"
    fakeDelete.id = "ev-nonexistent"
    let fakeOut = try await fakeDelete.run() as? [String: Any]
    XCTAssertEqual(fakeOut?["executed"] as? Bool, false)
    XCTAssertEqual(promptCount.withLock { $0 }, 0)

    // Real ID surfaces authoritative title ("Board Review") with `.destructive` RiskTier.
    let captured = Mutex<ToolConfirmationRequest?>(nil)
    ToolConfirmationGate.setTestHandler { req in
      captured.withLock { $0 = req }
      return .approved
    }
    var realDelete = ManageCalendarEventTool()
    realDelete.action = "delete"
    realDelete.id = "ev-real-42"
    let realOut = try await realDelete.run() as? [String: Any]
    XCTAssertEqual(realOut?["executed"] as? Bool, true)
    let req = try XCTUnwrap(captured.withLock { $0 })
    XCTAssertEqual(req.risk, .destructive)
    XCTAssertEqual(req.parameters.first(where: { $0.name == "event" })?.value, "Board Review")
    XCTAssertTrue(backend.state.withLock { $0.events.isEmpty })

    // A read (.found) followed by a delete (.deleted) for the same event collapses to one card.
    let foundCard = ActionCardRecord(
      payload: .calendarEvent(
        CalendarEventCard(
          status: .found, eventIdentifier: "ev-real-42", title: "Board Review",
          startDate: start, endDate: start.addingTimeInterval(3_600), isAllDay: false)))
    let deletedCard = ActionCardRecord(
      payload: .calendarEvent(
        CalendarEventCard(
          status: .deleted, eventIdentifier: "ev-real-42", title: "Board Review",
          startDate: start, endDate: start.addingTimeInterval(3_600), isAllDay: false)))
    let merged = ActionCards.merge([foundCard], [deletedCard])
    XCTAssertEqual(merged.count, 1)
    if case .calendarEvent(let c) = merged.first?.payload {
      XCTAssertEqual(c.status, .deleted)
    } else {
      XCTFail("Expected collapsed deleted calendar card")
    }

    // Verify snake_case JSON decoding via ToolManager (catches any camelCase acronym mismatches).
    let manager = ToolManager(tools: [
      ReadCalendarTool(), ManageCalendarEventTool(), ManageReminderTool(),
      GetWeatherTool(), ListAlarmsTool(), ManageAlarmTool(),
    ])
    let created = try await manager.execute(
      name: "manage_calendar_event",
      arguments: [
        "action": "create",
        "title": "Team Sync",
        "start_date": "2026-12-02T10:00:00",
        "end_date": "2026-12-02T11:00:00",
      ]) as? [String: Any]
    XCTAssertEqual(created?["executed"] as? Bool, true)
    let reminderCreated = try await manager.execute(
      name: "manage_reminder",
      arguments: ["action": "create", "title": "Buy coffee"]) as? [String: Any]
    XCTAssertEqual(reminderCreated?["executed"] as? Bool, true)
    let timerCreated = try await manager.execute(
      name: "manage_alarm",
      arguments: ["action": "set_timer", "label": "Tea", "duration_seconds": 180]) as? [String: Any]
    XCTAssertEqual(timerCreated?["executed"] as? Bool, true)
  }

  func testWeatherAndAlarmToolsEmitCardsAndNormalizeWeekdays() async throws {
    let wxCard = WeatherCard(
      locationName: "Montréal, QC", temperature: "-2°C", feelsLike: "-7°C",
      condition: "Snow", conditionSymbol: "cloud.snow.fill", high: "0°C", low: "-5°C",
      humidityPercent: 80, windSpeed: "18 km/h", hourly: [], daily: [],
      alerts: [.init(summary: "Winter Weather Advisory", severity: "moderate", detailsURL: nil)],
      attributionLegalURL: "https://weatherkit.apple.com/legal-attribution.html")
    let backend = PhaseAMockBackend(
      weather: WeatherSummary(locationName: "Montréal, QC", description: "Snow, -2°C", card: wxCard))
    PersonalTools.setTestBackend(backend)

    let cWx = ToolCardRecorder.cursor
    var wxTool = GetWeatherTool()
    wxTool.place = "Montreal"
    let wxOut = try await wxTool.run() as? [String: Any]
    XCTAssertEqual(wxOut?["alerts_count"] as? Int, 1)
    let wxRecords = ToolCardRecorder.records(since: cWx)
    XCTAssertEqual(wxRecords.count, 1)
    if case .weather(let card) = wxRecords.first?.payload {
      XCTAssertEqual(card.locationName, "Montréal, QC")
    } else {
      XCTFail("Expected weather card")
    }

    // AlarmKit timer + weekly alarm with multilingual weekdays.
    XCTAssertEqual(PersonalToolsLogic.normalizeWeekdays(["lundi", "Wed", "vendredi"]), ["mon", "wed", "fri"])
    XCTAssertEqual(PersonalToolsLogic.normalizeWeekdays(["weekdays"]), ["mon", "tue", "wed", "thu", "fri"])

    ToolConfirmationGate.setTestHandler { _ in .approved }
    let cAlarm = ToolCardRecorder.cursor
    var alarmTool = ManageAlarmTool()
    alarmTool.action = "set_alarm"
    alarmTool.label = "Morning Run"
    alarmTool.hour = 6
    alarmTool.minute = 30
    alarmTool.weekdays = ["mon", "wed", "fri"]
    let alarmOut = try await alarmTool.run() as? [String: Any]
    XCTAssertEqual(alarmOut?["executed"] as? Bool, true)
    let alarmRecords = ToolCardRecorder.records(since: cAlarm)
    XCTAssertEqual(alarmRecords.count, 1)
    if case .alarm(let card) = alarmRecords.first?.payload {
      XCTAssertEqual(card.label, "Morning Run")
      XCTAssertEqual(card.weekdays, ["mon", "wed", "fri"])
    } else {
      XCTFail("Expected alarm card")
    }

    // Round-trip WeatherCard + AlarmCard through MessageParts LossyArray JSON.
    let parts = MessageParts(actionCards: wxRecords + alarmRecords)
    let encoded = try JSONEncoder().encode(parts)
    let decoded = try JSONDecoder().decode(MessageParts.self, from: encoded)
    XCTAssertEqual(decoded.actionCards.count, 2)
  }

  @MainActor
  func testThermalPolicyExtractionSchemaAndFocusFilterOverrides() {
    let nominal = ThermalPolicy.guidance(for: .init(thermalState: .nominal, lowPowerMode: false))
    XCTAssertEqual(nominal.streamFlushInterval, .milliseconds(100))
    XCTAssertFalse(nominal.deferBackgroundChatIndexing)
    XCTAssertFalse(nominal.pauseBackgroundANE)

    let serious = ThermalPolicy.guidance(for: .init(thermalState: .serious, lowPowerMode: false))
    XCTAssertEqual(serious.streamFlushInterval, .milliseconds(200))
    XCTAssertTrue(serious.deferBackgroundChatIndexing)
    XCTAssertFalse(serious.pauseBackgroundANE)

    let lpm = ThermalPolicy.guidance(for: .init(thermalState: .nominal, lowPowerMode: true))
    XCTAssertEqual(lpm.streamFlushInterval, .milliseconds(200))
    XCTAssertTrue(lpm.deferBackgroundChatIndexing)

    let critical = ThermalPolicy.guidance(for: .init(thermalState: .critical, lowPowerMode: false))
    XCTAssertEqual(critical.streamFlushInterval, .milliseconds(250))
    XCTAssertNil(critical.helperIdleDelay)
    XCTAssertTrue(critical.pauseBackgroundANE)

    // Structured extraction schema builder deduplicates fields and emits strict JSON Schema.
    let spec = HelperTasks.extractionSchema(fields: ["vendor", " total ", "vendor", ""])
    XCTAssertEqual(spec?.fields, ["vendor", "total"])
    XCTAssertTrue(spec?.schemaJSON.contains("\"additionalProperties\":false") ?? false)

    // Focus Filter suppresses personal tools in effectiveOptions without overwriting user settings.
    let appState = AppState(useMockEngine: true)
    appState.personalTools = PersonalToolsSettings(calendar: true, maps: true, weather: true, alarms: true)
    appState.focusFilter = FocusFilterOverrides(hidePersonalTools: true)
    XCTAssertFalse(appState.effectiveOptions.personalTools.anyEnabled)
    XCTAssertTrue(appState.personalTools.calendar)
  }

  func testPrepareMessageChecksProvenanceAndFailsClosed() async throws {
    XCTAssertFalse(PrepareMessageTool.isReadOnly)
    let john = ContactSummary(
      contactIdentifier: "c-john", fullName: "John Appleseed",
      phones: ["+1 888-555-5512"], emails: ["john@example.com"])
    PersonalTools.setTestBackend(PhaseAMockBackend(contacts: [john]))

    // Fetch John first so TurnContactRoster verifies his phone/email.
    var lookup = SearchContactsTool()
    lookup.query = "John"
    _ = try await lookup.run()

    // Denied -> zero draft cards recorded.
    ToolConfirmationGate.setTestHandler { _ in .denied(reason: "Denied.") }
    let cDenied = ToolCardRecorder.cursor
    var draft = PrepareMessageTool()
    draft.channel = "email"
    draft.recipients = ["john@example.com", "exfil@evil.example"]
    draft.subject = "Hello"
    draft.body = "Lunch at 12:30?"
    let deniedOut = try await draft.run() as? [String: Any]
    XCTAssertEqual(deniedOut?["executed"] as? Bool, false)
    XCTAssertTrue(ToolCardRecorder.records(since: cDenied).isEmpty)

    // Approved -> records MessageDraftCard flagging only the unverified attacker address.
    ToolConfirmationGate.setTestHandler { _ in .approved }
    let cApproved = ToolCardRecorder.cursor
    let approvedOut = try await draft.run() as? [String: Any]
    XCTAssertEqual(approvedOut?["executed"] as? Bool, true)
    let cards = ToolCardRecorder.records(since: cApproved)
    XCTAssertEqual(cards.count, 1)
    if case .messageDraft(let card) = cards.first?.payload {
      XCTAssertEqual(card.unverifiedRecipients, ["exfil@evil.example"])
    } else {
      XCTFail("Expected messageDraft card")
    }
  }

  @MainActor
  func testAppStatePersistsStreamedActionCards() async throws {
    let container = try ModelContainer(
      for: ChatStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = ModelContext(container)
    let appState = AppState(useMockEngine: true)
    appState.modelContext = context
    let mock = try XCTUnwrap(appState.engine as? MockChatEngine)
    let placeCard = ActionCardRecord(
      payload: .places(
        PlacesCard(
          query: "gas station", areaLabel: nil,
          places: [.init(name: "Esso", latitude: 45.5, longitude: -73.5, distanceMeters: 420)])))
    await mock.setScriptChunks([
      ChatChunk(textDelta: "The nearest gas station is Esso.", actionCards: [placeCard])
    ])

    let thread = appState.newThread(in: context)
    await appState.send(text: "Nearest gas station?", imageData: nil, audioFileURL: nil, in: thread)
    let reply = try XCTUnwrap(thread.orderedTurns.last)
    XCTAssertEqual(reply.parts.actionCards, [placeCard])
  }
}
