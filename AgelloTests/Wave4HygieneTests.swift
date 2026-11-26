import Foundation
import XCTest

@testable import Agello

/// Cross-platform unit tests for Wave 4 model and filesystem hygiene contracts:
/// `ActionCards.merge` deduplication keys (`areaLabel`, `subject`), `Identifiable` uniqueness and
/// legacy `Codable` backwards-compatibility across Action Card sub-items,
/// `ToolConfirmationRequest.Parameter` ID uniqueness, and non-recursive `FolderBookmarks` scanning.
final class Wave4HygieneTests: XCTestCase {
  // MARK: - ActionCards.merge deduplication

  func testPlacesMergeKeepsDistinctAreaLabelsAndDeduplicatesIdentical() {
    let downtown = ActionCardRecord(
      payload: .places(
        PlacesCard(
          query: "coffee", areaLabel: "Downtown",
          places: [.init(name: "Cafe A", latitude: 45.501, longitude: -73.567)])))
    let airport = ActionCardRecord(
      payload: .places(
        PlacesCard(
          query: "coffee", areaLabel: "Airport",
          places: [.init(name: "Cafe A", latitude: 45.470, longitude: -73.740)])))

    let distinct = ActionCards.merge([downtown], [airport])
    XCTAssertEqual(distinct.count, 2, "Distinct non-empty areaLabels must stay distinct")

    let downtownUpdated = ActionCardRecord(
      payload: .places(
        PlacesCard(
          query: "coffee", areaLabel: " downtown ",
          places: [.init(name: "Cafe A", latitude: 45.501, longitude: -73.567, distanceMeters: 150)])))
    let deduped = ActionCards.merge([downtown], [downtownUpdated])
    XCTAssertEqual(deduped.count, 1, "Same query, areaLabel, and top place must deduplicate")
    if case .places(let card) = deduped.first?.payload {
      XCTAssertEqual(card.places.first?.distanceMeters, 150, "Later identical card should win")
    } else {
      XCTFail("Expected places card")
    }

    // Nil/blank areaLabel followed by enriched non-empty areaLabel upgrades in place.
    let unlabelled = ActionCardRecord(
      payload: .places(
        PlacesCard(
          query: "coffee", areaLabel: nil,
          places: [.init(name: "Cafe A", latitude: 45.501, longitude: -73.567)])))
    let upgraded = ActionCards.merge([unlabelled], [downtown])
    XCTAssertEqual(upgraded.count, 1)
    if case .places(let card) = upgraded.first?.payload {
      XCTAssertEqual(card.areaLabel, "Downtown")
    } else {
      XCTFail("Expected upgraded places card")
    }
  }

  func testMessageDraftMergeKeepsDistinctSubjectsAndDeduplicatesIdentical() {
    let sharedBody = "Please see the attached quarterly review notes for tomorrow's meeting."
    let first = ActionCardRecord(
      payload: .messageDraft(
        MessageDraftCard(
          channel: .email, recipients: ["alice@example.com"], subject: "Q1 Review",
          body: sharedBody, unverifiedRecipients: [])))
    let second = ActionCardRecord(
      payload: .messageDraft(
        MessageDraftCard(
          channel: .email, recipients: ["alice@example.com"], subject: "Q2 Roadmap",
          body: sharedBody, unverifiedRecipients: [])))

    let distinct = ActionCards.merge([first], [second])
    XCTAssertEqual(distinct.count, 2, "Message drafts with different subjects must stay distinct")

    let duplicate = ActionCardRecord(
      payload: .messageDraft(
        MessageDraftCard(
          channel: .email, recipients: ["ALICE@example.com"], subject: " q1 review ",
          body: "\(sharedBody) Updated.", unverifiedRecipients: [])))
    let deduped = ActionCards.merge([first], [duplicate])
    XCTAssertEqual(deduped.count, 1, "Identical channel, recipients, subject, and body prefix must deduplicate")
    if case .messageDraft(let draft) = deduped.first?.payload {
      XCTAssertTrue(draft.body.contains("Updated."), "Later identical draft should replace earlier")
    } else {
      XCTFail("Expected messageDraft card")
    }
  }

  // MARK: - ActionCards Identifiable uniqueness & legacy Codable compatibility

  func testActionCardSubItemsGenerateUniqueIDsForDuplicates() {
    let now = Date(timeIntervalSince1970: 1_795_564_800)

    let place1 = PlacesCard.PlaceItem(name: "Esso", latitude: 45.5017, longitude: -73.5673)
    let place2 = PlacesCard.PlaceItem(name: "Esso", latitude: 45.5017, longitude: -73.5673)
    XCTAssertNotEqual(place1.id, place2.id, "Duplicate PlaceItems must have unique IDs")

    let hour1 = WeatherCard.HourItem(date: now, temperature: "18°C", symbolName: "sun.max", precipitationPercent: 0)
    let hour2 = WeatherCard.HourItem(date: now, temperature: "18°C", symbolName: "sun.max", precipitationPercent: 0)
    XCTAssertNotEqual(hour1.id, hour2.id, "Duplicate HourItems must have unique IDs")

    let day1 = WeatherCard.DayItem(
      date: now, label: "Mon", high: "20°C", low: "10°C", symbolName: "sun.max", precipitationPercent: 10)
    let day2 = WeatherCard.DayItem(
      date: now, label: "Mon", high: "20°C", low: "10°C", symbolName: "sun.max", precipitationPercent: 10)
    XCTAssertNotEqual(day1.id, day2.id, "Duplicate DayItems must have unique IDs")

    let alert1 = WeatherCard.AlertItem(summary: "Wind Advisory", severity: "moderate", detailsURL: nil)
    let alert2 = WeatherCard.AlertItem(summary: "Wind Advisory", severity: "moderate", detailsURL: nil)
    XCTAssertNotEqual(alert1.id, alert2.id, "Duplicate AlertItems must have unique IDs")
  }

  func testLegacyActionCardJSONWithoutItemIDsDecodesAndRoundTrips() throws {
    let legacyJSON = """
      {
        "actionCards": [
          {
            "id": "00000000-0000-0000-0000-000000000010",
            "payload": {
              "kind": "places",
              "data": {
                "query": "cafe",
                "places": [
                  {"name": "Cafe", "latitude": 45.5, "longitude": -73.5},
                  {"name": "Cafe", "latitude": 45.5, "longitude": -73.5}
                ]
              }
            }
          },
          {
            "id": "00000000-0000-0000-0000-000000000011",
            "payload": {
              "kind": "weather",
              "data": {
                "locationName": "Montréal",
                "temperature": "18°C",
                "condition": "Clear",
                "conditionSymbol": "sun.max",
                "hourly": [
                  {"date": 700000000, "temperature": "18°C", "symbolName": "sun.max", "precipitationPercent": 0},
                  {"date": 700000000, "temperature": "18°C", "symbolName": "sun.max", "precipitationPercent": 0}
                ],
                "daily": [
                  {"date": 700000000, "label": "Mon", "high": "20°C", "low": "10°C", "symbolName": "sun.max", "precipitationPercent": 0},
                  {"date": 700000000, "label": "Mon", "high": "20°C", "low": "10°C", "symbolName": "sun.max", "precipitationPercent": 0}
                ],
                "alerts": [
                  {"summary": "Advisory", "severity": "minor"},
                  {"summary": "Advisory", "severity": "minor"}
                ]
              }
            }
          },
          {
            "id": "00000000-0000-0000-0000-000000000012",
            "payload": {
              "kind": "weather",
              "data": {
                "locationName": "Minimal",
                "temperature": "10°C",
                "condition": "Cloudy",
                "conditionSymbol": "cloud"
              }
            }
          }
        ]
      }
      """

    let decoded = try JSONDecoder().decode(MessageParts.self, from: Data(legacyJSON.utf8))
    XCTAssertEqual(decoded.actionCards.count, 3)

    if case .places(let placesCard) = decoded.actionCards[0].payload {
      XCTAssertEqual(placesCard.places.count, 2)
      XCTAssertNotEqual(placesCard.places[0].id, placesCard.places[1].id)
    } else {
      XCTFail("Expected places card")
    }

    if case .weather(let weatherCard) = decoded.actionCards[1].payload {
      XCTAssertEqual(weatherCard.hourly.count, 2)
      XCTAssertNotEqual(weatherCard.hourly[0].id, weatherCard.hourly[1].id)
      XCTAssertEqual(weatherCard.daily.count, 2)
      XCTAssertNotEqual(weatherCard.daily[0].id, weatherCard.daily[1].id)
      XCTAssertEqual(weatherCard.alerts.count, 2)
      XCTAssertNotEqual(weatherCard.alerts[0].id, weatherCard.alerts[1].id)
    } else {
      XCTFail("Expected weather card")
    }

    if case .weather(let minimal) = decoded.actionCards[2].payload {
      XCTAssertTrue(minimal.hourly.isEmpty)
      XCTAssertTrue(minimal.daily.isEmpty)
      XCTAssertTrue(minimal.alerts.isEmpty)
    } else {
      XCTFail("Expected minimal weather card")
    }

    // Re-encoding and decoding preserves generated IDs identically.
    let reencoded = try JSONEncoder().encode(decoded)
    let roundTripped = try JSONDecoder().decode(MessageParts.self, from: reencoded)
    XCTAssertEqual(roundTripped, decoded)
  }

  // MARK: - ToolConfirmationRequest.Parameter uniqueness

  func testToolConfirmationParametersProduceUniqueIDsForDuplicateLabels() {
    let first = ToolConfirmationRequest.Parameter(name: "recipient", value: "alice@example.com")
    let second = ToolConfirmationRequest.Parameter(name: "recipient", value: "alice@example.com")
    let third = ToolConfirmationRequest.Parameter(name: "recipient", value: "bob@example.com")

    let ids = Set([first.id, second.id, third.id])
    XCTAssertEqual(ids.count, 3, "Duplicate parameter labels must still produce unique Identifiable IDs")
  }

  // MARK: - FolderBookmarks non-recursive scanning & cancellation

  func testFolderBookmarksCollectSupportedFilesIsNonRecursiveAndHonorsCancellation() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("Wave4Hygiene-\(UUID().uuidString)", isDirectory: true)
    let nested = root.appendingPathComponent("Nested", isDirectory: true)
    let deep = nested.appendingPathComponent("Deep", isDirectory: true)
    try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try "Top note".write(to: root.appendingPathComponent("alpha.md"), atomically: true, encoding: .utf8)
    try "a,b\n1,2".write(to: root.appendingPathComponent("beta.csv"), atomically: true, encoding: .utf8)
    try Data([0x89, 0x50]).write(to: root.appendingPathComponent("ignored.png"))
    try "Subdir note".write(to: nested.appendingPathComponent("nested.md"), atomically: true, encoding: .utf8)
    try "Deep note".write(to: deep.appendingPathComponent("buried.txt"), atomically: true, encoding: .utf8)

    let found = FolderBookmarks.collectSupportedFiles(in: root)
    XCTAssertEqual(
      found.map(\.lastPathComponent), ["alpha.md", "beta.csv"],
      "collectSupportedFiles must scan top-level supported files only without descending into subdirectories")

    let cancelledFound = await Task<[URL], Never> {
      withUnsafeCurrentTask { $0?.cancel() }
      return FolderBookmarks.collectSupportedFiles(in: root)
    }.value
    XCTAssertTrue(cancelledFound.isEmpty, "collectSupportedFiles must stop early when the current Task is cancelled")
  }
}
