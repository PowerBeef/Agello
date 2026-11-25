import Contacts
import CoreLocation
import EventKit
import Foundation
import MapKit

/// Native iOS implementation of ``PersonalContextBackend`` backed by EventKit, Contacts, and MapKit.
/// All queries and writes stay strictly on-device; permission is requested lazily on first opted-in use.
final class PersonalContextService: PersonalContextBackend, @unchecked Sendable {
  static let shared = PersonalContextService()

  private let eventStore = EKEventStore()
  private let contactStore = CNContactStore()

  private init() {}

  // MARK: - Calendar

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
    let summaries = filtered.sorted { $0.startDate < $1.startDate }.prefix(40).map { event in
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
    return .success(Array(summaries))
  }

  func createCalendarEvent(
    title: String, start: Date, end: Date, location: String?, notes: String?
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
    event.location = location
    event.notes = notes
    do {
      try eventStore.save(event, span: .thisEvent, commit: true)
      return .success(
        CalendarEventSummary(
          eventIdentifier: event.eventIdentifier,
          title: event.title ?? title, startDate: event.startDate, endDate: event.endDate,
          isAllDay: event.isAllDay, location: event.location, calendarName: calendar.title,
          notes: event.notes))
    } catch {
      return .error("Could not save calendar event: \(error.localizedDescription)")
    }
  }

  // MARK: - Reminders

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
          let haystack = [item.title, item.notes].compactMap { $0 }.joined(separator: " ")
          return haystack.localizedCaseInsensitiveContains(filter)
        }
        let result = matched.prefix(30).map { item in
          ReminderSummary(
            reminderIdentifier: item.calendarItemIdentifier,
            title: item.title ?? "Untitled",
            dueDate: item.dueDateComponents?.date,
            isCompleted: item.isCompleted,
            listName: item.calendar?.title,
            priority: item.priority,
            notes: item.notes)
        }
        continuation.resume(returning: Array(result))
      }
    }
    return .success(summaries)
  }

  func createReminder(
    title: String, dueDate: Date?, notes: String?
  ) async -> PersonalToolResult<ReminderSummary> {
    if let err = await ensureRemindersAccess() { return .error(err) }
    guard let list = eventStore.defaultCalendarForNewReminders() else {
      return .error("No default writable Reminders list is configured on this device.")
    }
    let reminder = EKReminder(eventStore: eventStore)
    reminder.calendar = list
    reminder.title = title
    reminder.notes = notes
    if let dueDate {
      reminder.dueDateComponents = Calendar.current.dateComponents(
        [.year, .month, .day, .hour, .minute], from: dueDate)
    }
    do {
      try eventStore.save(reminder, commit: true)
      return .success(
        ReminderSummary(
          reminderIdentifier: reminder.calendarItemIdentifier,
          title: reminder.title ?? title, dueDate: dueDate, isCompleted: false,
          listName: list.title, priority: reminder.priority, notes: reminder.notes))
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
      return .success(
        ReminderSummary(
          reminderIdentifier: reminder.calendarItemIdentifier,
          title: reminder.title ?? "Untitled",
          dueDate: reminder.dueDateComponents?.date,
          isCompleted: reminder.isCompleted,
          listName: reminder.calendar?.title,
          priority: reminder.priority,
          notes: reminder.notes))
    } catch {
      return .error("Could not update reminder: \(error.localizedDescription)")
    }
  }

  /// Looks up an EventKit event for native `EKEventViewController` / `EKEventEditViewController`.
  func event(withIdentifier identifier: String) -> EKEvent? {
    eventStore.event(withIdentifier: identifier)
  }

  /// Shared store for native `EKEventEditViewController` presentation.
  var sharedEventStore: EKEventStore { eventStore }

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

  /// Fetches a full `CNContact` for native `CNContactViewController` presentation or vCard export.
  func contact(withIdentifier identifier: String, keysToFetch: [CNKeyDescriptor]) -> CNContact? {
    try? contactStore.unifiedContact(withIdentifier: identifier, keysToFetch: keysToFetch)
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
}
