import Foundation

/// Pure, App Store Guideline 2.5.1–compliant URL builders and RFC 5545 / RFC 6350 exporters for
/// inline Action Cards. Uses strictly public schemes (`https`, `tel`, `sms`, `mailto`, `facetime`)
/// and sanitizes every user/tool value before constructing a URL.
enum NativeActionURLs {
  // MARK: - Apple Maps Universal Links (fallback & Share)

  static func appleMapsPlace(
    name: String, latitude: Double, longitude: Double
  ) -> URL? {
    guard latitude.isFinite, longitude.isFinite else { return nil }
    var components = URLComponents(string: "https://maps.apple.com/")
    components?.queryItems = [
      URLQueryItem(name: "q", value: name),
      URLQueryItem(name: "ll", value: String(format: "%.5f,%.5f", latitude, longitude)),
    ]
    return components?.url
  }

  static func appleMapsDirections(
    destinationName: String,
    destinationLatitude: Double,
    destinationLongitude: Double,
    originLatitude: Double? = nil,
    originLongitude: Double? = nil,
    transport: String = "driving"
  ) -> URL? {
    guard destinationLatitude.isFinite, destinationLongitude.isFinite else { return nil }
    let dirFlag: String
    switch transport.lowercased() {
    case "walking": dirFlag = "w"
    case "transit": dirFlag = "r"
    case "cycling": dirFlag = "c"
    default: dirFlag = "d"
    }
    var items: [URLQueryItem] = [
      URLQueryItem(
        name: "daddr",
        value: String(format: "%.5f,%.5f", destinationLatitude, destinationLongitude)),
      URLQueryItem(name: "q", value: destinationName),
      URLQueryItem(name: "dirflg", value: dirFlag),
    ]
    if let originLatitude, let originLongitude, originLatitude.isFinite, originLongitude.isFinite {
      items.insert(
        URLQueryItem(
          name: "saddr",
          value: String(format: "%.5f,%.5f", originLatitude, originLongitude)),
        at: 0)
    }
    var components = URLComponents(string: "https://maps.apple.com/")
    components?.queryItems = items
    return components?.url
  }

  // MARK: - Communication schemes (public iOS URL schemes only)

  /// Sanitizes a phone number to digits and an optional leading `+`, requiring at least 3 digits.
  static func sanitizedPhone(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let hasPlus = trimmed.hasPrefix("+")
    let digits = trimmed.filter(\.isNumber)
    guard digits.count >= 3 else { return nil }
    return hasPlus ? "+\(digits)" : digits
  }

  static func phone(_ raw: String) -> URL? {
    guard let number = sanitizedPhone(raw) else { return nil }
    return URL(string: "tel:\(number)")
  }

  static func sms(recipient: String, body: String? = nil) -> URL? {
    let target = sanitizedPhone(recipient) ?? sanitizedEmail(recipient)
    guard let target else { return nil }
    var components = URLComponents()
    components.scheme = "sms"
    components.path = target
    if let body, !body.isEmpty {
      components.queryItems = [URLQueryItem(name: "body", value: body)]
    }
    return components.url
  }

  static func facetime(_ raw: String) -> URL? {
    guard let target = sanitizedPhone(raw) ?? sanitizedEmail(raw) else { return nil }
    return URL(string: "facetime:\(target)")
  }

  static func sanitizedEmail(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }),
      let at = trimmed.firstIndex(of: "@"),
      at > trimmed.startIndex,
      trimmed[trimmed.index(after: at)...].contains(".")
    else { return nil }
    return trimmed
  }

  static func mailto(recipients: [String], subject: String? = nil, body: String? = nil) -> URL? {
    let valid = recipients.compactMap(sanitizedEmail)
    guard !valid.isEmpty else { return nil }
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = valid.joined(separator: ",")
    var items: [URLQueryItem] = []
    if let subject, !subject.isEmpty { items.append(URLQueryItem(name: "subject", value: subject)) }
    if let body, !body.isEmpty { items.append(URLQueryItem(name: "body", value: body)) }
    if !items.isEmpty { components.queryItems = items }
    return components.url
  }

  /// Validates an external website URL as strictly `http` or `https` with a non-empty host.
  static func website(_ raw: String?) -> URL? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
      let url = URL(string: raw),
      let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      let host = url.host, !host.isEmpty
    else { return nil }
    return url
  }

  // MARK: - Portable RFC exports (.ics / .vcf)

  static func icsString(for event: CalendarEventCard) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    let nowStamp = formatter.string(from: Date())
    let startStamp = formatter.string(from: event.startDate)
    let endStamp = formatter.string(from: event.endDate)
    var lines = [
      "BEGIN:VCALENDAR",
      "VERSION:2.0",
      "PRODID:-//Agello//On-Device Assistant//EN",
      "BEGIN:VEVENT",
      "UID:\(event.eventIdentifier ?? UUID().uuidString)@agello.local",
      "DTSTAMP:\(nowStamp)",
      "DTSTART:\(startStamp)",
      "DTEND:\(endStamp)",
      "SUMMARY:\(escapeICSText(event.title))",
    ]
    if let location = event.location, !location.isEmpty {
      lines.append("LOCATION:\(escapeICSText(location))")
    }
    lines.append("END:VEVENT")
    lines.append("END:VCALENDAR")
    return lines.joined(separator: "\r\n") + "\r\n"
  }

  static func vCardString(for contact: ContactCard) -> String {
    var lines = [
      "BEGIN:VCARD",
      "VERSION:3.0",
      "FN:\(escapeICSText(contact.fullName))",
    ]
    if let org = contact.organization, !org.isEmpty {
      lines.append("ORG:\(escapeICSText(org))")
    }
    for phone in contact.phones {
      lines.append("TEL;TYPE=CELL:\(escapeICSText(phone))")
    }
    for email in contact.emails {
      lines.append("EMAIL;TYPE=INTERNET:\(escapeICSText(email))")
    }
    if let address = contact.postalAddress, !address.isEmpty {
      lines.append("ADR;TYPE=HOME:;;\(escapeICSText(address));;;;")
    }
    lines.append("END:VCARD")
    return lines.joined(separator: "\r\n") + "\r\n"
  }

  private static func escapeICSText(_ raw: String) -> String {
    raw
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\r\n", with: "\\n")
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: ";", with: "\\;")
      .replacingOccurrences(of: ",", with: "\\,")
  }
}
