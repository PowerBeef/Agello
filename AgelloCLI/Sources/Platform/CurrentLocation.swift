import CoreLocation

/// The Mac command line has no user location (`CurrentLocation` on the iPhone asks for it): "near
/// me" searches report the location as unavailable.
enum CurrentLocation {
  static func fetch(timeout: Duration = .seconds(10)) async -> CLLocation? { nil }

  static func meansHere(_ place: String) -> Bool {
    let words: Set = ["me", "here", "my location", "moi", "ici"]
    return words.contains(place.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }
}
