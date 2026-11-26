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
    cache.totalCostLimit = 16 * 1024 * 1024
    return cache
  }()

  @MainActor
  private final class InFlightSnapshot {
    let task: Task<UIImage?, Never>
    var waiters = 0

    init(task: Task<UIImage?, Never>) {
      self.task = task
    }
  }

  private enum LookAroundCacheEntry {
    case available(MKLookAroundScene)
    case unavailable
  }

  private static var inFlightSnapshots: [String: InFlightSnapshot] = [:]
  private static var lookAroundCache: [String: LookAroundCacheEntry] = [:]
  private static let maxLookAroundCacheEntries = 48

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

  private static func mapSnapshotCacheKey(
    places: [PlacesCard.PlaceItem], size: CGSize, scale: CGFloat
  ) -> String {
    let effectiveScale = max(1, scale)
    return places.prefix(5)
      .map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) }
      .joined(separator: ";")
      + "|\(Int(size.width.rounded()))x\(Int(size.height.rounded()))@\(Int(effectiveScale.rounded()))x"
  }

  /// Synchronous RAM cache lookup so cached map previews display immediately without starting
  /// Metal work while E4B is busy.
  static func cachedMapSnapshot(
    places: [PlacesCard.PlaceItem], size: CGSize, scale: CGFloat
  ) -> UIImage? {
    guard !places.isEmpty, size.width > 10, size.height > 10 else { return nil }
    let key = mapSnapshotCacheKey(places: places, size: size, scale: scale) as NSString
    return snapshotCache.object(forKey: key)
  }

  /// Renders and caches a static dark-styled Retina mini-map snapshot with custom pin markers on
  /// `.utility` QoS. Deduplicates concurrent identical requests and propagates task cancellation
  /// directly to `MKMapSnapshotter.cancel()`. Call only when E4B is idle so its Metal pass never
  /// contends with decode.
  static func renderMapSnapshot(
    places: [PlacesCard.PlaceItem], size: CGSize, scale: CGFloat
  ) async -> UIImage? {
    guard !places.isEmpty, size.width > 10, size.height > 10 else { return nil }
    let effectiveScale = max(1, scale)
    let keyString = mapSnapshotCacheKey(places: places, size: size, scale: effectiveScale)
    let cacheKey = keyString as NSString
    if let cached = snapshotCache.object(forKey: cacheKey) { return cached }
    guard !Task.isCancelled else { return nil }

    let entry: InFlightSnapshot
    if let existing = inFlightSnapshots[keyString] {
      entry = existing
    } else {
      let points: [(Double, Double)] = places.prefix(5).map { ($0.latitude, $0.longitude) }
      let renderSize = CGSize(width: size.width, height: size.height)
      let traitsBox = TraitCollectionBox(
        UITraitCollection { traits in
          traits.displayScale = effectiveScale
          traits.userInterfaceStyle = .dark
        })
      let task = Task.detached(priority: .utility) { () -> UIImage? in
        await Self.renderSnapshotImage(
          points: points, size: renderSize, scale: effectiveScale, traits: traitsBox)
      }
      let created = InFlightSnapshot(task: task)
      inFlightSnapshots[keyString] = created
      entry = created
    }

    entry.waiters += 1
    let released = OneShotFlag()
    let releaseWaiter: @MainActor () -> Void = {
      guard released.claim() else { return }
      entry.waiters -= 1
      if entry.waiters <= 0 {
        entry.task.cancel()
        if inFlightSnapshots[keyString] === entry {
          inFlightSnapshots.removeValue(forKey: keyString)
        }
      }
    }

    let rendered: UIImage? = await withTaskCancellationHandler {
      await entry.task.value
    } onCancel: {
      Task { @MainActor in releaseWaiter() }
    }

    releaseWaiter()
    if let rendered {
      let cost = Self.imageByteCost(rendered)
      snapshotCache.setObject(rendered, forKey: cacheKey, cost: cost)
    }
    return Task.isCancelled ? nil : rendered
  }

  private nonisolated static func renderSnapshotImage(
    points: [(Double, Double)], size: CGSize, scale: CGFloat, traits: TraitCollectionBox
  ) async -> UIImage? {
    guard !Task.isCancelled else { return nil }
    let coords = points.map { CLLocationCoordinate2D(latitude: $0.0, longitude: $0.1) }
      .filter(CLLocationCoordinate2DIsValid)
    guard !coords.isEmpty else { return nil }

    let options = MKMapSnapshotter.Options()
    options.size = size
    options.traitCollection = traits.value
    options.region = boundingRegion(for: coords)
    let box = SnapshotterBox(MKMapSnapshotter(options: options))
    let snapshot: MKMapSnapshotter.Snapshot? = await withTaskCancellationHandler {
      guard !Task.isCancelled else { return nil }
      return try? await box.snapshotter.start()
    } onCancel: {
      box.snapshotter.cancel()
    }
    guard let snapshot, !Task.isCancelled else { return nil }

    let format = UIGraphicsImageRendererFormat()
    format.scale = scale
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
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
  }

  private static func imageByteCost(_ image: UIImage) -> Int {
    if let cg = image.cgImage {
      return max(1, cg.bytesPerRow * cg.height)
    }
    let pxW = Int((image.size.width * image.scale).rounded())
    let pxH = Int((image.size.height * image.scale).rounded())
    return max(1, pxW * pxH * 4)
  }

  /// On-demand, cached, cancellable Look Around scene lookup.
  static func checkLookAround(latitude: Double, longitude: Double) async -> MKLookAroundScene? {
    let coord = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    guard CLLocationCoordinate2DIsValid(coord) else { return nil }
    let key = String(format: "%.4f,%.4f", latitude, longitude)
    if let cached = lookAroundCache[key] {
      switch cached {
      case .available(let scene): return scene
      case .unavailable: return nil
      }
    }
    guard !Task.isCancelled else { return nil }
    let box = LookAroundRequestBox(MKLookAroundSceneRequest(coordinate: coord))
    let scene: MKLookAroundScene? = await withTaskCancellationHandler {
      guard !Task.isCancelled else { return nil }
      return try? await box.request.scene
    } onCancel: {
      box.request.cancel()
    }
    guard !Task.isCancelled else { return nil }
    if lookAroundCache.count >= maxLookAroundCacheEntries {
      lookAroundCache.removeAll(keepingCapacity: true)
    }
    lookAroundCache[key] = scene.map(LookAroundCacheEntry.available) ?? .unavailable
    return scene
  }

  /// Recalculates travel time, distance, and turn-by-turn steps via MapKit when the user switches
  /// transport mode (`driving` / `walking` / `cycling` / `transit`) inside ``RouteCardView``.
  static func recalculateRoute(from card: RouteCard, transport mode: String) async -> RouteCard? {
    let normalized = mode.lowercased()
    let destItem = await resolveMapItem(
      identifier: card.destinationMapItemIdentifier,
      name: card.destinationName,
      latitude: card.destinationLatitude,
      longitude: card.destinationLongitude)
    let sourceItem: MKMapItem
    if card.originIsCurrentLocation {
      sourceItem = MKMapItem.forCurrentLocation()
    } else if let lat = card.originLatitude, let lon = card.originLongitude {
      sourceItem = MKMapItem(location: CLLocation(latitude: lat, longitude: lon), address: nil)
      sourceItem.name = card.originName
    } else {
      sourceItem = MKMapItem.forCurrentLocation()
    }

    let request = MKDirections.Request()
    request.source = sourceItem
    request.destination = destItem
    switch normalized {
    case "walking": request.transportType = .walking
    case "cycling": request.transportType = .cycling
    case "transit": request.transportType = .transit
    default: request.transportType = .automobile
    }

    var updated = card
    updated.transport = normalized

    if request.transportType != .transit,
      let routeResponse = try? await MKDirections(request: request).calculate(),
      let route = routeResponse.routes.first
    {
      updated.distanceMeters = route.distance
      updated.expectedTravelSeconds = route.expectedTravelTime
      updated.routeName = route.name.isEmpty ? nil : route.name
      updated.steps = route.steps
        .filter { !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .prefix(15)
        .enumerated()
        .map { idx, step in
          RouteCard.Step(
            id: idx,
            instruction: step.instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            distanceMeters: step.distance)
        }
      return updated
    }

    guard let eta = try? await MKDirections(request: request).calculateETA() else { return nil }
    updated.distanceMeters = eta.distance
    updated.expectedTravelSeconds = eta.expectedTravelTime
    updated.routeName = nil
    updated.steps = []
    return updated
  }

  private nonisolated static func boundingRegion(
    for coords: [CLLocationCoordinate2D]
  ) -> MKCoordinateRegion {
    let valid = coords.filter(CLLocationCoordinate2DIsValid)
    guard let first = valid.first else { return MKCoordinateRegion() }
    if valid.count == 1 {
      let clamped = CLLocationCoordinate2D(
        latitude: min(85, max(-85, first.latitude)),
        longitude: normalizeLongitude(first.longitude))
      return MKCoordinateRegion(center: clamped, latitudinalMeters: 900, longitudinalMeters: 900)
    }
    let lats = valid.map(\.latitude)
    let minLat = lats.min() ?? first.latitude
    let maxLat = lats.max() ?? first.latitude
    let centerLat = min(85, max(-85, (minLat + maxLat) / 2))
    let maxSafeLatDelta = max(0.008, min(160, (89 - abs(centerLat)) * 2))
    let latDelta = min(maxSafeLatDelta, max(0.008, (maxLat - minLat) * 1.65))

    // Find the largest gap around the 360° longitude circle so coordinates straddling the
    // antimeridian (+/-180°) frame tightly across the Pacific instead of spanning the globe.
    let sortedLons = valid.map { normalizeLongitude($0.longitude) }.sorted()
    var largestGap = (sortedLons[0] + 360) - (sortedLons.last ?? sortedLons[0])
    var arcStart = sortedLons[0]
    for index in 0..<(sortedLons.count - 1) {
      let gap = sortedLons[index + 1] - sortedLons[index]
      if gap > largestGap {
        largestGap = gap
        arcStart = sortedLons[index + 1]
      }
    }
    let rawLonSpan = max(0, 360 - largestGap)
    let centerLon = normalizeLongitude(arcStart + rawLonSpan / 2)
    let lonDelta = min(350, max(0.008, rawLonSpan * 1.65))

    return MKCoordinateRegion(
      center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
      span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
  }

  private nonisolated static func normalizeLongitude(_ lon: Double) -> Double {
    var normalized = lon.truncatingRemainder(dividingBy: 360)
    if normalized > 180 { normalized -= 360 }
    if normalized < -180 { normalized += 360 }
    return normalized
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

private final class TraitCollectionBox: @unchecked Sendable {
  let value: UITraitCollection
  init(_ value: UITraitCollection) { self.value = value }
}

private final class SnapshotterBox: @unchecked Sendable {
  let snapshotter: MKMapSnapshotter
  init(_ snapshotter: MKMapSnapshotter) { self.snapshotter = snapshotter }
}

private final class LookAroundRequestBox: @unchecked Sendable {
  let request: MKLookAroundSceneRequest
  init(_ request: MKLookAroundSceneRequest) { self.request = request }
}

private final class OneShotFlag: @unchecked Sendable {
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

private final class ResolvedCalendarEvent: @unchecked Sendable {
  let store: EKEventStore
  let event: EKEvent

  init(store: EKEventStore, event: EKEvent) {
    self.store = store
    self.event = event
  }
}

// MARK: - Out-of-process Native iOS Sheets (EventKitUI, ContactsUI, MessageUI, SwiftUI Map)

enum CalendarEventEditOutcome: Equatable {
  case saved(CalendarEventCard)
  case deleted
  case cancelled
}

struct CalendarEventEditSheet: View {
  let card: CalendarEventCard
  var onComplete: ((CalendarEventEditOutcome) -> Void)? = nil
  @Environment(\.dismiss) private var dismiss
  @State private var resolved: ResolvedCalendarEvent?

  var body: some View {
    Group {
      if let resolved {
        CalendarEventEditRepresentable(
          card: card,
          store: resolved.store,
          event: resolved.event,
          dismiss: dismiss,
          onComplete: onComplete
        )
        .ignoresSafeArea()
      } else {
        NavigationStack {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Surface.canvas.ignoresSafeArea())
            .navigationTitle(card.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                  onComplete?(.cancelled)
                  dismiss()
                }
              }
            }
        }
      }
    }
    .task(id: card.eventIdentifier ?? card.title) {
      let cardSnapshot = card
      let loaded = await Task.detached(priority: .userInitiated) { () -> ResolvedCalendarEvent in
        let store = EKEventStore()
        let event: EKEvent
        if let id = cardSnapshot.eventIdentifier, let existing = store.event(withIdentifier: id) {
          event = existing
        } else {
          let created = EKEvent(eventStore: store)
          created.calendar = store.defaultCalendarForNewEvents
          created.title = cardSnapshot.title
          created.startDate = cardSnapshot.startDate
          created.endDate = cardSnapshot.endDate
          created.isAllDay = cardSnapshot.isAllDay
          created.location = cardSnapshot.location
          event = created
        }
        return ResolvedCalendarEvent(store: store, event: event)
      }.value
      guard !Task.isCancelled else { return }
      resolved = loaded
    }
  }
}

private struct CalendarEventEditRepresentable: UIViewControllerRepresentable {
  let card: CalendarEventCard
  let store: EKEventStore
  let event: EKEvent
  let dismiss: DismissAction
  var onComplete: ((CalendarEventEditOutcome) -> Void)? = nil

  func makeCoordinator() -> Coordinator {
    Coordinator(store: store, card: card, dismiss: dismiss, onComplete: onComplete)
  }

  func makeUIViewController(context: Context) -> EKEventEditViewController {
    let controller = EKEventEditViewController()
    controller.eventStore = store
    controller.event = event
    controller.editViewDelegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {
    context.coordinator.card = card
    context.coordinator.onComplete = onComplete
  }

  @MainActor
  final class Coordinator: NSObject, @preconcurrency EKEventEditViewDelegate {
    let store: EKEventStore
    var card: CalendarEventCard
    let dismiss: DismissAction
    var onComplete: ((CalendarEventEditOutcome) -> Void)?

    init(
      store: EKEventStore, card: CalendarEventCard, dismiss: DismissAction,
      onComplete: ((CalendarEventEditOutcome) -> Void)?
    ) {
      self.store = store
      self.card = card
      self.dismiss = dismiss
      self.onComplete = onComplete
    }

    func eventEditViewController(
      _ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction
    ) {
      switch action {
      case .saved:
        if let saved = controller.event {
          let updated = CalendarEventCard(
            status: card.eventIdentifier == nil ? .created : .updated,
            eventIdentifier: saved.eventIdentifier ?? card.eventIdentifier,
            title: saved.title?.isEmpty == false ? (saved.title ?? card.title) : card.title,
            startDate: saved.startDate ?? card.startDate,
            endDate: saved.endDate ?? card.endDate,
            isAllDay: saved.isAllDay,
            location: saved.location,
            calendarName: saved.calendar?.title ?? card.calendarName)
          onComplete?(.saved(updated))
        } else {
          onComplete?(.cancelled)
        }
      case .deleted:
        onComplete?(.deleted)
      case .canceled:
        onComplete?(.cancelled)
      @unknown default:
        onComplete?(.cancelled)
      }
      dismiss()
    }
  }
}

struct ContactDetailSheet: View {
  let card: ContactCard
  @Environment(\.dismiss) private var dismiss
  @State private var resolvedContact: CNContact?
  @State private var didResolve = false

  var body: some View {
    Group {
      if didResolve || card.contactIdentifier == nil {
        ContactDetailViewControllerRepresentable(
          card: card, existingContact: resolvedContact, dismiss: dismiss
        )
        .ignoresSafeArea()
      } else {
        NavigationStack {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.Surface.canvas.ignoresSafeArea())
            .navigationTitle(card.fullName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                Button(role: .close) { dismiss() }
              }
            }
        }
      }
    }
    .task(id: card.contactIdentifier) {
      guard let id = card.contactIdentifier else {
        didResolve = true
        return
      }
      resolvedContact = await PersonalContextService.shared.fetchContact(
        withIdentifier: id,
        keysToFetch: [CNContactViewController.descriptorForRequiredKeys()])
      didResolve = true
    }
  }
}

private struct ContactDetailViewControllerRepresentable: UIViewControllerRepresentable {
  let card: ContactCard
  let existingContact: CNContact?
  let dismiss: DismissAction

  func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

  func makeUIViewController(context: Context) -> UINavigationController {
    let controller: CNContactViewController
    if let existingContact {
      controller = CNContactViewController(for: existingContact)
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
      if let address = card.postalAddress, !address.isEmpty {
        let postal = CNMutablePostalAddress()
        postal.street = address
        mutable.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: postal)]
      }
      controller = CNContactViewController(forUnknownContact: mutable)
      controller.contactStore = CNContactStore()
      controller.delegate = context.coordinator
    }
    controller.allowsEditing = false
    let close = dismiss
    controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
      systemItem: .close,
      primaryAction: UIAction { _ in close() })
    return UINavigationController(rootViewController: controller)
  }

  func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

  @MainActor
  final class Coordinator: NSObject, @preconcurrency CNContactViewControllerDelegate {
    let dismiss: DismissAction
    init(dismiss: DismissAction) { self.dismiss = dismiss }

    func contactViewController(
      _ viewController: CNContactViewController, didCompleteWith contact: CNContact?
    ) {
      dismiss()
    }
  }
}

private final class DismissingFallbackViewController: UIViewController {
  private let onAppearDismiss: () -> Void
  private var didDismiss = false

  init(onAppearDismiss: @escaping () -> Void) {
    self.onAppearDismiss = onAppearDismiss
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !didDismiss else { return }
    didDismiss = true
    onAppearDismiss()
  }
}

struct MessageComposeSheet: UIViewControllerRepresentable {
  let recipients: [String]
  let body: String
  @Environment(\.dismiss) private var dismiss

  func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

  func makeUIViewController(context: Context) -> UIViewController {
    guard MFMessageComposeViewController.canSendText() else {
      let close = dismiss
      return DismissingFallbackViewController { close() }
    }
    let controller = MFMessageComposeViewController()
    controller.recipients = recipients
    controller.body = body
    controller.messageComposeDelegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

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

  func makeUIViewController(context: Context) -> UIViewController {
    guard MFMailComposeViewController.canSendMail() else {
      let close = dismiss
      return DismissingFallbackViewController { close() }
    }
    let controller = MFMailComposeViewController()
    controller.setToRecipients(recipients)
    if let subject { controller.setSubject(subject) }
    controller.setMessageBody(body, isHTML: false)
    controller.mailComposeDelegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

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

struct MapItemDetailSheet: UIViewControllerRepresentable {
  let mapItem: MKMapItem
  var displaysMap = true
  @Environment(\.dismiss) private var dismiss

  func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

  func makeUIViewController(context: Context) -> MKMapItemDetailViewController {
    let controller = MKMapItemDetailViewController(mapItem: mapItem, displaysMap: displaysMap)
    controller.delegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ uiViewController: MKMapItemDetailViewController, context: Context) {
    if uiViewController.mapItem != mapItem {
      uiViewController.mapItem = mapItem
    }
  }

  @MainActor
  final class Coordinator: NSObject, MKMapItemDetailViewControllerDelegate {
    let dismiss: DismissAction
    init(dismiss: DismissAction) { self.dismiss = dismiss }

    func mapItemDetailViewControllerDidFinish(_ detailViewController: MKMapItemDetailViewController) {
      dismiss()
    }
  }
}

struct LookAroundSheet: View {
  let scene: MKLookAroundScene
  let title: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      LookAroundPreview(initialScene: scene, allowsNavigation: true)
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button(role: .close) { dismiss() }
          }
        }
    }
  }
}

struct InteractivePlacesMapSheet: View {
  let card: PlacesCard
  var initialSelectedIndex: Int = 0
  @Environment(\.dismiss) private var dismiss
  @State private var selectedPlaceID: String?
  @State private var cameraPosition: MapCameraPosition

  init(card: PlacesCard, initialSelectedIndex: Int = 0) {
    self.card = card
    self.initialSelectedIndex = initialSelectedIndex
    let clampedIndex = card.places.indices.contains(initialSelectedIndex) ? initialSelectedIndex : 0
    let initialPlace = card.places.indices.contains(clampedIndex) ? card.places[clampedIndex] : nil
    _selectedPlaceID = State(initialValue: initialPlace?.id)
    if let place = initialPlace {
      let coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
      let region = MKCoordinateRegion(
        center: coordinate, latitudinalMeters: 1_200, longitudinalMeters: 1_200)
      _cameraPosition = State(initialValue: .region(region))
    } else {
      _cameraPosition = State(initialValue: .automatic)
    }
  }

  private var selectedPlace: PlacesCard.PlaceItem? {
    if let selectedPlaceID, let match = card.places.first(where: { $0.id == selectedPlaceID }) {
      return match
    }
    if card.places.indices.contains(initialSelectedIndex) {
      return card.places[initialSelectedIndex]
    }
    return card.places.first
  }

  var body: some View {
    NavigationStack {
      Map(position: $cameraPosition, selection: $selectedPlaceID) {
        ForEach(card.places) { place in
          Marker(
            place.name,
            coordinate: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
          )
          .tint(place.id == selectedPlace?.id ? Theme.Brand.gold : Theme.Brand.teal)
          .tag(place.id)
        }
      }
      .mapControls {
        MapUserLocationButton()
        MapCompass()
      }
      .navigationTitle(selectedPlace?.name ?? card.query)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(role: .close) { dismiss() }
        }
        if let target = selectedPlace {
          ToolbarItem(placement: .primaryAction) {
            Button("Open in Maps", systemImage: "map") {
              NativeActions.openInMaps(place: target)
            }
          }
        }
      }
    }
  }
}
