import Contacts
import ContactsUI
import CoreLocation
import EventKit
import EventKitUI
import MapKit
import MessageUI
import SwiftUI
import UIKit

/// Public iOS 27 native handoffs and UIKit sheet wrappers shared by `Agello` and `AgelloSim`.
/// Uses exclusively public Apple APIs (`MKMapItem.openInMaps`, `MKMapItemRequest`,
/// `MKMapSnapshotter`, `EKEventEditViewController`, `CNContactViewController`,
/// `MFMessageComposeViewController`, `MFMailComposeViewController`) — zero private URL schemes.
@MainActor
enum NativeActions {
  private static let snapshotCache: NSCache<NSString, UIImage> = {
    let cache = NSCache<NSString, UIImage>()
    cache.countLimit = 24
    return cache
  }()

  // MARK: - Apple Maps

  static func openInMaps(place: PlacesCard.PlaceItem, directionsMode: String? = nil) {
    Task { @MainActor in
      let item = await resolveMapItem(for: place)
      var options: [String: Any] = [:]
      if let directionsMode {
        options[MKLaunchOptionsDirectionsModeKey] = launchDirectionsMode(directionsMode)
      }
      let opened = item.openInMaps(launchOptions: options.isEmpty ? nil : options)
      if !opened {
        let fallback =
          directionsMode != nil
          ? NativeActionURLs.appleMapsDirections(
            destinationName: place.name,
            destinationLatitude: place.latitude,
            destinationLongitude: place.longitude,
            transport: directionsMode ?? "driving")
          : NativeActionURLs.appleMapsPlace(
            name: place.name, latitude: place.latitude, longitude: place.longitude)
        if let fallback { openURL(fallback) }
      }
    }
  }

  static func openRouteInMaps(_ route: RouteCard, transportOverride: String? = nil) {
    Task { @MainActor in
      let mode = transportOverride ?? route.transport
      let destItem = await resolveMapItem(
        identifier: route.destinationMapItemIdentifier,
        name: route.destinationName,
        latitude: route.destinationLatitude,
        longitude: route.destinationLongitude)
      let sourceItem: MKMapItem
      if route.originIsCurrentLocation {
        sourceItem = MKMapItem.forCurrentLocation()
      } else if let lat = route.originLatitude, let lon = route.originLongitude {
        sourceItem = MKMapItem(location: CLLocation(latitude: lat, longitude: lon), address: nil)
        sourceItem.name = route.originName
      } else {
        sourceItem = MKMapItem.forCurrentLocation()
      }
      let options: [String: Any] = [MKLaunchOptionsDirectionsModeKey: launchDirectionsMode(mode)]
      let opened = MKMapItem.openMaps(with: [sourceItem, destItem], launchOptions: options)
      if !opened,
        let fallback = NativeActionURLs.appleMapsDirections(
          destinationName: route.destinationName,
          destinationLatitude: route.destinationLatitude,
          destinationLongitude: route.destinationLongitude,
          originLatitude: route.originIsCurrentLocation ? nil : route.originLatitude,
          originLongitude: route.originIsCurrentLocation ? nil : route.originLongitude,
          transport: mode)
      {
        openURL(fallback)
      }
    }
  }

  static func openAddressInMaps(_ query: String) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    var comps = URLComponents(string: "https://maps.apple.com/")
    comps?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
    if let url = comps?.url { openURL(url) }
  }

  static func resolveMapItem(for place: PlacesCard.PlaceItem) async -> MKMapItem {
    await resolveMapItem(
      identifier: place.mapItemIdentifier,
      name: place.name,
      latitude: place.latitude,
      longitude: place.longitude,
      phone: place.phone)
  }

  static func resolveMapItem(
    identifier: String?, name: String, latitude: Double, longitude: Double, phone: String? = nil
  ) async -> MKMapItem {
    if let rawID = identifier, !rawID.isEmpty, let id = MKMapItem.Identifier(rawValue: rawID) {
      let request = MKMapItemRequest(mapItemIdentifier: id)
      if let resolved = try? await request.mapItem {
        return resolved
      }
    }
    let item = MKMapItem(
      location: CLLocation(latitude: latitude, longitude: longitude), address: nil)
    item.name = name
    if let phone { item.phoneNumber = phone }
    return item
  }

  /// Renders and caches a static dark-styled mini-map snapshot with custom pin markers on `.utility`
  /// QoS. Call only after streaming completes so its brief Metal render pass never contends with E4B.
  static func renderMapSnapshot(
    places: [PlacesCard.PlaceItem], size: CGSize, scale: CGFloat
  ) async -> UIImage? {
    guard !places.isEmpty, size.width > 10, size.height > 10 else { return nil }
    let keyString = places.prefix(5)
      .map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) }
      .joined(separator: ";") + "|\(Int(size.width))x\(Int(size.height))"
    let cacheKey = keyString as NSString
    if let cached = snapshotCache.object(forKey: cacheKey) { return cached }

    let points: [(Double, Double)] = places.prefix(5).map { ($0.latitude, $0.longitude) }
    let width = size.width
    let height = size.height
    let rendered: UIImage? = await Task.detached(priority: .utility) {
      let coords = points.map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }
      let renderSize = CGSize(width: width, height: height)
      let options = MKMapSnapshotter.Options()
      options.size = renderSize
      options.scale = scale
      options.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
      options.region = Self.boundingRegion(for: coords)
      guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }

      let renderer = UIGraphicsImageRenderer(size: renderSize)
      return renderer.image { ctx in
        snapshot.image.draw(at: .zero)
        let cg = ctx.cgContext
        for (idx, coord) in coords.enumerated().reversed() {
          let point = snapshot.point(for: coord)
          let isPrimary = idx == 0
          let radius: CGFloat = isPrimary ? 9 : 6
          let rect = CGRect(
            x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
          cg.setFillColor(
            (isPrimary
              ? UIColor(red: 0.549, green: 0.780, blue: 0.749, alpha: 1) : UIColor.white).cgColor)
          cg.fillEllipse(in: rect)
          cg.setStrokeColor(UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 0.95).cgColor)
          cg.setLineWidth(2)
          cg.strokeEllipse(in: rect)
        }
      }
    }.value
    if let rendered { snapshotCache.setObject(rendered, forKey: cacheKey) }
    return rendered
  }

  static func checkLookAround(latitude: Double, longitude: Double) async -> MKLookAroundScene? {
    let coord = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    return try? await MKLookAroundSceneRequest(coordinate: coord).scene
  }

  private nonisolated static func boundingRegion(
    for coords: [CLLocationCoordinate2D]
  ) -> MKCoordinateRegion {
    guard let first = coords.first else { return MKCoordinateRegion() }
    if coords.count == 1 {
      return MKCoordinateRegion(center: first, latitudinalMeters: 900, longitudinalMeters: 900)
    }
    let lats = coords.map(\.latitude)
    let lons = coords.map(\.longitude)
    let minLat = lats.min() ?? first.latitude
    let maxLat = lats.max() ?? first.latitude
    let minLon = lons.min() ?? first.longitude
    let maxLon = lons.max() ?? first.longitude
    let center = CLLocationCoordinate2D(
      latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
    let latDelta = max(0.008, (maxLat - minLat) * 1.65)
    let lonDelta = max(0.008, (maxLon - minLon) * 1.65)
    return MKCoordinateRegion(
      center: center, span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
  }

  private static func launchDirectionsMode(_ mode: String) -> String {
    switch mode.lowercased() {
    case "walking": return MKLaunchOptionsDirectionsModeWalking
    case "cycling": return MKLaunchOptionsDirectionsModeCycling
    case "transit": return MKLaunchOptionsDirectionsModeTransit
    default: return MKLaunchOptionsDirectionsModeDriving
    }
  }

  // MARK: - URL & Composer availability

  static func openURL(_ url: URL) {
    UIApplication.shared.open(url)
  }

  static func openExternalURL(_ url: URL) async -> Bool {
    await UIApplication.shared.open(url)
  }

  static var canSendText: Bool { MFMessageComposeViewController.canSendText() }
  static var canSendMail: Bool { MFMailComposeViewController.canSendMail() }
}

// MARK: - Out-of-process Native iOS Sheets (EventKitUI, ContactsUI, MessageUI, SwiftUI Map)

struct CalendarEventEditSheet: UIViewControllerRepresentable {
  let card: CalendarEventCard
  @Environment(\.dismiss) private var dismiss

  func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

  func makeUIViewController(context: Context) -> EKEventEditViewController {
    let store = PersonalContextService.shared.sharedEventStore
    let controller = EKEventEditViewController()
    controller.eventStore = store
    if let id = card.eventIdentifier, let existing = PersonalContextService.shared.event(withIdentifier: id) {
      controller.event = existing
    } else {
      let event = EKEvent(eventStore: store)
      event.title = card.title
      event.startDate = card.startDate
      event.endDate = card.endDate
      event.isAllDay = card.isAllDay
      event.location = card.location
      controller.event = event
    }
    controller.editViewDelegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {}

  final class Coordinator: NSObject, @preconcurrency EKEventEditViewDelegate {
    let dismiss: DismissAction
    init(dismiss: DismissAction) { self.dismiss = dismiss }
    @MainActor
    func eventEditViewController(
      _ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction
    ) {
      dismiss()
    }
  }
}

struct ContactDetailSheet: UIViewControllerRepresentable {
  let card: ContactCard

  func makeUIViewController(context: Context) -> UINavigationController {
    let controller: CNContactViewController
    if let id = card.contactIdentifier,
      let existing = PersonalContextService.shared.contact(
        withIdentifier: id, keysToFetch: [CNContactViewController.descriptorForRequiredKeys()])
    {
      controller = CNContactViewController(for: existing)
    } else {
      let mutable = CNMutableContact()
      let parts = card.fullName.split(separator: " ", maxSplits: 1)
      mutable.givenName = parts.first.map(String.init) ?? card.fullName
      if parts.count > 1 { mutable.familyName = String(parts[1]) }
      if let org = card.organization { mutable.organizationName = org }
      mutable.phoneNumbers = card.phones.map {
        CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0))
      }
      mutable.emailAddresses = card.emails.map {
        CNLabeledValue(label: CNLabelHome, value: $0 as NSString)
      }
      controller = CNContactViewController(forUnknownContact: mutable)
    }
    controller.allowsEditing = false
    return UINavigationController(rootViewController: controller)
  }

  func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

struct MessageComposeSheet: UIViewControllerRepresentable {
  let recipients: [String]
  let body: String
  @Environment(\.dismiss) private var dismiss

  func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

  func makeUIViewController(context: Context) -> MFMessageComposeViewController {
    let controller = MFMessageComposeViewController()
    controller.recipients = recipients
    controller.body = body
    controller.messageComposeDelegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ uiViewController: MFMessageComposeViewController, context: Context) {}

  final class Coordinator: NSObject, @preconcurrency MFMessageComposeViewControllerDelegate {
    let dismiss: DismissAction
    init(dismiss: DismissAction) { self.dismiss = dismiss }
    @MainActor
    func messageComposeViewController(
      _ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult
    ) {
      dismiss()
    }
  }
}

struct MailComposeSheet: UIViewControllerRepresentable {
  let recipients: [String]
  let subject: String?
  let body: String
  @Environment(\.dismiss) private var dismiss

  func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

  func makeUIViewController(context: Context) -> MFMailComposeViewController {
    let controller = MFMailComposeViewController()
    controller.setToRecipients(recipients)
    if let subject { controller.setSubject(subject) }
    controller.setMessageBody(body, isHTML: false)
    controller.mailComposeDelegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}

  final class Coordinator: NSObject, @preconcurrency MFMailComposeViewControllerDelegate {
    let dismiss: DismissAction
    init(dismiss: DismissAction) { self.dismiss = dismiss }
    @MainActor
    func mailComposeController(
      _ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?
    ) {
      dismiss()
    }
  }
}

struct InteractivePlacesMapSheet: View {
  let card: PlacesCard
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Map {
        ForEach(card.places) { place in
          Marker(
            place.name,
            coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
          )
          .tint(Theme.Brand.teal)
        }
      }
      .mapControls {
        MapUserLocationButton()
        MapCompass()
      }
      .navigationTitle(card.places.first?.name ?? card.query)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        if let primary = card.places.first {
          ToolbarItem(placement: .primaryAction) {
            Button("Open in Maps", systemImage: "map") {
              NativeActions.openInMaps(place: primary)
            }
          }
        }
      }
    }
  }
}
