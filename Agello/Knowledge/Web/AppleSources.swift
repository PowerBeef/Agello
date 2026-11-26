import CoreLocation
import Foundation
import MapKit
import WeatherKit

// Apple's own sources behind Search (``SearchTopic``): Apple Maps for places (MapKit) and Apple
// Weather (WeatherKit, 500,000 calls a month with the developer membership, then paid tiers).
// Both run on the device through Apple's frameworks, with no key. The formatting is pure and
// unit-tested; the lookups need the network (and WeatherKit its entitlement).

// MARK: - Places (Apple Maps)

enum PlaceSearch {
  struct Place: Equatable, Sendable {
    var name: String
    var address: String?
    var phone: String?
    var website: URL?
    var category: String?
    var latitude: Double
    var longitude: Double
    /// From the user, when the search was around them.
    var meters: Double?
    /// Opaque Apple Maps item identifier for `.mapItemDetailSheet(item:)` & `MKMapItemRequest`.
    var mapItemIdentifier: String?
  }

  /// Places for a query like "pharmacy near Place des Arts, Montreal", from Apple Maps: the what,
  /// searched only within a kilometre of the where (a loose query matched "Place du Commerce"
  /// across the river, 2026-11-12); the whole query anywhere when that finds nothing.
  @MainActor
  static func search(_ query: String, limit: Int = 5) async throws -> (places: [Place], area: String?) {
    let (what, place) = split(query)
    return try await search(what: what, near: place, originalQuery: query, limit: limit)
  }

  /// Structured place search taking explicit `what` and optional `near` area (landmark, city, or
  /// current-location token), bypassing natural-language preposition parsing across all languages.
  @MainActor
  static func search(
    what rawWhat: String, near rawPlace: String?, originalQuery: String? = nil, limit: Int = 5
  ) async throws -> (places: [Place], area: String?) {
    let what = rawWhat.trimmingCharacters(in: .whitespacesAndNewlines)
    let place = rawPlace?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedPlace = (place?.isEmpty == false) ? place : nil
    let poiCategories = pointOfInterestCategories(for: what)

    // Around the user, nearest first ("the nearest gas station").
    if let resolvedPlace, CurrentLocation.meansHere(resolvedPlace) {
      guard let here = await CurrentLocation.fetch() else { throw WebSearchError.locationUnavailable }
      let region = MKCoordinateRegion(
        center: here.coordinate, latitudinalMeters: 10_000, longitudinalMeters: 10_000)
      let items = try await runSearch(
        query: what, region: region, categories: poiCategories, requireRegion: false)
      let found = items.map { item in
        var entry = entry(from: item)
        entry.meters = item.location.distance(from: here)
        return entry
      }
      return (Array(found.sorted { ($0.meters ?? 0) < ($1.meters ?? 0) }.prefix(limit)), nil)
    }
    if let resolvedPlace, let area = await find(resolvedPlace, types: [.pointOfInterest, .address]) {
      let region = MKCoordinateRegion(
        center: area.location.coordinate, latitudinalMeters: 2_000, longitudinalMeters: 2_000)
      if let found = try? await runSearch(
        query: what, region: region, categories: poiCategories, requireRegion: true),
        !found.isEmpty
      {
        return (found.prefix(limit).map(entry(from:)), resolvedPlace)
      }
    }
    let fallbackQuery = originalQuery ?? (resolvedPlace.map { "\(what) \($0)" } ?? what)
    let found =
      (try? await runSearch(
        query: fallbackQuery, region: nil, categories: poiCategories, requireRegion: false)) ?? []
    if found.isEmpty, resolvedPlace == nil {
      // "Walmart closing time November 12 2026" / "Heures d'ouverture Walmart": the store, around the user.
      let store = LanguageSupport.stripPlaceHoursNoise(fallbackQuery)
      if !store.isEmpty, store.caseInsensitiveCompare(fallbackQuery) != .orderedSame {
        return try await search(what: store, near: "me", limit: limit)
      }
    }
    if found.isEmpty { throw WebSearchError.noResults }
    return (found.prefix(limit).map(entry(from:)), nil)
  }

  /// Queries Apple Maps with `MKPointOfInterestFilter` for recognized generic categories
  /// (`gasStation`, `restaurant`, `pharmacy`, ...) before falling back to an unfiltered search so
  /// unrelated text matches (e.g. "Gascon" for "gas station") are excluded while keeping full
  /// retail coverage within the search region.
  @MainActor
  private static func runSearch(
    query: String, region: MKCoordinateRegion?,
    categories: [MKPointOfInterestCategory]?, requireRegion: Bool
  ) async throws -> [MKMapItem] {
    func execute(with activeFilter: MKPointOfInterestFilter?) async throws -> [MKMapItem] {
      let request = MKLocalSearch.Request()
      request.resultTypes = activeFilter != nil ? [.pointOfInterest] : [.pointOfInterest, .address]
      request.naturalLanguageQuery = query
      if let region {
        request.region = region
        if requireRegion { request.regionPriority = .required }
      }
      if let activeFilter {
        request.pointOfInterestFilter = activeFilter
      }
      return try await MKLocalSearch(request: request).start().mapItems
    }
    if let categories, !categories.isEmpty {
      let filter = MKPointOfInterestFilter(including: categories)
      if let filtered = try? await execute(with: filter), !filtered.isEmpty {
        let exact = filtered.filter { item in
          item.pointOfInterestCategory.map(categories.contains) == true
        }
        if !exact.isEmpty { return exact }
        return filtered
      }
    }
    return try await execute(with: nil)
  }

  /// Maps canonical category keys from ``LanguageSupport/placePOICategory(for:)`` to MapKit categories.
  static func pointOfInterestCategories(for query: String) -> [MKPointOfInterestCategory]? {
    guard let key = LanguageSupport.placePOICategory(for: query) else { return nil }
    switch key {
    case "gasStation": return [.gasStation]
    case "evCharger": return [.evCharger]
    case "restaurant": return [.restaurant]
    case "cafe": return [.cafe]
    case "pharmacy": return [.pharmacy]
    case "hospital": return [.hospital]
    case "hotel": return [.hotel]
    case "parking": return [.parking]
    case "foodMarket": return [.foodMarket]
    case "bakery": return [.bakery]
    case "bank": return [.bank]
    case "atm": return [.atm]
    case "airport": return [.airport]
    case "park": return [.park, .nationalPark]
    case "museum": return [.museum]
    default: return nil
    }
  }

  /// Convenience wrapper returning an `MKPointOfInterestFilter` for generic category queries.
  static func pointOfInterestFilter(for query: String) -> MKPointOfInterestFilter? {
    pointOfInterestCategories(for: query).map { MKPointOfInterestFilter(including: $0) }
  }

  @MainActor
  private static func entry(from item: MKMapItem) -> Place {
    Place(
      name: item.name ?? "", address: item.address?.fullAddress, phone: item.phoneNumber,
      website: item.url, category: item.pointOfInterestCategory.map(categoryName),
      latitude: item.location.coordinate.latitude, longitude: item.location.coordinate.longitude,
      mapItemIdentifier: item.identifier?.rawValue)
  }

  /// Converts verified Apple Maps places into a typed inline ``PlacesCard`` action card.
  static func actionCard(_ places: [Place], query: String, area: String? = nil) -> ActionCardRecord? {
    guard !places.isEmpty else { return nil }
    let items = places.prefix(5).map { place in
      PlacesCard.PlaceItem(
        name: place.name,
        category: place.category,
        address: place.address,
        phone: place.phone,
        websiteURL: place.website?.absoluteString,
        latitude: place.latitude,
        longitude: place.longitude,
        distanceMeters: place.meters,
        mapItemIdentifier: place.mapItemIdentifier)
    }
    return ActionCardRecord(
      payload: .places(PlacesCard(query: query, areaLabel: area, places: Array(items))))
  }

  /// What a name designates on Apple Maps: a landmark as a point of interest, a city as an
  /// address. The address geocoder alone put "Place des Arts, Montreal" in Saint-Léonard and
  /// "Montreal" on a street in Longueuil (2026-11-12).
  @MainActor
  static func find(_ text: String, types: MKLocalSearch.ResultType) async -> MKMapItem? {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = text
    request.resultTypes = types
    if let item = try? await MKLocalSearch(request: request).start().mapItems.first { return item }
    return try? await MKGeocodingRequest(addressString: text)?.mapItems.first
  }

  /// Splits proximity place queries across languages ("pharmacy near Place des Arts",
  /// "farmacia cerca de …", "渋谷駅近くの薬局") into `(what, place)`.
  static func split(_ query: String) -> (what: String, place: String?) {
    LanguageSupport.splitPlaceQuery(query)
  }

  /// "MKPOICategoryPharmacy" as "pharmacy".
  static func categoryName(_ category: MKPointOfInterestCategory) -> String {
    let name = category.rawValue.replacingOccurrences(of: "MKPOICategory", with: "")
    return name.replacing(/([a-z])([A-Z])/) { "\($0.output.1) \($0.output.2)" }.lowercased()
  }

  /// One pinned source per place, linked to it on Apple Maps; `area`, when the search kept to
  /// one, is said in each (without it the reply doubted the places were near what was asked).
  static func results(_ places: [Place], area: String? = nil) -> [WebResult] {
    places.compactMap { place in
      var components = URLComponents(string: "https://maps.apple.com/")
      components?.queryItems = [
        .init(name: "q", value: place.name),
        .init(name: "ll", value: String(format: "%.5f,%.5f", place.latitude, place.longitude)),
      ]
      guard let url = components?.url else { return nil }
      let distance = place.meters.map {
        Measurement(value: $0, unit: UnitLength.meters).formatted(
          .measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
      }
      let lines = [
        place.name + (place.category.map { " (\($0))" } ?? ""),
        area.map { "Within about 1 km of \($0), according to Apple Maps" },
        distance.map { "About \($0) from the user, in a straight line" },
        place.address.map { "Address: \($0)" },
        place.phone.map { "Phone: \($0)" },
        place.website.map { "Website: \($0.absoluteString)" },
        // MapKit shares no opening hours with apps; Apple Maps shows them on the place's card.
        "Opening hours: not available here; the place's link opens it in Apple Maps, which shows them",
      ].compactMap { $0 }
      return WebResult(
        title: "\(place.name) — Apple Maps", url: url, snippet: place.address ?? "",
        content: lines.joined(separator: "\n"), pinned: true)
    }
  }
}

// MARK: - Weather (Apple Weather)

enum WeatherLookup {
  struct Report: Equatable, Sendable {
    var place: String
    var timeZone: TimeZone
    var now: Now
    var hours: [Hour]
    var days: [Day]
    var alerts: [Alert] = []
  }

  struct Now: Equatable, Sendable {
    var date: Date
    var temperature: Measurement<UnitTemperature>
    var feelsLike: Measurement<UnitTemperature>
    var condition: String
    var symbolName: String = "cloud.sun.fill"
    var windSpeed: Measurement<UnitSpeed>
    var humidity: Double
  }

  struct Hour: Equatable, Sendable {
    var date: Date
    var temperature: Measurement<UnitTemperature>
    var condition: String
    var symbolName: String = "cloud.sun.fill"
    var precipitationChance: Double
  }

  struct Day: Equatable, Sendable {
    var date: Date
    var high: Measurement<UnitTemperature>
    var low: Measurement<UnitTemperature>
    var condition: String
    var symbolName: String = "cloud.sun.fill"
    var precipitationChance: Double
  }

  struct Alert: Equatable, Sendable {
    var summary: String
    var severity: String
    var detailsURL: URL?
  }

  /// Where the user is, named by its city.
  @MainActor
  static func describe(_ here: CLLocation) async -> (name: String, location: CLLocation, timeZone: TimeZone) {
    let item = try? await MKReverseGeocodingRequest(location: here)?.mapItems.first
    return (item?.addressRepresentations?.cityWithContext ?? "the user's location", here, item?.timeZone ?? .current)
  }

  /// The place a query names, from Apple Maps, named by its city ("Montréal, QC").
  @MainActor
  static func locate(_ place: String) async throws -> (name: String, location: CLLocation, timeZone: TimeZone)? {
    guard let item = await PlaceSearch.find(place, types: .address) else { return nil }
    let name =
      item.addressRepresentations?.cityWithContext ?? item.addressRepresentations?.cityName
      ?? item.address?.shortAddress ?? item.name ?? place
    return (name, item.location, item.timeZone ?? .current)
  }

  /// Words of a weather query that aren't the place ("Montreal weather tomorrow",
  /// "Wetter Berlin morgen", "天気 東京 明日"), stripped across languages.
  static func placeName(in query: String) -> String {
    LanguageSupport.stripWeatherNoise(query)
  }

  /// The weather at `place` (where the user is for "here"): now, the next 12 hours, the next
  /// 10 days, and active severe weather alerts.
  static func report(for query: String) async throws -> Report? {
    let place = placeName(in: query)
    let found: (name: String, location: CLLocation, timeZone: TimeZone)?
    if place.isEmpty || CurrentLocation.meansHere(place) {
      guard let here = await CurrentLocation.fetch() else { throw WebSearchError.locationUnavailable }
      found = await describe(here)
    } else {
      found = try await locate(place)
    }
    guard let (name, location, timeZone) = found else { return nil }
    let (current, hourly, daily, alerts) = try await WeatherService.shared.weather(
      for: location, including: .current, .hourly, .daily, .alerts)
    return Report(
      place: name, timeZone: timeZone,
      now: Now(
        date: current.date, temperature: current.temperature, feelsLike: current.apparentTemperature,
        condition: current.condition.description, symbolName: current.symbolName,
        windSpeed: current.wind.speed, humidity: current.humidity),
      hours: hourly.forecast.filter { $0.date > current.date }.prefix(12).map {
        Hour(
          date: $0.date, temperature: $0.temperature, condition: $0.condition.description,
          symbolName: $0.symbolName, precipitationChance: $0.precipitationChance)
      },
      days: daily.forecast.prefix(10).map {
        Day(
          date: $0.date, high: $0.highTemperature, low: $0.lowTemperature, condition: $0.condition.description,
          symbolName: $0.symbolName, precipitationChance: $0.precipitationChance)
      },
      alerts: (alerts ?? []).prefix(5).map { alert in
        Alert(
          summary: alert.summary,
          severity: String(describing: alert.severity),
          detailsURL: alert.detailsURL)
      })
  }

  /// Builds a typed inline ``WeatherCard`` from an Apple Weather report.
  static func actionCard(
    _ report: Report, attributionLegalURL: URL? = nil, locale: Locale = .current
  ) -> ActionCardRecord {
    func temp(_ value: Measurement<UnitTemperature>) -> String {
      value.formatted(
        .measurement(
          width: .abbreviated, usage: .weather,
          numberFormatStyle: .number.precision(.fractionLength(0))
        ).locale(locale))
    }
    var dayStyle = Date.FormatStyle(
      date: .omitted, time: .omitted, locale: locale, timeZone: report.timeZone)
    dayStyle = dayStyle.weekday(.abbreviated)
    let wind = report.now.windSpeed.formatted(
      .measurement(
        width: .abbreviated, usage: .general,
        numberFormatStyle: .number.precision(.fractionLength(0))
      ).locale(locale))
    let today = report.days.first
    let card = WeatherCard(
      locationName: report.place,
      temperature: temp(report.now.temperature),
      feelsLike: temp(report.now.feelsLike),
      condition: report.now.condition,
      conditionSymbol: report.now.symbolName,
      high: today.map { temp($0.high) },
      low: today.map { temp($0.low) },
      humidityPercent: Int((report.now.humidity * 100).rounded()),
      windSpeed: wind,
      hourly: report.hours.prefix(6).map { h in
        WeatherCard.HourItem(
          date: h.date, temperature: temp(h.temperature), symbolName: h.symbolName,
          precipitationPercent: Int((h.precipitationChance * 100).rounded()))
      },
      daily: report.days.prefix(5).map { d in
        WeatherCard.DayItem(
          date: d.date, label: d.date.formatted(dayStyle), high: temp(d.high), low: temp(d.low),
          symbolName: d.symbolName, precipitationPercent: Int((d.precipitationChance * 100).rounded()))
      },
      alerts: report.alerts.map { a in
        WeatherCard.AlertItem(
          summary: a.summary, severity: a.severity, detailsURL: a.detailsURL?.absoluteString)
      },
      attributionLegalURL: attributionLegalURL?.absoluteString)
    return ActionCardRecord(payload: .weather(card))
  }

  /// Static legal attribution fallback when `WeatherService.shared.attribution` is unreachable
  /// offline or in unsigned builds, so legal attribution always remains visible.
  static let fallbackServiceName = "Apple Weather"
  static let fallbackLegalURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

  /// Apple Weather's mark (for dark backgrounds, the app's) and legal page: WeatherKit's terms
  /// and App Review require both wherever its data shows (`WeatherAttributionMark`).
  struct Mark: Equatable, Sendable {
    var name: String
    var image: URL
    var legal: URL
  }

  static func mark() async -> Mark? {
    guard let attribution = try? await WeatherService.shared.attribution else { return nil }
    return Mark(name: attribution.serviceName, image: attribution.combinedMarkDarkURL, legal: attribution.legalPageURL)
  }

  /// Whether a source is Apple Weather's (its link is the legal page).
  static func isAttribution(_ url: String?) -> Bool {
    url.flatMap(URL.init(string:))?.host() == "weatherkit.apple.com"
  }

  /// Apple's attribution: the source's name (" Weather") and its legal page, which every
  /// display of the data must show (the reply cites it).
  static func attribution() async -> (name: String, url: URL) {
    if let attribution = try? await WeatherService.shared.attribution {
      return (attribution.serviceName, attribution.legalPageURL)
    }
    return (fallbackServiceName, fallbackLegalURL)
  }

  /// The source's text, in the place's own time and the user's units.
  static func describe(_ report: Report, locale: Locale = .current) -> String {
    var day = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, timeZone: report.timeZone)
    day = day.weekday(.abbreviated)
    let hour = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: report.timeZone)
    func temperature(_ value: Measurement<UnitTemperature>) -> String {
      value.formatted(.measurement(width: .abbreviated, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))).locale(locale))
    }
    func percent(_ value: Double) -> String { "\(Int((value * 100).rounded())) %" }
    // Today and tomorrow named, in the place's own calendar: given only weekdays, a reply put
    // "tomorrow" on the wrong line ("tomorrow, Sunday, November 22" on Monday the 16th, 2026-11-15).
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = report.timeZone
    func relative(_ date: Date) -> String? {
      if calendar.isDate(date, inSameDayAs: report.now.date) { return "Today" }
      guard let next = calendar.date(byAdding: .day, value: 1, to: report.now.date) else { return nil }
      return calendar.isDate(date, inSameDayAs: next) ? "Tomorrow" : nil
    }
    var lines = ["Weather for \(report.place) (local time):"]
    let now = report.now
    lines.append(
      "Now (\(now.date.formatted(hour))): \(temperature(now.temperature)), feels like \(temperature(now.feelsLike)), "
        + "\(now.condition.lowercased()), wind \(now.windSpeed.formatted(.measurement(width: .abbreviated, usage: .general, numberFormatStyle: .number.precision(.fractionLength(0))).locale(locale))), humidity \(percent(now.humidity))")
    if !report.hours.isEmpty {
      lines.append("Next hours:")
      for item in report.hours.enumerated() where item.offset.isMultiple(of: 3) {
        let next = item.element
        let label = relative(next.date) == "Tomorrow" ? " tomorrow" : ""
        lines.append(
          "  \(next.date.formatted(hour))\(label): \(temperature(next.temperature)), \(next.condition.lowercased()), "
            + "\(percent(next.precipitationChance)) chance of precipitation")
      }
    }
    lines.append("Next days:")
    for next in report.days {
      let label = relative(next.date).map { "\($0), " } ?? ""
      lines.append(
        "  \(label)\(next.date.formatted(day)): \(next.condition.lowercased()), high \(temperature(next.high)), "
          + "low \(temperature(next.low)), \(percent(next.precipitationChance)) chance of precipitation")
    }
    if !report.alerts.isEmpty {
      lines.append("Alerts:")
      for alert in report.alerts {
        lines.append("  [\(alert.severity)] \(alert.summary)")
      }
    }
    return lines.joined(separator: "\n")
  }
}
