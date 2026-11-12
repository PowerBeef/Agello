import CoreLocation

/// One location fix for "near me", asking permission (while in use) the first time. Nil when it's
/// refused or takes longer than `timeout`, so a pending prompt never holds a search.
enum CurrentLocation {
  static func fetch(timeout: Duration = .seconds(10)) async -> CLLocation? {
    let session = CLServiceSession(authorization: .whenInUse)
    defer { session.invalidate() }
    return await withTaskGroup(of: CLLocation?.self) { group in
      group.addTask {
        do {
          for try await update in CLLocationUpdate.liveUpdates() {
            if let location = update.location { return location }
            if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
              return nil
            }
          }
        } catch {}
        return nil
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  /// Words that mean "where I am" in a planner's query ("gas station near me").
  static func meansHere(_ place: String) -> Bool {
    let words: Set = ["me", "here", "my location", "moi", "ici"]
    return words.contains(place.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }
}
