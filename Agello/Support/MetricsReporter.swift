import CoreTransferable
import Foundation
import MetricKit
import OSLog
import UniformTypeIdentifiers

/// MetricKit's metrics and diagnostics (crashes, hangs, CPU/disk/memory exceptions, GPU/CPU time,
/// peak memory), kept on this iPhone (`Application Support/Diagnostics`, newest ``kept``) for the
/// user to share from Settings → Help. Nothing is sent anywhere.
final class MetricsReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
  static let shared = MetricsReporter()
  static let kept = 30

  /// Aggregated view over saved MetricKit payloads (both classic `MX*Payload` and iOS 27
  /// `MetricReport` / `DiagnosticReport` JSON). Pure & unit-tested.
  struct TelemetrySummary: Equatable, Sendable {
    var reportCount = 0
    var metricReportCount = 0
    var diagnosticReportCount = 0
    var memoryExceptionCount = 0
    var crashCount = 0
    var hangCount = 0
    var cpuExceptionCount = 0
    var diskWriteExceptionCount = 0
    var peakMemoryMB: Double?
    var gpuTimeSeconds: Double = 0
    var cpuTimeSeconds: Double = 0

    var formattedLines: [String] {
      var lines = [
        "Reports: \(reportCount) (\(metricReportCount) metrics, \(diagnosticReportCount) diagnostics)",
        "Diagnostics: \(memoryExceptionCount) memory exceptions, \(crashCount) crashes, \(hangCount) hangs, \(cpuExceptionCount) CPU, \(diskWriteExceptionCount) disk",
      ]
      if let peakMemoryMB {
        lines.append(String(format: "MetricKit peak memory: %.1f MB", peakMemoryMB))
      }
      if gpuTimeSeconds > 0 || cpuTimeSeconds > 0 {
        lines.append(
          String(format: "Cumulative compute: GPU %.1f s · CPU %.1f s", gpuTimeSeconds, cpuTimeSeconds))
      }
      return lines
    }
  }

  func start() {
    // Agello targets iOS 27.0+: subscribe exclusively to the Swift `MetricManager` async streams
    // (which include `.memoryException` diagnostics and structured `MetricReport`s) rather than
    // double-subscribing to classic `MXMetricManager`.
    MetricKitStream.shared.start()
  }

  func didReceive(_ payloads: [MXMetricPayload]) {
    for payload in payloads { Self.save(payload.jsonRepresentation(), kind: "metrics") }
  }

  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    for payload in payloads { Self.save(payload.jsonRepresentation(), kind: "diagnostics") }
  }

  static func directory() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let folder = base.appendingPathComponent("Diagnostics", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }

  /// Write a report and keep only the newest ``kept``. Appends a unique suffix so multi-report
  /// bursts arriving within the same second never clobber earlier files.
  static func save(_ data: Data, kind: String, in folder: URL? = nil, now: Date = .now) {
    guard let folder = folder ?? (try? directory()) else { return }
    let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
    let suffix = String(UUID().uuidString.prefix(8))
    try? data.write(
      to: folder.appendingPathComponent("\(stamp)-\(suffix)-\(kind).json"), options: .atomic)
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
      .filter { $0.hasSuffix(".json") }
      .sorted(by: >)
    for name in names.dropFirst(kept) {
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
  }

  /// Summarize all saved MetricKit JSON files in `folder` (defaults to `directory()`).
  static func summarize(in folder: URL? = nil) -> TelemetrySummary {
    guard let folder = folder ?? (try? directory()) else { return TelemetrySummary() }
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
      .filter { $0.hasSuffix(".json") }
      .sorted()
    let payloads: [(String, Data)] = names.compactMap { name in
      guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
      return (name, data)
    }
    return summarize(payloads: payloads)
  }

  /// Summarize all saved MetricKit JSON files off the main actor.
  static func summarizeAsync(in folder: URL? = nil) async -> TelemetrySummary {
    await Task.detached(priority: .utility) {
      Self.summarize(in: folder)
    }.value
  }

  /// Pure summarizer over raw MetricKit JSON payloads (classic and iOS 27 formats).
  static func summarize(payloads: [(name: String, data: Data)]) -> TelemetrySummary {
    var summary = TelemetrySummary()
    for (name, data) in payloads {
      summary.reportCount += 1
      guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        continue
      }
      let isDiagnostic =
        name.contains("diagnostics")
        || json["result"] != nil
        || json["crashDiagnostics"] != nil
        || json["memoryExceptionDiagnostics"] != nil
        || json["hangDiagnostics"] != nil
        || json["cpuExceptionDiagnostics"] != nil
        || json["diskWriteExceptionDiagnostics"] != nil
        || json["memoryExceptionDiagnostic"] != nil
        || json["crashDiagnostic"] != nil
        || json["hangDiagnostic"] != nil
        || json["cpuExceptionDiagnostic"] != nil
        || json["diskWriteExceptionDiagnostic"] != nil
        || json["appLaunchDiagnostic"] != nil
      if isDiagnostic {
        summary.diagnosticReportCount += 1
        accumulateDiagnostic(json, into: &summary)
      } else {
        summary.metricReportCount += 1
        accumulateMetrics(json, into: &summary)
      }
    }
    return summary
  }

  private static func accumulateDiagnostic(_ json: [String: Any], into summary: inout TelemetrySummary) {
    // Classic MXDiagnosticPayload arrays.
    summary.crashCount += (json["crashDiagnostics"] as? [Any])?.count ?? 0
    summary.hangCount += (json["hangDiagnostics"] as? [Any])?.count ?? 0
    summary.cpuExceptionCount += (json["cpuExceptionDiagnostics"] as? [Any])?.count ?? 0
    summary.diskWriteExceptionCount += (json["diskWriteExceptionDiagnostics"] as? [Any])?.count ?? 0
    summary.memoryExceptionCount += (json["memoryExceptionDiagnostics"] as? [Any])?.count ?? 0

    // iOS 27 Swift DiagnosticReport flattens `DiagnosticResult` directly at the root as `*Diagnostic`.
    if json["memoryExceptionDiagnostic"] != nil { summary.memoryExceptionCount += 1 }
    if json["crashDiagnostic"] != nil { summary.crashCount += 1 }
    if json["hangDiagnostic"] != nil { summary.hangCount += 1 }
    if json["cpuExceptionDiagnostic"] != nil { summary.cpuExceptionCount += 1 }
    if json["diskWriteExceptionDiagnostic"] != nil { summary.diskWriteExceptionCount += 1 }

    // Also tolerate legacy nested `result` envelope if present.
    if let result = json["result"] as? [String: Any] {
      if result["memoryException"] != nil || result["memoryExceptionDiagnostic"] != nil {
        summary.memoryExceptionCount += 1
      }
      if result["crash"] != nil || result["crashDiagnostic"] != nil { summary.crashCount += 1 }
      if result["hang"] != nil || result["hangDiagnostic"] != nil { summary.hangCount += 1 }
      if result["cpuException"] != nil || result["cpuExceptionDiagnostic"] != nil {
        summary.cpuExceptionCount += 1
      }
      if result["diskWriteException"] != nil || result["diskWriteExceptionDiagnostic"] != nil {
        summary.diskWriteExceptionCount += 1
      }
    }
  }

  private static func accumulateMetrics(_ json: [String: Any], into summary: inout TelemetrySummary) {
    // Classic MXMetricPayload dictionaries.
    if let memory = json["memoryMetrics"] as? [String: Any],
      let peakMB = parseMegabytes(memory["peakMemoryUsage"])
    {
      summary.peakMemoryMB = max(summary.peakMemoryMB ?? 0, peakMB)
    }
    if let gpu = json["gpuMetrics"] as? [String: Any],
      let seconds = parseSeconds(gpu["cumulativeGPUTime"])
    {
      summary.gpuTimeSeconds += seconds
    }
    if let cpu = json["cpuMetrics"] as? [String: Any],
      let seconds = parseSeconds(cpu["cumulativeCPUTime"])
    {
      summary.cpuTimeSeconds += seconds
    }

    // iOS 27 Swift MetricReport: prefer the full-day interval entry (`states: []`) so state
    // breakdowns never double-count the same day's cumulative GPU/CPU time.
    let intervalEntries = (json["intervalEntries"] as? [[String: Any]]) ?? []
    let fullDayEntries = intervalEntries.filter { entry in
      (entry["states"] as? [Any])?.isEmpty ?? true
    }
    let entries: [[String: Any]]
    if !fullDayEntries.isEmpty {
      entries = fullDayEntries
    } else if !intervalEntries.isEmpty {
      entries = intervalEntries
    } else {
      entries = (json["stateEntries"] as? [[String: Any]]) ?? []
    }
    for entry in entries {
      guard let values = entry["values"] as? [[String: Any]] else { continue }
      for item in values {
        if let peakObj = (item["peakMemoryMetric"] ?? item["peakMemory"]) as? [String: Any],
          let peakMB = parseMegabytes(peakObj["value"] ?? peakObj["_0"])
        {
          summary.peakMemoryMB = max(summary.peakMemoryMB ?? 0, peakMB)
        }
        if let gpuObj = (item["gpuTimeMetric"] ?? item["gpuTime"]) as? [String: Any],
          let seconds = parseSeconds(gpuObj["value"] ?? gpuObj["_0"])
        {
          summary.gpuTimeSeconds += seconds
        }
        if let cpuObj = (item["cpuTimeMetric"] ?? item["cpuTime"]) as? [String: Any],
          let seconds = parseSeconds(cpuObj["value"] ?? cpuObj["_0"])
        {
          summary.cpuTimeSeconds += seconds
        }
      }
    }
  }

  static func parseMegabytes(_ raw: Any?) -> Double? {
    if let dict = raw as? [String: Any] {
      if let nested = dict["value"] as? [String: Any] { return parseMegabytes(nested) }
      guard let number = numericValue(dict["value"]) else { return nil }
      // iOS 27 MetricKit encodes Measurement.unit as a plain String (e.g. "MB"); also accept nested symbol.
      let symbol =
        (dict["unit"] as? String)
        ?? (dict["unit"] as? [String: Any])?["symbol"] as? String
        ?? "B"
      return convertStorageToMB(number, unit: symbol)
    }
    if let text = raw as? String {
      let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
      guard let first = parts.first, let number = Double(first) else { return nil }
      let unit = parts.count > 1 ? String(parts[1]) : "B"
      return convertStorageToMB(number, unit: unit)
    }
    if let number = numericValue(raw) { return number / 1e6 }
    return nil
  }

  static func parseSeconds(_ raw: Any?) -> Double? {
    if let dict = raw as? [String: Any] {
      if let nested = dict["value"] as? [String: Any] { return parseSeconds(nested) }
      guard let number = numericValue(dict["value"]) else { return nil }
      let symbol =
        (dict["unit"] as? String)
        ?? (dict["unit"] as? [String: Any])?["symbol"] as? String
        ?? "s"
      return convertDurationToSeconds(number, unit: symbol)
    }
    if let text = raw as? String {
      let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
      guard let first = parts.first, let number = Double(first) else { return nil }
      let unit = parts.count > 1 ? String(parts[1]) : "s"
      return convertDurationToSeconds(number, unit: unit)
    }
    return numericValue(raw)
  }

  private static func numericValue(_ raw: Any?) -> Double? {
    if let d = raw as? Double { return d }
    if let i = raw as? Int { return Double(i) }
    if let n = raw as? NSNumber { return n.doubleValue }
    return nil
  }

  private static func convertStorageToMB(_ value: Double, unit: String) -> Double {
    switch unit.lowercased() {
    case "gb": value * 1_000
    case "gib": value * 1_024
    case "mb": value
    case "mib": value * 1.048_576
    case "kb", "kib": value / 1_000
    case "b", "bytes": value / 1_000_000
    default: value / 1_000_000
    }
  }

  private static func convertDurationToSeconds(_ value: Double, unit: String) -> Double {
    switch unit.lowercased() {
    case "hr", "h", "hours": value * 3_600
    case "min", "m", "minutes": value * 60
    case "ms", "msec": value / 1_000
    case "us", "µs", "usec": value / 1_000_000
    case "ns": value / 1_000_000_000
    default: value
    }
  }

  /// Formatted live memory ledger & thermal snapshot for diagnostics exports.
  static func liveTelemetrySummary(snapshot: MemoryProbe.Snapshot = MemoryProbe.capture()) -> String {
    let lines = [
      String(
        format: "Footprint: %.2f GB (peak %.2f GB · available %.2f GB)",
        Double(snapshot.footprintBytes) / 1e9,
        Double(snapshot.peakFootprintBytes) / 1e9,
        Double(snapshot.availableBytes) / 1e9),
      String(
        format: "Ledgers: GPU %.2f GB · ANE %.2f GB · compressed %.2f GB",
        Double(snapshot.graphicsBytes) / 1e9,
        Double(snapshot.neuralBytes) / 1e9,
        Double(snapshot.compressedBytes) / 1e9),
      "Thermal state: \(MemoryProbe.thermalStateLabel(snapshot.thermalState))",
    ]
    return lines.joined(separator: "\n")
  }

  /// One text file for sharing: the app and device, live memory/ANE/GPU/thermal snapshot,
  /// MetricKit telemetry summary, every saved report, and the app's log of the last hour.
  static func exportFile(now: Date = .now) throws -> URL {
    var text = "Agello diagnostics, \(now.formatted(date: .abbreviated, time: .standard))\n"
    let info = Bundle.main.infoDictionary
    text += "Version \(info?["CFBundleShortVersionString"] as? String ?? "?")"
    text += " (\(info?["CFBundleVersion"] as? String ?? "?")), \(DeviceProfile.current.summary)\n\n"
    text += "== Live memory & thermal ==\n" + liveTelemetrySummary() + "\n\n"
    let folder = try directory()
    let summary = summarize(in: folder)
    text += "== Telemetry summary ==\n" + summary.formattedLines.joined(separator: "\n") + "\n\n"
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
      .filter { $0.hasSuffix(".json") }
      .sorted()
    text += "== MetricKit reports (\(names.count)) ==\n"
    for name in names {
      let body = (try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)) ?? ""
      text += "\n-- \(name)\n\(body)\n"
    }
    text += "\n== Log, last hour ==\n" + recentLog(since: now.addingTimeInterval(-3_600))
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("Agello-diagnostics.txt")
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  /// This process's log lines from Agello's subsystem since `date`.
  static func recentLog(since date: Date) -> String {
    guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
      let entries = try? store.getEntries(
        at: store.position(date: date),
        matching: NSPredicate(format: "subsystem == %@", "com.patricedery.agello"))
    else { return "(unavailable)\n" }
    return entries.compactMap { $0 as? OSLogEntryLog }
      .map { "\($0.date.formatted(date: .omitted, time: .standard)) [\($0.category)] \($0.composedMessage)" }
      .joined(separator: "\n") + "\n"
  }
}

/// The diagnostics file, made when the user shares it.
struct DiagnosticsExport: Transferable {
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(exportedContentType: .plainText) { _ in
      SentTransferredFile(try MetricsReporter.exportFile())
    }
  }
}
