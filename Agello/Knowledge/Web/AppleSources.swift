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
  }

  /// Places for a query like "pharmacy near Place des Arts, Montreal", from Apple Maps: the what,
  /// searched only within a kilometre of the where (a loose query matched "Place du Commerce"
  /// across the river, 2026-11-12); the whole query anywhere when that finds nothing.
  @MainActor
  static func search(_ query: String, limit: Int = 5) async throws -> (places: [Place], area: String?) {
    let (what, place) = split(query)
    // Around the user, nearest first ("the nearest gas station").
    if let place, CurrentLocation.meansHere(place) {
      guard let here = await CurrentLocation.fetch() else { throw WebSearchError.locationUnavailable }
      let request = MKLocalSearch.Request()
      request.resultTypes = [.pointOfInterest, .address]
      request.naturalLanguageQuery = what
      request.region = MKCoordinateRegion(center: here.coordinate, latitudinalMeters: 10_000, longitudinalMeters: 10_000)
      let found = try await MKLocalSearch(request: request).start().mapItems.map { item in
        var place = entry(from: item)
        place.meters = item.location.distance(from: here)
        return place
      }
      return (Array(found.sorted { ($0.meters ?? 0) < ($1.meters ?? 0) }.prefix(limit)), nil)
    }
    if let place, let area = await find(place, types: [.pointOfInterest, .address]) {
      let request = MKLocalSearch.Request()
      request.resultTypes = [.pointOfInterest, .address]
      request.naturalLanguageQuery = what
      request.region = MKCoordinateRegion(
        center: area.location.coordinate, latitudinalMeters: 2_000, longitudinalMeters: 2_000)
      request.regionPriority = .required
      if let found = try? await MKLocalSearch(request: request).start().mapItems, !found.isEmpty {
        return (found.prefix(limit).map(entry(from:)), place)
      }
    }
    let request = MKLocalSearch.Request()
    request.resultTypes = [.pointOfInterest, .address]
    request.naturalLanguageQuery = query
    let found = (try? await MKLocalSearch(request: request).start().mapItems) ?? []
    if found.isEmpty, place == nil {
      // "Walmart closing time November 12 2026" found nothing: the store, around the user.
      let store = WeatherLookup.placeName(in: query).split(whereSeparator: \.isWhitespace)
        .filter { !["closing", "close", "closes", "opening", "open", "hours", "time", "at", "what", "does"].contains($0.lowercased()) }
        .joined(separator: " ")
      if !store.isEmpty { return try await search("\(store) near me", limit: limit) }
    }
    if found.isEmpty { throw WebSearchError.noResults }
    return (found.prefix(limit).map(entry(from:)), nil)
  }

  @MainActor
  private static func entry(from item: MKMapItem) -> Place {
    Place(
      name: item.name ?? "", address: item.address?.fullAddress, phone: item.phoneNumber,
      website: item.url, category: item.pointOfInterestCategory.map(categoryName),
      latitude: item.location.coordinate.latitude, longitude: item.location.coordinate.longitude)
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

  /// "pharmacy near Place des Arts, Montreal" as ("pharmacy", "Place des Arts, Montreal"); a
  /// query without "near" is all what.
  static func split(_ query: String) -> (what: String, place: String?) {
    guard let range = query.range(of: " near ", options: .caseInsensitive) else { return (query, nil) }
    let what = query[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
    let place = query[range.upperBound...].trimmingCharacters(in: .whitespaces)
    return what.isEmpty || place.isEmpty ? (query, nil) : (what, place)
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
  }

  struct Now: Equatable, Sendable {
    var date: Date
    var temperature: Measurement<UnitTemperature>
    var feelsLike: Measurement<UnitTemperature>
    var condition: String
    var windSpeed: Measurement<UnitSpeed>
    var humidity: Double
  }

  struct Hour: Equatable, Sendable {
    var date: Date
    var temperature: Measurement<UnitTemperature>
    var condition: String
    var precipitationChance: Double
  }

  struct Day: Equatable, Sendable {
    var date: Date
    var high: Measurement<UnitTemperature>
    var low: Measurement<UnitTemperature>
    var condition: String
    var precipitationChance: Double
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

  /// Words of a weather query that aren't the place ("Montreal weather tomorrow"): the place
  /// search read them as an address and found Morris, Manitoba (2026-11-12).
  static func placeName(in query: String) -> String {
    let noise: Set = [
      "weather", "forecast", "temperature", "today", "tomorrow", "tonight", "this", "week", "weekend",
      "rain", "snow", "will", "it", "météo", "prévisions", "demain", "aujourd'hui", "pluie", "neige", "ce",
    ]
    let months = Set(Calendar(identifier: .gregorian).monthSymbols.map { $0.lowercased() })
    return query.split(whereSeparator: \.isWhitespace)
      .filter { word in
        let plain = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        // "Montreal weather forecast November 13 2026": the date isn't the place either.
        return !noise.contains(plain) && !months.contains(plain) && Int(plain) == nil
      }
      .joined(separator: " ").trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
  }

  /// The weather at `place` (where the user is for "here"): now, the next 12 hours and the next
  /// 10 days.
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
    let (current, hourly, daily) = try await WeatherService.shared.weather(
      for: location, including: .current, .hourly, .daily)
    return Report(
      place: name, timeZone: timeZone,
      now: Now(
        date: current.date, temperature: current.temperature, feelsLike: current.apparentTemperature,
        condition: current.condition.description, windSpeed: current.wind.speed, humidity: current.humidity),
      hours: hourly.forecast.filter { $0.date > current.date }.prefix(12).map {
        Hour(
          date: $0.date, temperature: $0.temperature, condition: $0.condition.description,
          precipitationChance: $0.precipitationChance)
      },
      days: daily.forecast.prefix(10).map {
        Day(
          date: $0.date, high: $0.highTemperature, low: $0.lowTemperature, condition: $0.condition.description,
          precipitationChance: $0.precipitationChance)
      })
  }

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
    return ("Apple Weather", URL(string: "https://weatherkit.apple.com/legal-attribution.html")!)
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
    var lines = ["Weather for \(report.place) (local time):"]
    let now = report.now
    lines.append(
      "Now (\(now.date.formatted(hour))): \(temperature(now.temperature)), feels like \(temperature(now.feelsLike)), "
        + "\(now.condition.lowercased()), wind \(now.windSpeed.formatted(.measurement(width: .abbreviated, usage: .general, numberFormatStyle: .number.precision(.fractionLength(0))).locale(locale))), humidity \(percent(now.humidity))")
    if !report.hours.isEmpty {
      lines.append("Next hours:")
      for item in report.hours.enumerated() where item.offset.isMultiple(of: 3) {
        let next = item.element
        lines.append(
          "  \(next.date.formatted(hour)): \(temperature(next.temperature)), \(next.condition.lowercased()), "
            + "\(percent(next.precipitationChance)) chance of precipitation")
      }
    }
    lines.append("Next days:")
    for next in report.days {
      lines.append(
        "  \(next.date.formatted(day)): \(next.condition.lowercased()), high \(temperature(next.high)), "
          + "low \(temperature(next.low)), \(percent(next.precipitationChance)) chance of precipitation")
    }
    return lines.joined(separator: "\n")
  }
}
