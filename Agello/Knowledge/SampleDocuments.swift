import Foundation

/// Sample documents made in code, for what can't pick a file by hand: the UI tests (the system
/// file picker can't be driven) and the bench, on the iPhone and from the Mac command line.
enum SampleDocuments {
  /// A short note (`--uitest-sample-file`).
  static let tripNotes = ExtractedDocument(
    name: "trip-notes.md", kind: .text, byteCount: 120,
    pages: [
      "Hiking trip notes.\n\nThe trailhead parking opens at 6 am. Bring a tent, a stove, "
        + "and three litres of water per person."
    ])

  /// A long report (`--uitest-sample-report`): 60 pages, about 8K tokens, so "Summarize this"
  /// read it section by section when chat's window was 8K. Section 23 is about water quality,
  /// inspected by district 4.
  static var coastalReport: ExtractedDocument {
    let topics = [
      "harbour maintenance", "coastal erosion", "lighthouse operations", "fisheries",
      "visitor services", "storm preparedness", "habitat restoration", "water quality",
    ]
    let pages = (1...60).map { page -> String in
      let topic = topics[page % topics.count]
      return [
        "Section \(page): \(topic.capitalized).",
        "This section reviews \(topic) during the reporting period. Teams in district "
          + "\(page % 5 + 1) completed scheduled inspections, logged their findings, and "
          + "filed follow-up requests where repairs were needed.",
        "Most indicators for \(topic) stayed within normal ranges. Seasonal variation was "
          + "observed, and staff recommend continuing the current monitoring programme.",
      ].joined(separator: "\n\n")
    }
    return ExtractedDocument(name: "coastal-report.pdf", kind: .pdf, byteCount: 200_000, pages: pages)
  }

  /// The sample a launch argument names, if any.
  static func named(in arguments: [String]) -> ExtractedDocument? {
    if arguments.contains("--uitest-sample-file") { return tripNotes }
    if arguments.contains("--uitest-sample-report") { return coastalReport }
    return nil
  }
}
