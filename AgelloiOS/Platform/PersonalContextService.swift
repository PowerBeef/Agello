import AlarmKit
import Contacts
import CoreLocation
import EventKit
import Foundation
import ImageIO
import MapKit
import Photos
import SwiftUI
import Vision

/// Serializes all non-UI EventKit reads and writes onto a dedicated actor owning its own
/// `EKEventStore`, preventing concurrent background tool calls and `@MainActor` sheets from
/// sharing a non-thread-safe `EKEventStore` instance.
private actor EventKitStoreActor {
  private let eventStore = EKEventStore()

  private func ensureCalendarAccess() async -> String? {
    let status = EKEventStore.authorizationStatus(for: .event)
    switch status {
    case .fullAccess:
      return nil
    case .notDetermined:
      let granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
      return granted ? nil : "Calendar access was denied. Enable it in Settings > Agello."
    default:
      return "Calendar access is not enabled. Enable Full Calendar Access in Settings > Agello."
    }
  }

  private func eventSummary(from event: EKEvent) -> CalendarEventSummary {
    CalendarEventSummary(
      eventIdentifier: event.eventIdentifier,
      title: event.title ?? "Untitled",
      startDate: event.startDate,
      endDate: event.endDate,
      isAllDay: event.isAllDay,
      location: event.location,
      calendarName: event.calendar?.title,
      notes: event.notes)
  }

  private func recurrenceRule(for raw: String?) -> EKRecurrenceRule? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
      return nil
    }
    let frequency: EKRecurrenceFrequency
    switch raw {
    case "daily": frequency = .daily
    case "weekly": frequency = .weekly
    case "monthly": frequency = .monthly
    case "yearly": frequency = .yearly
    default: return nil
    }
    return EKRecurrenceRule(recurrenceWith: frequency, interval: 1, end: nil)
  }

  func searchCalendarEvents(
    start: Date, end: Date, query: String?
  ) async -> PersonalToolResult<[CalendarEventSummary]> {
    if let err = await ensureCalendarAccess() { return .error(err) }
    let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
    let raw = eventStore.events(matching: predicate)
    let filter = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let filtered = raw.filter { event in
      guard !filter.isEmpty else { return true }
      let haystack = [event.title, event.location, event.notes]
        .compactMap { $0 }.joined(separator: " ")
      return haystack.localizedCaseInsensitiveContains(filter)
    }
    let summaries = filtered.sorted { $0.startDate < $1.startDate }.prefix(40).map(eventSummary(from:))
    return .success(Array(summaries))
  }

  func fetchCalendarEvent(identifier: String) async -> PersonalToolResult<CalendarEventSummary> {
    if let err = await ensureCalendarAccess() { return .error(err) }
    guard let event = eventStore.event(withIdentifier: identifier) else {
      return .error("Calendar event not found for that id.")
    }
    return .success(eventSummary(from: event))
  }

  func createCalendarEvent(
    title: String, start: Date, end: Date, location: String?, notes: String?,
    alarmMinutesBefore: Int?, recurrence: String?
  ) async -> PersonalToolResult<CalendarEventSummary> {
    if let err = await ensureCalendarAccess() { return .error(err) }
    guard let calendar = eventStore.defaultCalendarForNewEvents else {
      return .error("No default writable calendar is configured on this device.")
    }
    let event = EKEvent(eventStore: eventStore)
    event.calendar = calendar
    event.title = title
    event.startDate = start
    event.endDate = end
    if let location, !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      event.structuredLocation = EKStructuredLocation(title: location)
      event.location = location
    }
    event.notes = notes
    if let minutes = alarmMinutesBefore, minutes >= 0 {
      event.addAlarm(EKAlarm(relativeOffset: -TimeInterval(minutes * 60)))
    }
    if let rule = recurrenceRule(for: recurrence) {
      event.addRecurrenceRule(rule)
    }
    do {
      try eventStore.save(event, span: .thisEvent, commit: true)
      return .success(eventSummary(from: event))
    } catch {
      return .error("Could not save calendar event: \(error.localizedDescription)")
    }
  }

  func updateCalendarEvent(
    identifier: String, mutation: CalendarEventMutation
  ) async -> PersonalToolResult<CalendarEventSummary> {
    if let err = await ensureCalendarAccess() { return .error(err) }
    guard let event = eventStore.event(withIdentifier: identifier) else {
      return .error("Calendar event not found for that id.")
    }
    if let title = mutation.title { event.title = title }
    if let start = mutation.startDate { event.startDate = start }
    if let end = mutation.endDate { event.endDate = end }
    if let location = mutation.location {
      event.location = location
      event.structuredLocation = location.isEmpty ? nil : EKStructuredLocation(title: location)
    }
    if let notes = mutation.notes { event.notes = notes }
    if let minutes = mutation.alarmMinutesBefore, minutes >= 0 {
      event.alarms = [EKAlarm(relativeOffset: -TimeInterval(minutes * 60))]
    }
    if let recurrence = mutation.recurrence {
      if recurrence == "none" {
        event.recurrenceRules = nil
      } else if let rule = recurrenceRule(for: recurrence) {
        event.recurrenceRules = [rule]
      }
    }
    do {
      try eventStore.save(event, span: .thisEvent, commit: true)
      return .success(eventSummary(from: event))
    } catch {
      return .error("Could not update calendar event: \(error.localizedDescription)")
    }
  }

  func deleteCalendarEvent(identifier: String) async -> PersonalToolResult<CalendarEventSummary> {
    if let err = await ensureCalendarAccess() { return .error(err) }
    guard let event = eventStore.event(withIdentifier: identifier) else {
      return .error("Calendar event not found for that id.")
    }
    let snapshot = eventSummary(from: event)
    do {
      try eventStore.remove(event, span: .thisEvent, commit: true)
      return .success(snapshot)
    } catch {
      return .error("Could not delete calendar event: \(error.localizedDescription)")
    }
  }

  private func ensureRemindersAccess() async -> String? {
    let status = EKEventStore.authorizationStatus(for: .reminder)
    switch status {
    case .fullAccess:
      return nil
    case .notDetermined:
      let granted = (try? await eventStore.requestFullAccessToReminders()) ?? false
      return granted ? nil : "Reminders access was denied. Enable it in Settings > Agello."
    default:
      return "Reminders access is not enabled. Enable Reminders access in Settings > Agello."
    }
  }

  private nonisolated static func reminderSummary(from item: EKReminder) -> ReminderSummary {
    ReminderSummary(
      reminderIdentifier: item.calendarItemIdentifier,
      title: item.title ?? "Untitled",
      dueDate: item.dueDateComponents?.date,
      isCompleted: item.isCompleted,
      listName: item.calendar?.title,
      priority: item.priority,
      notes: item.notes)
  }

  private func resolveReminderList(named listName: String?) -> EKCalendar? {
    if let listName, !listName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let clean = listName.trimmingCharacters(in: .whitespacesAndNewlines)
      let calendars = eventStore.calendars(for: .reminder)
      if let matched = calendars.first(where: { $0.title.localizedCaseInsensitiveCompare(clean) == .orderedSame }) {
        return matched
      }
    }
    return eventStore.defaultCalendarForNewReminders()
  }

  func listReminders(
    includeCompleted: Bool, query: String?
  ) async -> PersonalToolResult<[ReminderSummary]> {
    if let err = await ensureRemindersAccess() { return .error(err) }
    let predicate: NSPredicate = includeCompleted
      ? eventStore.predicateForReminders(in: nil)
      : eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
    let filter = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let summaries: [ReminderSummary] = await withCheckedContinuation { continuation in
      eventStore.fetchReminders(matching: predicate) { items in
        let matched = (items ?? []).filter { item in
          guard !filter.isEmpty else { return true }
          let haystack = [item.title, item.notes, item.calendar?.title].compactMap { $0 }.joined(separator: " ")
          return haystack.localizedCaseInsensitiveContains(filter)
        }
        continuation.resume(returning: Array(matched.prefix(30).map(Self.reminderSummary(from:))))
      }
    }
    return .success(summaries)
  }

  func fetchReminder(identifier: String) async -> PersonalToolResult<ReminderSummary> {
    if let err = await ensureRemindersAccess() { return .error(err) }
    guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
      return .error("Reminder not found for that id.")
    }
    return .success(Self.reminderSummary(from: reminder))
  }

  func createReminder(
    title: String, dueDate: Date?, listName: String?, notes: String?, priority: Int?
  ) async -> PersonalToolResult<ReminderSummary> {
    if let err = await ensureRemindersAccess() { return .error(err) }
    guard let list = resolveReminderList(named: listName) else {
      return .error("No default writable Reminders list is configured on this device.")
    }
    let reminder = EKReminder(eventStore: eventStore)
    reminder.calendar = list
    reminder.title = title
    reminder.notes = notes
    if let priority, (0...9).contains(priority) { reminder.priority = priority }
    if let dueDate {
      reminder.dueDateComponents = Calendar.current.dateComponents(
        [.year, .month, .day, .hour, .minute], from: dueDate)
    }
    do {
      try eventStore.save(reminder, commit: true)
      return .success(Self.reminderSummary(from: reminder))
    } catch {
      return .error("Could not save reminder: \(error.localizedDescription)")
    }
  }

  func setReminderCompleted(
    identifier: String, completed: Bool
  ) async -> PersonalToolResult<ReminderSummary> {
    if let err = await ensureRemindersAccess() { return .error(err) }
    guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
      return .error("Reminder not found.")
    }
    reminder.isCompleted = completed
    reminder.completionDate = completed ? Date() : nil
    do {
      try eventStore.save(reminder, commit: true)
      return .success(Self.reminderSummary(from: reminder))
    } catch {
      return .error("Could not update reminder: \(error.localizedDescription)")
    }
  }

  func updateReminder(
    identifier: String, mutation: ReminderMutation
  ) async -> PersonalToolResult<ReminderSummary> {
    if let err = await ensureRemindersAccess() { return .error(err) }
    guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
      return .error("Reminder not found for that id.")
    }
    if let title = mutation.title { reminder.title = title }
    if mutation.clearDueDate {
      reminder.dueDateComponents = nil
    } else if let dueDate = mutation.dueDate {
      reminder.dueDateComponents = Calendar.current.dateComponents(
        [.year, .month, .day, .hour, .minute], from: dueDate)
    }
    if let listName = mutation.listName, let targetList = resolveReminderList(named: listName) {
      reminder.calendar = targetList
    }
    if let notes = mutation.notes { reminder.notes = notes }
    if let priority = mutation.priority, (0...9).contains(priority) { reminder.priority = priority }
    if let completed = mutation.isCompleted {
      reminder.isCompleted = completed
      reminder.completionDate = completed ? Date() : nil
    }
    do {
      try eventStore.save(reminder, commit: true)
      return .success(Self.reminderSummary(from: reminder))
    } catch {
      return .error("Could not update reminder: \(error.localizedDescription)")
    }
  }

  func deleteReminder(identifier: String) async -> PersonalToolResult<ReminderSummary> {
    if let err = await ensureRemindersAccess() { return .error(err) }
    guard let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
      return .error("Reminder not found for that id.")
    }
    let snapshot = Self.reminderSummary(from: reminder)
    do {
      try eventStore.remove(reminder, commit: true)
      return .success(snapshot)
    } catch {
      return .error("Could not delete reminder: \(error.localizedDescription)")
    }
  }
}

private final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed = false

  func claim() -> Bool {
    lock.withLock {
      guard !claimed else { return false }
      claimed = true
      return true
    }
  }
}

private struct SendableContactBox: @unchecked Sendable {
  let contact: CNContact?
}

private struct SendableKeyDescriptors: @unchecked Sendable {
  let keys: [CNKeyDescriptor]
}

/// Native iOS implementation of ``PersonalContextBackend`` backed by EventKit, Contacts, MapKit,
/// WeatherKit, and AlarmKit. All queries and writes stay strictly on-device; permission is requested
/// lazily on first opted-in use.
final class PersonalContextService: PersonalContextBackend, @unchecked Sendable {
  static let shared = PersonalContextService()

  private let eventKit = EventKitStoreActor()
  private let contactStore = CNContactStore()
  private let alarmMetaLock = NSLock()

  private init() {}

  // MARK: - Calendar

  func searchCalendarEvents(
    start: Date, end: Date, query: String?
  ) async -> PersonalToolResult<[CalendarEventSummary]> {
    await eventKit.searchCalendarEvents(start: start, end: end, query: query)
  }

  func fetchCalendarEvent(identifier: String) async -> PersonalToolResult<CalendarEventSummary> {
    await eventKit.fetchCalendarEvent(identifier: identifier)
  }

  func createCalendarEvent(
    title: String, start: Date, end: Date, location: String?, notes: String?
  ) async -> PersonalToolResult<CalendarEventSummary> {
    await eventKit.createCalendarEvent(
      title: title, start: start, end: end, location: location, notes: notes,
      alarmMinutesBefore: nil, recurrence: nil)
  }

  func createCalendarEvent(
    title: String, start: Date, end: Date, location: String?, notes: String?,
    alarmMinutesBefore: Int?, recurrence: String?
  ) async -> PersonalToolResult<CalendarEventSummary> {
    await eventKit.createCalendarEvent(
      title: title, start: start, end: end, location: location, notes: notes,
      alarmMinutesBefore: alarmMinutesBefore, recurrence: recurrence)
  }

  func updateCalendarEvent(
    identifier: String, mutation: CalendarEventMutation
  ) async -> PersonalToolResult<CalendarEventSummary> {
    await eventKit.updateCalendarEvent(identifier: identifier, mutation: mutation)
  }

  func deleteCalendarEvent(identifier: String) async -> PersonalToolResult<CalendarEventSummary> {
    await eventKit.deleteCalendarEvent(identifier: identifier)
  }

  // MARK: - Reminders

  func listReminders(
    includeCompleted: Bool, query: String?
  ) async -> PersonalToolResult<[ReminderSummary]> {
    await eventKit.listReminders(includeCompleted: includeCompleted, query: query)
  }

  func fetchReminder(identifier: String) async -> PersonalToolResult<ReminderSummary> {
    await eventKit.fetchReminder(identifier: identifier)
  }

  func createReminder(
    title: String, dueDate: Date?, notes: String?
  ) async -> PersonalToolResult<ReminderSummary> {
    await eventKit.createReminder(title: title, dueDate: dueDate, listName: nil, notes: notes, priority: nil)
  }

  func createReminder(
    title: String, dueDate: Date?, listName: String?, notes: String?, priority: Int?
  ) async -> PersonalToolResult<ReminderSummary> {
    await eventKit.createReminder(
      title: title, dueDate: dueDate, listName: listName, notes: notes, priority: priority)
  }

  func setReminderCompleted(
    identifier: String, completed: Bool
  ) async -> PersonalToolResult<ReminderSummary> {
    await eventKit.setReminderCompleted(identifier: identifier, completed: completed)
  }

  func updateReminder(
    identifier: String, mutation: ReminderMutation
  ) async -> PersonalToolResult<ReminderSummary> {
    await eventKit.updateReminder(identifier: identifier, mutation: mutation)
  }

  func deleteReminder(identifier: String) async -> PersonalToolResult<ReminderSummary> {
    await eventKit.deleteReminder(identifier: identifier)
  }

  // MARK: - Contacts

  private func ensureContactsAccess() async -> String? {
    let status = CNContactStore.authorizationStatus(for: .contacts)
    switch status {
    case .authorized, .limited:
      return nil
    case .notDetermined:
      let granted = (try? await contactStore.requestAccess(for: .contacts)) ?? false
      return granted ? nil : "Contacts access was denied. Enable it in Settings > Agello."
    default:
      return "Contacts access is not enabled. Enable Contacts access in Settings > Agello."
    }
  }

  func searchContacts(query: String, limit: Int) async -> PersonalToolResult<[ContactSummary]> {
    if let err = await ensureContactsAccess() { return .error(err) }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .error("Provide a name, email, or phone number to search.") }
    let keys: [CNKeyDescriptor] = [
      CNContactIdentifierKey as CNKeyDescriptor,
      CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
      CNContactOrganizationNameKey as CNKeyDescriptor,
      CNContactPhoneNumbersKey as CNKeyDescriptor,
      CNContactEmailAddressesKey as CNKeyDescriptor,
      CNContactPostalAddressesKey as CNKeyDescriptor,
      CNContactBirthdayKey as CNKeyDescriptor,
    ]
    let capped = max(1, min(10, limit))
    do {
      let predicate = CNContact.predicateForContacts(matchingName: trimmed)
      var contacts = try contactStore.unifiedContacts(matching: predicate, keysToFetch: keys)
      if contacts.isEmpty {
        // Fallback: enumerate limited matches by organization/email/phone.
        let request = CNContactFetchRequest(keysToFetch: keys)
        var found: [CNContact] = []
        try contactStore.enumerateContacts(with: request) { contact, stop in
          let full = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
          let emails = contact.emailAddresses.map { $0.value as String }
          let phones = contact.phoneNumbers.map { $0.value.stringValue }
          let hay = ([full, contact.organizationName] + emails + phones).joined(separator: " ")
          if hay.localizedCaseInsensitiveContains(trimmed) {
            found.append(contact)
            if found.count >= capped { stop.pointee = true }
          }
        }
        contacts = found
      }
      let summaries = contacts.prefix(capped).map { contact in
        let name = CNContactFormatter.string(from: contact, style: .fullName)
          ?? contact.organizationName
        let postal: String? = contact.postalAddresses.first.map { labeled in
          CNPostalAddressFormatter.string(from: labeled.value, style: .mailingAddress)
            .replacingOccurrences(of: "\n", with: ", ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let birthday: String? = contact.birthday.flatMap { comps -> String? in
          guard let month = comps.month, let day = comps.day else { return nil }
          if let year = comps.year {
            return String(format: "%04d-%02d-%02d", year, month, day)
          }
          return String(format: "%02d-%02d", month, day)
        }
        return ContactSummary(
          contactIdentifier: contact.identifier,
          fullName: name.isEmpty ? "Unnamed contact" : name,
          organization: contact.organizationName.isEmpty ? nil : contact.organizationName,
          phones: contact.phoneNumbers.map { $0.value.stringValue },
          emails: contact.emailAddresses.map { $0.value as String },
          postalAddress: postal?.isEmpty == true ? nil : postal,
          birthday: birthday)
      }
      return .success(Array(summaries))
    } catch {
      return .error("Could not search contacts: \(error.localizedDescription)")
    }
  }

  /// Fetches a full `CNContact` off the MainActor for native `CNContactViewController` presentation.
  func fetchContact(withIdentifier identifier: String, keysToFetch: [CNKeyDescriptor]) async -> CNContact? {
    let keyBox = SendableKeyDescriptors(keys: keysToFetch)
    let boxed = await Task.detached(priority: .userInitiated) { [self] in
      let found = try? self.contactStore.unifiedContact(withIdentifier: identifier, keysToFetch: keyBox.keys)
      return SendableContactBox(contact: found)
    }.value
    return boxed.contact
  }

  // MARK: - Maps & Places (MapKit)

  func searchPlaces(
    query: String, near: String?, limit: Int
  ) async -> PersonalToolResult<[PlaceSummary]> {
    let capped = max(1, min(10, limit))
    let explicitNear = near?.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      let (places, _): ([PlaceSearch.Place], String?)
      if let explicitNear, !explicitNear.isEmpty {
        (places, _) = try await PlaceSearch.search(what: query, near: explicitNear, limit: capped)
      } else {
        let split = PlaceSearch.split(query)
        if let parsedPlace = split.place {
          (places, _) = try await PlaceSearch.search(
            what: split.what, near: parsedPlace, originalQuery: query, limit: capped)
        } else {
          // Default omitted `near` to the user's current location (B1 fix), falling back to an
          // unfiltered query only if Location permission is unavailable.
          do {
            (places, _) = try await PlaceSearch.search(
              what: query, near: "here", originalQuery: query, limit: capped)
          } catch WebSearchError.locationUnavailable {
            (places, _) = try await PlaceSearch.search(query, limit: capped)
          }
        }
      }
      let summaries = places.map { p in
        var comps = URLComponents(string: "https://maps.apple.com/")
        comps?.queryItems = [
          URLQueryItem(name: "q", value: p.name),
          URLQueryItem(name: "ll", value: String(format: "%.5f,%.5f", p.latitude, p.longitude)),
        ]
        return PlaceSummary(
          name: p.name, address: p.address, phone: p.phone, category: p.category,
          latitude: p.latitude, longitude: p.longitude, mapsURL: comps?.url?.absoluteString,
          distanceMeters: p.meters, websiteURL: p.website?.absoluteString,
          mapItemIdentifier: p.mapItemIdentifier)
      }
      return .success(summaries)
    } catch {
      return .error(error.localizedDescription)
    }
  }

  @MainActor
  func estimateTravelTime(
    origin: String?, destination: String, transport: String
  ) async -> PersonalToolResult<TravelEstimateSummary> {
    let destName = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !destName.isEmpty else { return .error("Provide a destination address or place name.") }
    guard let destItem = await PlaceSearch.find(destName, types: [.pointOfInterest, .address]) else {
      return .error("Could not locate destination '\(destName)' on Apple Maps.")
    }

    let sourceItem: MKMapItem
    let originLabel: String
    let originIsCurrentLocation: Bool
    if let origin, !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !CurrentLocation.meansHere(origin)
    {
      guard let found = await PlaceSearch.find(origin, types: [.pointOfInterest, .address]) else {
        return .error("Could not locate origin '\(origin)' on Apple Maps.")
      }
      sourceItem = found
      originLabel = found.name ?? origin
      originIsCurrentLocation = false
    } else if let here = await CurrentLocation.fetch() {
      sourceItem = MKMapItem(location: here, address: nil)
      originLabel = "Current location"
      originIsCurrentLocation = true
    } else {
      return .error("Provide an origin address or enable Location access to estimate travel from here.")
    }

    let mode = LanguageSupport.normalizeTransportMode(transport)
    let resolvedMode = mode.isEmpty ? "driving" : mode
    let transportType: MKDirectionsTransportType
    switch resolvedMode {
    case "walking": transportType = .walking
    case "cycling": transportType = .cycling
    case "transit": transportType = .transit
    default: transportType = .automobile
    }

    let request = MKDirections.Request()
    request.source = sourceItem
    request.destination = destItem
    request.transportType = transportType

    let originCoord = sourceItem.location.coordinate
    let destCoord = destItem.location.coordinate
    let destAddress = destItem.address?.fullAddress
    let destID = destItem.identifier?.rawValue

    // Per MKDirectionsTypes.h, `.transit` only supports `calculateETA()`; all other modes get
    // full turn-by-turn `MKDirections.calculate()` routes with graceful fallback to `calculateETA()`.
    if transportType != .transit,
      let routeResponse = try? await MKDirections(request: request).calculate(),
      let route = routeResponse.routes.first
    {
      let steps: [RouteCard.Step] = route.steps
        .filter { !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .prefix(15)
        .enumerated()
        .map { idx, step in
          RouteCard.Step(
            id: idx,
            instruction: step.instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            distanceMeters: step.distance)
        }
      return .success(
        TravelEstimateSummary(
          origin: originLabel,
          destination: destItem.name ?? destName,
          transport: resolvedMode,
          distanceMeters: route.distance,
          expectedTravelSeconds: route.expectedTravelTime,
          originLatitude: originCoord.latitude,
          originLongitude: originCoord.longitude,
          originIsCurrentLocation: originIsCurrentLocation,
          destinationAddress: destAddress,
          destinationLatitude: destCoord.latitude,
          destinationLongitude: destCoord.longitude,
          destinationMapItemIdentifier: destID,
          routeName: route.name.isEmpty ? nil : route.name,
          steps: steps))
    }

    do {
      let response = try await MKDirections(request: request).calculateETA()
      return .success(
        TravelEstimateSummary(
          origin: originLabel,
          destination: destItem.name ?? destName,
          transport: resolvedMode,
          distanceMeters: response.distance,
          expectedTravelSeconds: response.expectedTravelTime,
          originLatitude: originCoord.latitude,
          originLongitude: originCoord.longitude,
          originIsCurrentLocation: originIsCurrentLocation,
          destinationAddress: destAddress,
          destinationLatitude: destCoord.latitude,
          destinationLongitude: destCoord.longitude,
          destinationMapItemIdentifier: destID))
    } catch {
      return .error("Could not estimate travel time: \(error.localizedDescription)")
    }
  }

  // MARK: - Weather (WeatherKit)

  func fetchWeather(place: String?, scope: String) async -> PersonalToolResult<WeatherSummary> {
    let query = place?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    do {
      guard let report = try await WeatherLookup.report(for: query.isEmpty ? "here" : query) else {
        return .error("Could not find weather for '\(query)'.")
      }
      let attribution = await WeatherLookup.attribution()
      let record = WeatherLookup.actionCard(report, attributionLegalURL: attribution.url)
      guard case .weather(let card) = record.payload else {
        return .error("Could not format weather report.")
      }
      let text = WeatherLookup.describe(report)
      return .success(WeatherSummary(locationName: report.place, description: text, card: card))
    } catch {
      return .error("Weather unavailable: \(error.localizedDescription)")
    }
  }

  // MARK: - Alarms & Timers (iOS 27 AlarmKit)

  private struct StoredAlarmRecord: Codable {
    var label: String
    var kind: AlarmCard.Kind
    var fireDate: Date?
    var hour: Int?
    var minute: Int?
    var weekdays: [String]
    var durationSeconds: Double?
    var remainingSeconds: Double?
  }

  private static let alarmMetaKey = "agello.alarmKitMetadata"

  private static func clampedAlarmLabel(_ raw: String, fallback: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let clamped = String(trimmed.prefix(80))
    return clamped.isEmpty ? fallback : clamped
  }

  private func loadAlarmMetaUnlocked() -> [String: StoredAlarmRecord] {
    guard let data = UserDefaults.standard.data(forKey: Self.alarmMetaKey),
      let decoded = try? JSONDecoder().decode([String: StoredAlarmRecord].self, from: data)
    else { return [:] }
    return decoded
  }

  private func saveAlarmMetaUnlocked(_ records: [String: StoredAlarmRecord]) {
    if let data = try? JSONEncoder().encode(records) {
      UserDefaults.standard.set(data, forKey: Self.alarmMetaKey)
    }
  }

  private func withAlarmMeta<T>(_ body: (inout [String: StoredAlarmRecord]) -> T) -> T {
    alarmMetaLock.lock()
    defer { alarmMetaLock.unlock() }
    var records = loadAlarmMetaUnlocked()
    let result = body(&records)
    saveAlarmMetaUnlocked(records)
    return result
  }

  private func ensureAlarmAccess() async -> String? {
    let manager = AlarmManager.shared
    switch manager.authorizationState {
    case .authorized:
      return nil
    case .notDetermined:
      do {
        let state = try await manager.requestAuthorization()
        return state == .authorized ? nil : "Alarms permission was denied. Enable it in Settings > Agello."
      } catch {
        return "Alarms are unavailable: \(error.localizedDescription)"
      }
    case .denied:
      return "Alarms access is not enabled. Enable Alarms in Settings > Agello."
    @unknown default:
      return "Alarms access is unavailable on this device."
    }
  }

  private func mapAlarmState(_ state: Alarm.State) -> AlarmCard.State {
    switch state {
    case .scheduled: .scheduled
    case .countdown: .countdown
    case .paused: .paused
    case .alerting: .alerting
    @unknown default: .scheduled
    }
  }

  private func localeWeekdays(from tokens: [String]) -> [Locale.Weekday] {
    tokens.compactMap { token in
      switch token {
      case "mon": .monday
      case "tue": .tuesday
      case "wed": .wednesday
      case "thu": .thursday
      case "fri": .friday
      case "sat": .saturday
      case "sun": .sunday
      default: nil
      }
    }
  }

  private func alarmSummary(from alarm: Alarm, meta: StoredAlarmRecord?) -> AlarmSummary {
    var hour = meta?.hour
    var minute = meta?.minute
    var weekdays = meta?.weekdays ?? []
    var fireDate = meta?.fireDate
    if case .relative(let rel) = alarm.schedule {
      hour = rel.time.hour
      minute = rel.time.minute
      if case .weekly(let days) = rel.repeats, weekdays.isEmpty {
        weekdays = days.map { String(describing: $0).prefix(3).lowercased() }
      }
    } else if case .fixed(let date) = alarm.schedule {
      fireDate = date
    }
    let mappedState = mapAlarmState(alarm.state)
    let kind: AlarmCard.Kind = meta?.kind ?? (alarm.countdownDuration != nil ? .timer : .alarm)
    if mappedState == .paused {
      fireDate = nil
    }
    let duration =
      mappedState == .paused
      ? (meta?.remainingSeconds ?? meta?.durationSeconds ?? alarm.countdownDuration?.preAlert)
      : (meta?.durationSeconds ?? alarm.countdownDuration?.preAlert)
    return AlarmSummary(
      alarmID: alarm.id.uuidString,
      kind: kind,
      label: meta?.label ?? (kind == .timer ? "Timer" : "Alarm"),
      fireDate: fireDate,
      hour: hour,
      minute: minute,
      weekdays: weekdays,
      durationSeconds: duration,
      state: mappedState)
  }

  func listAlarms() async -> PersonalToolResult<[AlarmSummary]> {
    if let err = await ensureAlarmAccess() { return .error(err) }
    do {
      let active = try AlarmManager.shared.alarms
      let activeIDs = Set(active.map { $0.id.uuidString })
      let pruned: [String: StoredAlarmRecord] = alarmMetaLock.withLock {
        let meta = loadAlarmMetaUnlocked()
        let kept = meta.filter { activeIDs.contains($0.key) }
        if kept.count != meta.count { saveAlarmMetaUnlocked(kept) }
        return kept
      }
      return .success(active.map { alarmSummary(from: $0, meta: pruned[$0.id.uuidString]) })
    } catch {
      return .error("Could not list alarms: \(error.localizedDescription)")
    }
  }

  func scheduleTimer(label: String, durationSeconds: Double) async -> PersonalToolResult<AlarmSummary> {
    if let err = await ensureAlarmAccess() { return .error(err) }
    let id = UUID()
    let safeLabel = Self.clampedAlarmLabel(label, fallback: "Timer")
    let titleResource = LocalizedStringResource(stringLiteral: safeLabel)
    let presentation = AlarmPresentation(
      alert: AlarmPresentation.Alert(title: titleResource),
      countdown: AlarmPresentation.Countdown(
        title: titleResource,
        pauseButton: AlarmButton(text: "Pause", textColor: .white, systemImageName: "pause.fill")),
      paused: AlarmPresentation.Paused(
        title: titleResource,
        resumeButton: AlarmButton(text: "Resume", textColor: .white, systemImageName: "play.fill")))
    let attributes = AlarmAttributes(
      presentation: presentation,
      metadata: AgelloAlarmMetadata(label: safeLabel, kind: "timer"),
      tintColor: Color(red: 0.929, green: 0.800, blue: 0.541))
    let config = AlarmManager.AlarmConfiguration.timer(
      duration: durationSeconds,
      attributes: attributes,
      stopIntent: StopAgelloAlarmIntent(alarmID: id.uuidString))
    do {
      let scheduled = try await AlarmManager.shared.schedule(id: id, configuration: config)
      let fireDate = Date.now.addingTimeInterval(durationSeconds)
      let record = StoredAlarmRecord(
        label: safeLabel, kind: .timer, fireDate: fireDate, hour: nil, minute: nil, weekdays: [],
        durationSeconds: durationSeconds, remainingSeconds: nil)
      withAlarmMeta { meta in
        meta[id.uuidString] = record
      }
      return .success(alarmSummary(from: scheduled, meta: record))
    } catch {
      return .error("Could not start timer: \(error.localizedDescription)")
    }
  }

  func scheduleAlarm(
    label: String, hour: Int, minute: Int, weekdays: [String]
  ) async -> PersonalToolResult<AlarmSummary> {
    if let err = await ensureAlarmAccess() { return .error(err) }
    let id = UUID()
    let safeLabel = Self.clampedAlarmLabel(label, fallback: "Alarm")
    let titleResource = LocalizedStringResource(stringLiteral: safeLabel)
    let presentation = AlarmPresentation(
      alert: AlarmPresentation.Alert(title: titleResource))
    let attributes = AlarmAttributes(
      presentation: presentation,
      metadata: AgelloAlarmMetadata(label: safeLabel, kind: "alarm"),
      tintColor: Color(red: 0.929, green: 0.800, blue: 0.541))
    let mappedDays = localeWeekdays(from: weekdays)
    let schedule = Alarm.Schedule.relative(
      Alarm.Schedule.Relative(
        time: Alarm.Schedule.Relative.Time(hour: hour, minute: minute),
        repeats: mappedDays.isEmpty ? .never : .weekly(mappedDays)))
    let config = AlarmManager.AlarmConfiguration.alarm(
      schedule: schedule,
      attributes: attributes,
      stopIntent: StopAgelloAlarmIntent(alarmID: id.uuidString))
    do {
      let scheduled = try await AlarmManager.shared.schedule(id: id, configuration: config)
      let record = StoredAlarmRecord(
        label: safeLabel, kind: .alarm, fireDate: nil, hour: hour, minute: minute, weekdays: weekdays,
        durationSeconds: nil, remainingSeconds: nil)
      withAlarmMeta { meta in
        meta[id.uuidString] = record
      }
      return .success(alarmSummary(from: scheduled, meta: record))
    } catch {
      return .error("Could not schedule alarm: \(error.localizedDescription)")
    }
  }

  func cancelAlarm(identifier: String) async -> PersonalToolResult<AlarmSummary> {
    if let err = await ensureAlarmAccess() { return .error(err) }
    guard let uuid = UUID(uuidString: identifier) else { return .error("Invalid alarm ID.") }
    do {
      try AlarmManager.shared.cancel(id: uuid)
      let existingMeta = withAlarmMeta { meta in
        meta.removeValue(forKey: identifier)
      }
      return .success(
        AlarmSummary(
          alarmID: identifier,
          kind: existingMeta?.kind ?? .alarm,
          label: existingMeta?.label ?? "Alarm",
          fireDate: nil,
          hour: existingMeta?.hour,
          minute: existingMeta?.minute,
          weekdays: existingMeta?.weekdays ?? [],
          durationSeconds: existingMeta?.durationSeconds,
          state: .cancelled))
    } catch {
      return .error("Could not cancel alarm: \(error.localizedDescription)")
    }
  }

  func pauseAlarm(identifier: String) async -> PersonalToolResult<AlarmSummary> {
    if let err = await ensureAlarmAccess() { return .error(err) }
    guard let uuid = UUID(uuidString: identifier) else { return .error("Invalid alarm ID.") }
    do {
      try AlarmManager.shared.pause(id: uuid)
      let now = Date.now
      let updatedMeta: StoredAlarmRecord? = withAlarmMeta { meta in
        guard var existing = meta[identifier] else { return nil }
        let remaining =
          existing.fireDate.map { max(1, $0.timeIntervalSince(now)) }
          ?? existing.remainingSeconds
          ?? existing.durationSeconds
        existing.remainingSeconds = remaining
        existing.fireDate = nil
        meta[identifier] = existing
        return existing
      }
      return .success(
        AlarmSummary(
          alarmID: identifier,
          kind: updatedMeta?.kind ?? .timer,
          label: updatedMeta?.label ?? "Timer",
          fireDate: nil,
          hour: updatedMeta?.hour,
          minute: updatedMeta?.minute,
          weekdays: updatedMeta?.weekdays ?? [],
          durationSeconds: updatedMeta?.remainingSeconds ?? updatedMeta?.durationSeconds,
          state: .paused))
    } catch {
      return .error("Could not pause timer: \(error.localizedDescription)")
    }
  }

  func resumeAlarm(identifier: String) async -> PersonalToolResult<AlarmSummary> {
    if let err = await ensureAlarmAccess() { return .error(err) }
    guard let uuid = UUID(uuidString: identifier) else { return .error("Invalid alarm ID.") }
    do {
      try AlarmManager.shared.resume(id: uuid)
      let now = Date.now
      let updatedMeta: StoredAlarmRecord? = withAlarmMeta { meta in
        guard var existing = meta[identifier] else { return nil }
        let remaining = existing.remainingSeconds ?? existing.durationSeconds
        existing.fireDate = remaining.map { now.addingTimeInterval(max(1, $0)) }
        existing.remainingSeconds = nil
        meta[identifier] = existing
        return existing
      }
      return .success(
        AlarmSummary(
          alarmID: identifier,
          kind: updatedMeta?.kind ?? .timer,
          label: updatedMeta?.label ?? "Timer",
          fireDate: updatedMeta?.fireDate,
          hour: updatedMeta?.hour,
          minute: updatedMeta?.minute,
          weekdays: updatedMeta?.weekdays ?? [],
          durationSeconds: updatedMeta?.durationSeconds,
          state: .countdown))
    } catch {
      return .error("Could not resume timer: \(error.localizedDescription)")
    }
  }

  // MARK: - Photos + On-Device Vision OCR (ANE / .utility QoS)

  private func ensurePhotosAccess() async -> String? {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    switch status {
    case .authorized, .limited:
      return nil
    case .notDetermined:
      let granted = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
      return (granted == .authorized || granted == .limited)
        ? nil : "Photos access was denied. Enable it in Settings > Agello."
    default:
      return "Photos access is not enabled. Enable Photos access in Settings > Agello."
    }
  }

  func searchPhotos(
    query: String?, start: Date?, end: Date?, favoritesOnly: Bool, includeOCR: Bool, limit: Int
  ) async -> PersonalToolResult<[PhotoSearchMatch]> {
    if let err = await ensurePhotosAccess() { return .error(err) }

    let fetchOptions = PHFetchOptions()
    fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    var predicates: [NSPredicate] = [
      NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    ]
    if let start { predicates.append(NSPredicate(format: "creationDate >= %@", start as NSDate)) }
    if let end { predicates.append(NSPredicate(format: "creationDate <= %@", end as NSDate)) }
    if favoritesOnly { predicates.append(NSPredicate(format: "favorite == YES")) }
    fetchOptions.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)

    let thermal = ThermalPolicy.current
    let scanOCR = includeOCR && !thermal.pauseBackgroundANE
    let maxOCRScan = thermal.deferBackgroundChatIndexing ? 4 : 12
    let candidateCap = scanOCR ? max(limit, maxOCRScan) : limit
    fetchOptions.fetchLimit = candidateCap

    let result = PHAsset.fetchAssets(with: fetchOptions)
    var assets: [PHAsset] = []
    assets.reserveCapacity(min(result.count, candidateCap))
    result.enumerateObjects { asset, _, stop in
      assets.append(asset)
      if assets.count >= candidateCap { stop.pointee = true }
    }
    guard !assets.isEmpty else { return .success([]) }

    let cleanQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let matches = await Task.detached(priority: .utility) {
      await Self.processPhotoAssets(
        assets, query: cleanQuery, scanOCR: scanOCR, limit: limit)
    }.value
    return .success(matches)
  }

  /// Processes candidate Photo assets with at most 2 concurrent downsampled (<= 1,600 px) Vision
  /// OCR tasks on `.utility` QoS so peak memory and thermal load never clip Gemma 4 E4B.
  private static func processPhotoAssets(
    _ assets: [PHAsset], query: String, scanOCR: Bool, limit: Int
  ) async -> [PhotoSearchMatch] {
    var collected: [(Int, PhotoSearchMatch)] = []
    let maxInFlight = 2

    await withTaskGroup(of: (Int, PhotoSearchMatch).self) { group in
      var nextIndex = 0
      func enqueueNext() {
        guard nextIndex < assets.count else { return }
        let idx = nextIndex
        let asset = assets[idx]
        nextIndex += 1
        group.addTask {
          let ocr = scanOCR ? await Self.recognizeDownsampledText(for: asset) : nil
          let match = PhotoSearchMatch(
            localIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            locationName: nil,
            isFavorite: asset.isFavorite,
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            ocrText: ocr)
          return (idx, match)
        }
      }

      for _ in 0..<min(maxInFlight, assets.count) { enqueueNext() }
      for await item in group {
        collected.append(item)
        enqueueNext()
      }
    }

    let ordered = collected.sorted { $0.0 < $1.0 }.map(\.1)
    guard !query.isEmpty else { return Array(ordered.prefix(limit)) }

    let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    let filtered = ordered.filter { match in
      let haystack = [match.ocrText, match.locationName].compactMap { $0 }.joined(separator: " ").lowercased()
      guard !haystack.isEmpty else { return false }
      return tokens.allSatisfy { haystack.contains($0) }
        || haystack.contains(query.lowercased())
    }
    return Array(filtered.prefix(limit))
  }

  private static func recognizeDownsampledText(for asset: PHAsset) async -> String? {
    guard let cgImage = await loadDownsampledImage(for: asset, maxDimension: 1_600) else { return nil }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
      try handler.perform([request])
      let lines = (request.results ?? [])
        .compactMap { $0.topCandidates(1).first?.string }
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      return lines.isEmpty ? nil : lines.joined(separator: "\n")
    } catch {
      return nil
    }
  }

  private static func loadDownsampledImage(for asset: PHAsset, maxDimension: Int) async -> CGImage? {
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = false
    options.isSynchronous = false
    let data: Data? = await withCheckedContinuation { continuation in
      let once = OnceFlag()
      PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
        imageData, _, _, _ in
        guard once.claim() else { return }
        continuation.resume(returning: imageData)
      }
    }
    guard let data,
      let source = CGImageSourceCreateWithData(data as CFData, nil)
    else { return nil }
    let thumbOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxDimension,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary)
  }
}
