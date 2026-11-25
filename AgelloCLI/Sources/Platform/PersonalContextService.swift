import CoreLocation
import Foundation
import MapKit

/// macOS CLI seam matching ``PersonalContextService`` on iOS. Supports live MapKit queries;
/// EventKit and Contacts return a clean unavailable notice unless tests inject a mock backend.
final class PersonalContextService: PersonalContextBackend, @unchecked Sendable {
  static let shared = PersonalContextService()

  private init() {}

  func searchCalendarEvents(
    start: Date, end: Date, query: String?
  ) async -> PersonalToolResult<[CalendarEventSummary]> {
    .error("Calendar access is only available in the iOS app.")
  }

  func createCalendarEvent(
    title: String, start: Date, end: Date, location: String?, notes: String?
  ) async -> PersonalToolResult<CalendarEventSummary> {
    .error("Calendar access is only available in the iOS app.")
  }

  func listReminders(
    includeCompleted: Bool, query: String?
  ) async -> PersonalToolResult<[ReminderSummary]> {
    .error("Reminders access is only available in the iOS app.")
  }

  func createReminder(
    title: String, dueDate: Date?, notes: String?
  ) async -> PersonalToolResult<ReminderSummary> {
    .error("Reminders access is only available in the iOS app.")
  }

  func searchContacts(query: String, limit: Int) async -> PersonalToolResult<[ContactSummary]> {
    .error("Contacts access is only available in the iOS app.")
  }

  func searchPlaces(
    query: String, near: String?, limit: Int
  ) async -> PersonalToolResult<[PlaceSummary]> {
    let capped = max(1, min(10, limit))
    do {
      let (places, _): ([PlaceSearch.Place], String?)
      if let near, !near.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        (places, _) = try await PlaceSearch.search(what: query, near: near, limit: capped)
      } else {
        (places, _) = try await PlaceSearch.search(query, limit: capped)
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
    guard let origin, !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !CurrentLocation.meansHere(origin)
    else {
      return .error("Provide an origin address (current location is unavailable on the CLI).")
    }
    guard let sourceItem = await PlaceSearch.find(origin, types: [.pointOfInterest, .address]),
      let destItem = await PlaceSearch.find(destName, types: [.pointOfInterest, .address])
    else {
      return .error("Could not locate those places on Apple Maps.")
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
          origin: sourceItem.name ?? origin, destination: destItem.name ?? destName,
          transport: resolvedMode,
          distanceMeters: route.distance,
          expectedTravelSeconds: route.expectedTravelTime,
          originLatitude: originCoord.latitude,
          originLongitude: originCoord.longitude,
          originIsCurrentLocation: false,
          destinationAddress: destItem.address?.fullAddress,
          destinationLatitude: destCoord.latitude,
          destinationLongitude: destCoord.longitude,
          destinationMapItemIdentifier: destItem.identifier?.rawValue,
          routeName: route.name.isEmpty ? nil : route.name,
          steps: steps))
    }
    do {
      let response = try await MKDirections(request: request).calculateETA()
      return .success(
        TravelEstimateSummary(
          origin: sourceItem.name ?? origin, destination: destItem.name ?? destName,
          transport: resolvedMode,
          distanceMeters: response.distance,
          expectedTravelSeconds: response.expectedTravelTime,
          originLatitude: originCoord.latitude,
          originLongitude: originCoord.longitude,
          originIsCurrentLocation: false,
          destinationAddress: destItem.address?.fullAddress,
          destinationLatitude: destCoord.latitude,
          destinationLongitude: destCoord.longitude,
          destinationMapItemIdentifier: destItem.identifier?.rawValue))
    } catch {
      return .error("Could not estimate travel time: \(error.localizedDescription)")
    }
  }
}
