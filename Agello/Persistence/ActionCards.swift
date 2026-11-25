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
      if let item = try? container.decode(Element.self) {
        decoded.append(item)
      } else {
        _ = try? container.decode(IgnoredValue.self)
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

  private struct IgnoredValue: Decodable {}
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
      let top = card.places.first?.name.lowercased() ?? ""
      return "places:\(card.query.lowercased()):\(top)"
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
      return "draft:\(card.channel.rawValue):\(recips):\(card.body.prefix(40).lowercased())"
    case .weather(let card):
      return "weather:\(card.locationName.lowercased())"
    case .alarm(let card):
      return "alarm:\(card.alarmID)"
    case .unknown:
      return "unknown:\(id.uuidString)"
    }
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
    case .unknown:
      try container.encode("unknown", forKey: .kind)
    }
  }
}

// MARK: - Typed Card Payloads (Pure Foundation)

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
      self.id = id ?? mapItemIdentifier ?? String(format: "%@|%.5f|%.5f", name, latitude, longitude)
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
    var id: String { "\(Int(date.timeIntervalSince1970))" }
    var date: Date
    var temperature: String
    var symbolName: String
    var precipitationPercent: Int
  }

  struct DayItem: Codable, Equatable, Sendable, Identifiable {
    var id: String { "\(Int(date.timeIntervalSince1970))" }
    var date: Date
    var label: String
    var high: String
    var low: String
    var symbolName: String
    var precipitationPercent: Int
  }

  struct AlertItem: Codable, Equatable, Sendable, Identifiable {
    var id: String { "\(summary)|\(severity)" }
    var summary: String
    var severity: String
    var detailsURL: String?
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
      } else {
        guard result.count < limit else { continue }
        indexByKey[key] = result.count
        result.append(card)
      }
    }
    return result
  }
}
