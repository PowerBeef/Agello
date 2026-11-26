import Foundation

/// Decodes a JSON array while silently skipping individual elements that fail to decode
/// (forward-compatibility guard so future card types or schema additions never wipe existing
/// `MessageParts` fields like `sources`, `toolActivity`, or `files`).
struct LossyArray<Element: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
  var elements: [Element]

  init(_ elements: [Element] = []) {
    self.elements = elements
  }

  init(from decoder: Decoder) throws {
    var container = try decoder.unkeyedContainer()
    var decoded: [Element] = []
    while !container.isAtEnd {
      let before = container.currentIndex
      if let item = try? container.decode(Element.self) {
        decoded.append(item)
      } else {
        _ = try? container.decode(AnyDecodable.self)
      }
      if container.currentIndex == before {
        break
      }
    }
    self.elements = decoded
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    for element in elements {
      try container.encode(element)
    }
  }
}

/// Untyped sentinel capable of consuming any JSON token (null, primitive, nested array, or object)
/// so corrupt or forward-incompatible entries always advance the unkeyed container index.
private struct AnyDecodable: Decodable {
  private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
      self.stringValue = "\(intValue)"
      self.intValue = intValue
    }
  }

  init(from decoder: Decoder) throws {
    if let single = try? decoder.singleValueContainer() {
      if single.decodeNil() { return }
      if (try? single.decode(Bool.self)) != nil { return }
      if (try? single.decode(Int64.self)) != nil { return }
      if (try? single.decode(Double.self)) != nil { return }
      if (try? single.decode(String.self)) != nil { return }
    }
    if var unkeyed = try? decoder.unkeyedContainer() {
      while !unkeyed.isAtEnd {
        let before = unkeyed.currentIndex
        _ = try? unkeyed.decode(AnyDecodable.self)
        if unkeyed.currentIndex == before { break }
      }
      return
    }
    if let keyed = try? decoder.container(keyedBy: AnyCodingKey.self) {
      for key in keyed.allKeys {
        _ = try? keyed.decode(AnyDecodable.self, forKey: key)
      }
    }
  }
}

/// Typed, Swift-verified action card recorded out-of-band by tools or structured web lookups
/// and persisted inside `MessageParts.actionCards` (zero SwiftData schema migration).
struct ActionCardRecord: Codable, Equatable, Sendable, Identifiable {
  var id: UUID
  var payload: Payload

  init(id: UUID = UUID(), payload: Payload) {
    self.id = id
    self.payload = payload
  }

  var isRenderable: Bool {
    if case .unknown = payload { return false }
    return true
  }

  /// Stable key for deduplicating cards produced within the same turn (e.g., Search ON + tool).
  var deduplicationKey: String {
    switch payload {
    case .places(let card):
      let area = (card.areaLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let top = card.places.first?.name.lowercased() ?? ""
      return "places:\(card.query.lowercased()):\(area):\(top)"
    case .route(let card):
      return "route:\(card.destinationName.lowercased()):\(card.transport.lowercased())"
    case .calendarEvent(let card):
      let key = card.eventIdentifier ?? "\(card.title.lowercased()):\(Int(card.startDate.timeIntervalSince1970))"
      return "calendar:\(key)"
    case .reminder(let card):
      let key = card.reminderIdentifier ?? card.title.lowercased()
      return "reminder:\(key)"
    case .contact(let card):
      let key = card.contactIdentifier ?? card.fullName.lowercased()
      return "contact:\(key)"
    case .messageDraft(let card):
      let recips = card.recipients.map { $0.lowercased() }.joined(separator: ",")
      let subject = (card.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return "draft:\(card.channel.rawValue):\(recips):\(subject):\(card.body.prefix(40).lowercased())"
    case .weather(let card):
      return "weather:\(card.locationName.lowercased())"
    case .alarm(let card):
      return "alarm:\(card.alarmID)"
    case .automationHandoff(let card):
      return "automation:\(card.callbackRequestID ?? card.shortcutID)"
    case .unknown:
      return "unknown:\(id.uuidString)"
    }
  }

  /// Blank-area key for an area-labelled `.places` card so a later area-enriched result for
  /// the same `(query, topPlace)` can upgrade an earlier unlabelled card in place while keeping
  /// distinct non-empty `areaLabel`s separate.
  fileprivate var unlabelledPlacesKey: String? {
    guard case .places(let card) = payload else { return nil }
    let area = (card.areaLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !area.isEmpty else { return nil }
    let top = card.places.first?.name.lowercased() ?? ""
    return "places:\(card.query.lowercased())::\(top)"
  }

  typealias Payload = ActionCardPayload
}

enum ActionCardPayload: Codable, Equatable, Sendable {
  case places(PlacesCard)
  case route(RouteCard)
  case calendarEvent(CalendarEventCard)
  case reminder(ReminderCard)
  case contact(ContactCard)
  case messageDraft(MessageDraftCard)
  case weather(WeatherCard)
  case alarm(AlarmCard)
  case automationHandoff(AutomationHandoffCard)
  case unknown

  private enum CodingKeys: String, CodingKey {
    case kind, data
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = (try? container.decode(String.self, forKey: .kind)) ?? ""
    switch kind {
    case "places":
      self = (try? .places(container.decode(PlacesCard.self, forKey: .data))) ?? .unknown
    case "route":
      self = (try? .route(container.decode(RouteCard.self, forKey: .data))) ?? .unknown
    case "calendarEvent":
      self = (try? .calendarEvent(container.decode(CalendarEventCard.self, forKey: .data))) ?? .unknown
    case "reminder":
      self = (try? .reminder(container.decode(ReminderCard.self, forKey: .data))) ?? .unknown
    case "contact":
      self = (try? .contact(container.decode(ContactCard.self, forKey: .data))) ?? .unknown
    case "messageDraft":
      self = (try? .messageDraft(container.decode(MessageDraftCard.self, forKey: .data))) ?? .unknown
    case "weather":
      self = (try? .weather(container.decode(WeatherCard.self, forKey: .data))) ?? .unknown
    case "alarm":
      self = (try? .alarm(container.decode(AlarmCard.self, forKey: .data))) ?? .unknown
    case "automationHandoff":
      self =
        (try? .automationHandoff(container.decode(AutomationHandoffCard.self, forKey: .data)))
        ?? .unknown
    default:
      self = .unknown
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .places(let card):
      try container.encode("places", forKey: .kind)
      try container.encode(card, forKey: .data)
    case .route(let card):
      try container.encode("route", forKey: .kind)
      try container.encode(card, forKey: .data)
    case .calendarEvent(let card):
      try container.encode("calendarEvent", forKey: .kind)
      try container.encode(card, forKey: .data)
    case .reminder(let card):
      try container.encode("reminder", forKey: .kind)
      try container.encode(card, forKey: .data)
    case .contact(let card):
      try container.encode("contact", forKey: .kind)
      try container.encode(card, forKey: .data)
    case .messageDraft(let card):
      try container.encode("messageDraft", forKey: .kind)
      try container.encode(card, forKey: .data)
    case .weather(let card):
      try container.encode("weather", forKey: .kind)
      try container.encode(card, forKey: .data)
    case .alarm(let card):
      try container.encode("alarm", forKey: .kind)
      try container.encode(card, forKey: .data)
    case .automationHandoff(let card):
      try container.encode("automationHandoff", forKey: .kind)
      try container.encode(card, forKey: .data)
    case .unknown:
      try container.encode("unknown", forKey: .kind)
    }
  }
}

// MARK: - Typed Card Payloads (Pure Foundation)

private func normalizedItemID(_ raw: String?) -> String {
  guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
    return UUID().uuidString
  }
  return trimmed
}

private enum PlaceItemCodingKeys: String, CodingKey {
  case id, name, category, address, phone, websiteURL, latitude, longitude, distanceMeters,
    mapItemIdentifier
}

private enum WeatherHourCodingKeys: String, CodingKey {
  case id, date, temperature, symbolName, precipitationPercent
}

private enum WeatherDayCodingKeys: String, CodingKey {
  case id, date, label, high, low, symbolName, precipitationPercent
}

private enum WeatherAlertCodingKeys: String, CodingKey {
  case id, summary, severity, detailsURL
}

struct PlacesCard: Codable, Equatable, Sendable {
  struct PlaceItem: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var category: String?
    var address: String?
    var phone: String?
    var websiteURL: String?
    var latitude: Double
    var longitude: Double
    var distanceMeters: Double?
    var mapItemIdentifier: String?

    init(
      id: String? = nil, name: String, category: String? = nil, address: String? = nil,
      phone: String? = nil, websiteURL: String? = nil, latitude: Double, longitude: Double,
      distanceMeters: Double? = nil, mapItemIdentifier: String? = nil
    ) {
      self.id = normalizedItemID(id)
      self.name = name
      self.category = category
      self.address = address
      self.phone = phone
      self.websiteURL = websiteURL
      self.latitude = latitude
      self.longitude = longitude
      self.distanceMeters = distanceMeters
      self.mapItemIdentifier = mapItemIdentifier
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: PlaceItemCodingKeys.self)
      id = normalizedItemID(try c.decodeIfPresent(String.self, forKey: .id))
      name = try c.decode(String.self, forKey: .name)
      category = try c.decodeIfPresent(String.self, forKey: .category)
      address = try c.decodeIfPresent(String.self, forKey: .address)
      phone = try c.decodeIfPresent(String.self, forKey: .phone)
      websiteURL = try c.decodeIfPresent(String.self, forKey: .websiteURL)
      latitude = try c.decode(Double.self, forKey: .latitude)
      longitude = try c.decode(Double.self, forKey: .longitude)
      distanceMeters = try c.decodeIfPresent(Double.self, forKey: .distanceMeters)
      mapItemIdentifier = try c.decodeIfPresent(String.self, forKey: .mapItemIdentifier)
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: PlaceItemCodingKeys.self)
      try c.encode(id, forKey: .id)
      try c.encode(name, forKey: .name)
      try c.encodeIfPresent(category, forKey: .category)
      try c.encodeIfPresent(address, forKey: .address)
      try c.encodeIfPresent(phone, forKey: .phone)
      try c.encodeIfPresent(websiteURL, forKey: .websiteURL)
      try c.encode(latitude, forKey: .latitude)
      try c.encode(longitude, forKey: .longitude)
      try c.encodeIfPresent(distanceMeters, forKey: .distanceMeters)
      try c.encodeIfPresent(mapItemIdentifier, forKey: .mapItemIdentifier)
    }
  }

  var query: String
  var areaLabel: String?
  var places: [PlaceItem]
}

struct RouteCard: Codable, Equatable, Sendable {
  struct Step: Codable, Equatable, Sendable, Identifiable {
    var id: Int
    var instruction: String
    var distanceMeters: Double
  }

  var originName: String
  var originLatitude: Double?
  var originLongitude: Double?
  var originIsCurrentLocation: Bool
  var destinationName: String
  var destinationAddress: String?
  var destinationLatitude: Double
  var destinationLongitude: Double
  var destinationMapItemIdentifier: String?
  /// Canonical mode: `"driving"`, `"walking"`, `"cycling"`, or `"transit"`.
  var transport: String
  var distanceMeters: Double
  var expectedTravelSeconds: Double
  var routeName: String?
  var steps: [Step]
}

struct CalendarEventCard: Codable, Equatable, Sendable {
  enum Status: String, Codable, Equatable, Sendable {
    case created, found, updated, deleted
  }

  var status: Status
  var eventIdentifier: String?
  var title: String
  var startDate: Date
  var endDate: Date
  var isAllDay: Bool
  var location: String?
  var calendarName: String?
}

struct ReminderCard: Codable, Equatable, Sendable {
  enum Status: String, Codable, Equatable, Sendable {
    case created, found, completed, updated, deleted
  }

  var status: Status
  var reminderIdentifier: String?
  var title: String
  var dueDate: Date?
  var listName: String?
  var isCompleted: Bool
}

struct ContactCard: Codable, Equatable, Sendable {
  var contactIdentifier: String?
  var fullName: String
  var organization: String?
  var phones: [String]
  var emails: [String]
  var postalAddress: String?
}

struct MessageDraftCard: Codable, Equatable, Sendable {
  enum Channel: String, Codable, Equatable, Sendable {
    case sms, email
  }

  var channel: Channel
  var recipients: [String]
  var subject: String?
  var body: String
  /// Recipients not found in Contacts or directly typed by the user in this turn.
  var unverifiedRecipients: [String]
}

struct WeatherCard: Codable, Equatable, Sendable {
  struct HourItem: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var date: Date
    var temperature: String
    var symbolName: String
    var precipitationPercent: Int

    init(
      id: String? = nil, date: Date, temperature: String, symbolName: String,
      precipitationPercent: Int
    ) {
      self.id = normalizedItemID(id)
      self.date = date
      self.temperature = temperature
      self.symbolName = symbolName
      self.precipitationPercent = precipitationPercent
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: WeatherHourCodingKeys.self)
      id = normalizedItemID(try c.decodeIfPresent(String.self, forKey: .id))
      date = try c.decode(Date.self, forKey: .date)
      temperature = try c.decode(String.self, forKey: .temperature)
      symbolName = try c.decode(String.self, forKey: .symbolName)
      precipitationPercent = try c.decode(Int.self, forKey: .precipitationPercent)
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: WeatherHourCodingKeys.self)
      try c.encode(id, forKey: .id)
      try c.encode(date, forKey: .date)
      try c.encode(temperature, forKey: .temperature)
      try c.encode(symbolName, forKey: .symbolName)
      try c.encode(precipitationPercent, forKey: .precipitationPercent)
    }
  }

  struct DayItem: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var date: Date
    var label: String
    var high: String
    var low: String
    var symbolName: String
    var precipitationPercent: Int

    init(
      id: String? = nil, date: Date, label: String, high: String, low: String,
      symbolName: String, precipitationPercent: Int
    ) {
      self.id = normalizedItemID(id)
      self.date = date
      self.label = label
      self.high = high
      self.low = low
      self.symbolName = symbolName
      self.precipitationPercent = precipitationPercent
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: WeatherDayCodingKeys.self)
      id = normalizedItemID(try c.decodeIfPresent(String.self, forKey: .id))
      date = try c.decode(Date.self, forKey: .date)
      label = try c.decode(String.self, forKey: .label)
      high = try c.decode(String.self, forKey: .high)
      low = try c.decode(String.self, forKey: .low)
      symbolName = try c.decode(String.self, forKey: .symbolName)
      precipitationPercent = try c.decode(Int.self, forKey: .precipitationPercent)
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: WeatherDayCodingKeys.self)
      try c.encode(id, forKey: .id)
      try c.encode(date, forKey: .date)
      try c.encode(label, forKey: .label)
      try c.encode(high, forKey: .high)
      try c.encode(low, forKey: .low)
      try c.encode(symbolName, forKey: .symbolName)
      try c.encode(precipitationPercent, forKey: .precipitationPercent)
    }
  }

  struct AlertItem: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var summary: String
    var severity: String
    var detailsURL: String?

    init(id: String? = nil, summary: String, severity: String, detailsURL: String? = nil) {
      self.id = normalizedItemID(id)
      self.summary = summary
      self.severity = severity
      self.detailsURL = detailsURL
    }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: WeatherAlertCodingKeys.self)
      id = normalizedItemID(try c.decodeIfPresent(String.self, forKey: .id))
      summary = try c.decode(String.self, forKey: .summary)
      severity = try c.decode(String.self, forKey: .severity)
      detailsURL = try c.decodeIfPresent(String.self, forKey: .detailsURL)
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: WeatherAlertCodingKeys.self)
      try c.encode(id, forKey: .id)
      try c.encode(summary, forKey: .summary)
      try c.encode(severity, forKey: .severity)
      try c.encodeIfPresent(detailsURL, forKey: .detailsURL)
    }
  }

  var locationName: String
  var temperature: String
  var feelsLike: String?
  var condition: String
  var conditionSymbol: String
  var high: String?
  var low: String?
  var humidityPercent: Int?
  var windSpeed: String?
  var hourly: [HourItem]
  var daily: [DayItem]
  var alerts: [AlertItem]
  var attributionLegalURL: String?

  private enum CodingKeys: String, CodingKey {
    case locationName, temperature, feelsLike, condition, conditionSymbol, high, low,
      humidityPercent, windSpeed, hourly, daily, alerts, attributionLegalURL
  }

  init(
    locationName: String, temperature: String, feelsLike: String? = nil, condition: String,
    conditionSymbol: String, high: String? = nil, low: String? = nil,
    humidityPercent: Int? = nil, windSpeed: String? = nil, hourly: [HourItem] = [],
    daily: [DayItem] = [], alerts: [AlertItem] = [], attributionLegalURL: String? = nil
  ) {
    self.locationName = locationName
    self.temperature = temperature
    self.feelsLike = feelsLike
    self.condition = condition
    self.conditionSymbol = conditionSymbol
    self.high = high
    self.low = low
    self.humidityPercent = humidityPercent
    self.windSpeed = windSpeed
    self.hourly = hourly
    self.daily = daily
    self.alerts = alerts
    self.attributionLegalURL = attributionLegalURL
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    locationName = try c.decode(String.self, forKey: .locationName)
    temperature = try c.decode(String.self, forKey: .temperature)
    feelsLike = try c.decodeIfPresent(String.self, forKey: .feelsLike)
    condition = try c.decode(String.self, forKey: .condition)
    conditionSymbol = try c.decode(String.self, forKey: .conditionSymbol)
    high = try c.decodeIfPresent(String.self, forKey: .high)
    low = try c.decodeIfPresent(String.self, forKey: .low)
    humidityPercent = try c.decodeIfPresent(Int.self, forKey: .humidityPercent)
    windSpeed = try c.decodeIfPresent(String.self, forKey: .windSpeed)
    hourly = try c.decodeIfPresent([HourItem].self, forKey: .hourly) ?? []
    daily = try c.decodeIfPresent([DayItem].self, forKey: .daily) ?? []
    alerts = try c.decodeIfPresent([AlertItem].self, forKey: .alerts) ?? []
    attributionLegalURL = try c.decodeIfPresent(String.self, forKey: .attributionLegalURL)
  }
}

struct AlarmCard: Codable, Equatable, Sendable {
  enum Kind: String, Codable, Equatable, Sendable {
    case timer, alarm
  }

  enum State: String, Codable, Equatable, Sendable {
    case scheduled, countdown, paused, alerting, cancelled
  }

  var alarmID: String
  var kind: Kind
  var label: String
  var fireDate: Date?
  var hour: Int?
  var minute: Int?
  var weekdays: [String]
  var durationSeconds: Double?
  var state: State
}

struct AutomationHandoffCard: Codable, Equatable, Sendable {
  enum State: String, Codable, Equatable, Sendable {
    case readyToRun, completed, failed, cancelled
  }

  var shortcutID: String
  var shortcutName: String
  var inputSummary: String?
  var state: State
  var resultSummary: String?
  var callbackRequestID: String?
}

// MARK: - Merging & Capping

enum ActionCards {
  static let maxPerTurn = 6

  /// Merges pre-send cards (e.g. Search ON) with mid-stream tool cards without dropping initial
  /// cards, deduplicates by `deduplicationKey` (later card wins on status updates), filters
  /// unknown payloads, and caps at `limit`.
  static func merge(
    _ initial: [ActionCardRecord], _ streamed: [ActionCardRecord], limit: Int = maxPerTurn
  ) -> [ActionCardRecord] {
    var result: [ActionCardRecord] = []
    var indexByKey: [String: Int] = [:]
    for card in initial + streamed where card.isRenderable {
      let key = card.deduplicationKey
      if let existingIndex = indexByKey[key] {
        result[existingIndex] = card
      } else if let unlabelledKey = card.unlabelledPlacesKey,
        let existingIndex = indexByKey.removeValue(forKey: unlabelledKey)
      {
        result[existingIndex] = card
        indexByKey[key] = existingIndex
      } else {
        guard result.count < limit else { continue }
        indexByKey[key] = result.count
        result.append(card)
      }
    }
    return result
  }
}
