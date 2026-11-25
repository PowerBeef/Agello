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

  private final class PhaseAMockBackend: PersonalContextBackend, @unchecked Sendable {
    let events: [CalendarEventSummary]
    let contacts: [ContactSummary]
    init(events: [CalendarEventSummary] = [], contacts: [ContactSummary] = []) {
      self.events = events
      self.contacts = contacts
    }
    func searchCalendarEvents(
      start: Date, end: Date, query: String?
    ) async -> PersonalToolResult<[CalendarEventSummary]> {
      let matched = events.filter { event in
        let inWindow = event.endDate >= start && event.startDate <= end
        guard inWindow else { return false }
        guard let q = query, !q.isEmpty else { return true }
        return event.title.localizedCaseInsensitiveContains(q)
      }
      return .success(matched)
    }
    func createCalendarEvent(
      title: String, start: Date, end: Date, location: String?, notes: String?
    ) async -> PersonalToolResult<CalendarEventSummary> { .error("unused") }
    func listReminders(
      includeCompleted: Bool, query: String?
    ) async -> PersonalToolResult<[ReminderSummary]> { .success([]) }
    func createReminder(
      title: String, dueDate: Date?, notes: String?
    ) async -> PersonalToolResult<ReminderSummary> { .error("unused") }
    func searchContacts(query: String, limit: Int) async -> PersonalToolResult<[ContactSummary]> {
      .success(contacts.filter { $0.fullName.localizedCaseInsensitiveContains(query) })
    }
    func searchPlaces(
      query: String, near: String?, limit: Int
    ) async -> PersonalToolResult<[PlaceSummary]> { .success([]) }
    func estimateTravelTime(
      origin: String?, destination: String, transport: String
    ) async -> PersonalToolResult<TravelEstimateSummary> { .error("unused") }
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
    var tool = SearchCalendarEventsTool()
    tool.query = "Team Lunch"
    let out1 = try await tool.run() as? [String: Any]
    XCTAssertEqual(out1?["count"] as? Int, 1)
    let cards1 = ToolCardRecorder.records(since: c1)
    XCTAssertEqual(cards1.count, 1)

    // 2. Narrow today-only dates with query -> auto-widens once and still finds tomorrow's event.
    let todayStr = String(PersonalToolsLogic.formatISO(Date()).prefix(10))
    var narrow = SearchCalendarEventsTool()
    narrow.startDate = todayStr
    narrow.endDate = todayStr
    narrow.query = "Team Lunch"
    let out2 = try await narrow.run() as? [String: Any]
    XCTAssertEqual(out2?["count"] as? Int, 1)
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
