import XCTest

@testable import Agello

/// MetricKit reports are kept on the device, newest first, and the export holds them.
final class DiagnosticsTests: XCTestCase {
  func testReportsAreKeptUpToTheLimit() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Diagnostics-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    for day in 0..<(MetricsReporter.kept + 5) {
      MetricsReporter.save(
        Data("{\"day\":\(day)}".utf8), kind: "metrics", in: folder,
        now: start.addingTimeInterval(Double(day) * 86_400))
    }
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    XCTAssertEqual(names.count, MetricsReporter.kept)
    let oldest = try String(contentsOf: folder.appendingPathComponent(names[0]), encoding: .utf8)
    XCTAssertEqual(oldest, "{\"day\":5}", "The oldest reports go first")
  }

  func testExportHasAHeaderAndTheLog() throws {
    Log.lifecycle.info("diagnostics export test line")
    let text = try String(contentsOf: MetricsReporter.exportFile(), encoding: .utf8)
    XCTAssertTrue(text.hasPrefix("Agello diagnostics"))
    XCTAssertTrue(text.contains("== MetricKit reports"))
    XCTAssertTrue(text.contains("== Log, last hour =="))
  }
}
