import MetricKit
import XCTest

@testable import Agello

/// MetricKit reports are kept on the device, newest first, summarized cleanly across classic and
/// iOS 27 JSON formats, and live kernel memory peak / GPU / ANE deltas are included in exports.
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

  func testExportHasHeaderLiveTelemetrySummaryAndLog() throws {
    Log.lifecycle.info("diagnostics export test line")
    let text = try String(contentsOf: MetricsReporter.exportFile(), encoding: .utf8)
    XCTAssertTrue(text.hasPrefix("Agello diagnostics"))
    XCTAssertTrue(text.contains("== Live memory & thermal =="))
    XCTAssertTrue(text.contains("== Telemetry summary =="))
    XCTAssertTrue(text.contains("== MetricKit reports"))
    XCTAssertTrue(text.contains("== Log, last hour =="))
  }

  func testSummarizeClassicAndIOS27MetricKitPayloads() {
    let classicMetrics = """
      {
        "memoryMetrics": { "peakMemoryUsage": "3.45 GB" },
        "gpuMetrics": { "cumulativeGPUTime": "42.5 sec" },
        "cpuMetrics": { "cumulativeCPUTime": "12000 ms" }
      }
      """
    let ios27Diagnostic = """
      {
        "result": {
          "memoryException": {
            "callStackTree": { "callStackThreads": [], "callStackPerThread": true, "binaryInfo": {} }
          }
        }
      }
      """
    let ios27Metrics = """
      {
        "intervalEntries": [
          {
            "values": [
              { "peakMemory": { "value": { "value": 4120, "unit": { "symbol": "MB" } } } },
              { "gpuTime": { "value": { "value": 17.5, "unit": { "symbol": "s" } } } },
              { "cpuTime": { "value": { "value": 8.0, "unit": { "symbol": "s" } } } }
            ]
          }
        ]
      }
      """
    let classicDiagnostic = """
      {
        "crashDiagnostics": [{}],
        "hangDiagnostics": [{}, {}]
      }
      """
    let summary = MetricsReporter.summarize(payloads: [
      ("2026-11-22-metrics.json", Data(classicMetrics.utf8)),
      ("2026-11-22-diagnostics-v2.json", Data(ios27Diagnostic.utf8)),
      ("2026-11-22-metrics-v2.json", Data(ios27Metrics.utf8)),
      ("2026-11-22-diagnostics.json", Data(classicDiagnostic.utf8)),
    ])
    XCTAssertEqual(summary.reportCount, 4)
    XCTAssertEqual(summary.metricReportCount, 2)
    XCTAssertEqual(summary.diagnosticReportCount, 2)
    XCTAssertEqual(summary.memoryExceptionCount, 1)
    XCTAssertEqual(summary.crashCount, 1)
    XCTAssertEqual(summary.hangCount, 2)
    XCTAssertEqual(summary.peakMemoryMB ?? 0, 4120, accuracy: 0.1)
    XCTAssertEqual(summary.gpuTimeSeconds, 60.0, accuracy: 0.1)
    XCTAssertEqual(summary.cpuTimeSeconds, 20.0, accuracy: 0.1)
  }

  /// Verifies Apple's live iOS 27 MetricKit JSON encoding (flattened `*Diagnostic` root keys,
  /// `*Metric` keys, plain-string `unit`, full-day vs state deduplication, and same-second saves).
  func testSummarizeLiveIOS27MetricKitEncodingAndUniqueFilenames() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    // Round-trip a real MetricKit.MetricReport through Apple's Codable implementation.
    let liveMetricInput = """
      {
        "version": "2.0.0",
        "timeRange": { "begin": "2026-11-22T00:00:00Z", "end": "2026-11-23T00:00:00Z" },
        "intervalEntries": [
          {
            "states": [],
            "duration": { "unit": "s", "value": 86400 },
            "values": [
              { "cpuTimeMetric": { "value": { "unit": "ms", "value": 12000 } } },
              { "gpuTimeMetric": { "value": { "unit": "s", "value": 17.5 } } }
            ]
          }
        ],
        "stateEntries": {}
      }
      """
    let decodedReport = try decoder.decode(MetricReport.self, from: Data(liveMetricInput.utf8))
    let reencodedMetric = try encoder.encode(decodedReport)

    let iosPeakAndDiagMetrics = """
      {
        "intervalEntries": [
          {
            "states": [],
            "values": [
              { "peakMemoryMetric": { "value": { "unit": "MB", "value": 3450 } } }
            ]
          },
          {
            "states": [
              { "domain": "com.apple.test", "state": "active" }
            ],
            "values": [
              { "cpuTimeMetric": { "value": { "unit": "ms", "value": 9000 } } }
            ]
          }
        ],
        "stateEntries": [
          {
            "state": { "domain": "com.apple.test", "state": "active" },
            "values": [
              { "cpuTimeMetric": { "value": { "unit": "ms", "value": 9000 } } }
            ]
          }
        ]
      }
      """
    let ios27MemoryException = """
      {
        "memoryExceptionDiagnostic": { "callStackTree": {} },
        "version": "2.0.0"
      }
      """
    let ios27Crash = """
      {
        "crashDiagnostic": { "callStackTree": {} },
        "version": "2.0.0"
      }
      """
    let summary = MetricsReporter.summarize(payloads: [
      ("2026-11-22T12-00-00Z-aaaa-metrics-v2.json", reencodedMetric),
      ("2026-11-22T12-00-00Z-bbbb-metrics-v2.json", Data(iosPeakAndDiagMetrics.utf8)),
      ("2026-11-22T12-00-00Z-cccc-diagnostics-v2.json", Data(ios27MemoryException.utf8)),
      ("2026-11-22T12-00-00Z-dddd-diagnostics-v2.json", Data(ios27Crash.utf8)),
    ])
    XCTAssertEqual(summary.reportCount, 4)
    XCTAssertEqual(summary.metricReportCount, 2)
    XCTAssertEqual(summary.diagnosticReportCount, 2)
    XCTAssertEqual(summary.memoryExceptionCount, 1)
    XCTAssertEqual(summary.crashCount, 1)
    XCTAssertEqual(summary.peakMemoryMB ?? 0, 3450, accuracy: 0.1)
    XCTAssertEqual(summary.gpuTimeSeconds, 17.5, accuracy: 0.01)
    // Must not double-count `stateEntries` (12 s, not 21 s).
    XCTAssertEqual(summary.cpuTimeSeconds, 12.0, accuracy: 0.01)

    // Saving multiple reports in the same second must create distinct files.
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DiagSameSec-\(UUID())")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sameInstant = Date(timeIntervalSince1970: 1_800_000_000)
    for i in 0..<3 {
      MetricsReporter.save(Data("{\"i\":\(i)}".utf8), kind: "diagnostics-v2", in: folder, now: sameInstant)
    }
    let saved = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    XCTAssertEqual(saved.count, 3)
  }

  func testMemoryProbeSnapshotAndPeakDelta() {
    let base = MemoryProbe.Snapshot(
      footprintBytes: 1_000_000_000, peakFootprintBytes: 1_500_000_000,
      availableBytes: 5_000_000_000, graphicsBytes: 600_000_000, neuralBytes: 100_000_000,
      compressedBytes: 50_000_000, thermalState: 0, capturedAt: .now)
    let after = MemoryProbe.Snapshot(
      footprintBytes: 1_400_000_000, peakFootprintBytes: 2_100_000_000,
      availableBytes: 4_600_000_000, graphicsBytes: 900_000_000, neuralBytes: 180_000_000,
      compressedBytes: 60_000_000, thermalState: 1, capturedAt: .now)
    let delta = after.delta(from: base)
    XCTAssertEqual(delta.footprintDeltaBytes, 400_000_000)
    XCTAssertEqual(delta.peakDeltaMB, 600.0, accuracy: 0.01)
    XCTAssertEqual(delta.graphicsDeltaMB, 300.0, accuracy: 0.01)
    XCTAssertEqual(delta.neuralDeltaMB, 80.0, accuracy: 0.01)
    XCTAssertEqual(MemoryProbe.thermalStateLabel(0), "nominal")
    XCTAssertEqual(MemoryProbe.thermalStateLabel(1), "fair")

    let live = MemoryProbe.capture()
    XCTAssertGreaterThan(live.footprintBytes, 0)
    XCTAssertGreaterThanOrEqual(live.peakFootprintBytes, live.footprintBytes)
    XCTAssertNotNil(MemoryProbe.breakdown()["peak"])
  }
}
