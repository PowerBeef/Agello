import CoreTransferable
import Foundation
import MetricKit
import OSLog
import UIKit
import UniformTypeIdentifiers

/// MetricKit's metrics and diagnostics (crashes, hangs, CPU and disk-write exceptions), kept on
/// this iPhone (Application Support/Diagnostics, the newest ``kept``) for the user to share from
/// Settings → Advanced. Nothing is sent anywhere.
final class MetricsReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
  static let shared = MetricsReporter()
  static let kept = 30

  func start() {
    MXMetricManager.shared.add(self)
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

  /// Write a report and keep only the newest ``kept``.
  static func save(_ data: Data, kind: String, in folder: URL? = nil, now: Date = .now) {
    guard let folder = folder ?? (try? directory()) else { return }
    let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
    try? data.write(to: folder.appendingPathComponent("\(stamp)-\(kind).json"), options: .atomic)
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
      .filter { $0.hasSuffix(".json") }
      .sorted(by: >)
    for name in names.dropFirst(kept) {
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
  }

  /// One text file for sharing: the app and device, every saved report, and the app's log of
  /// the last hour.
  static func exportFile(now: Date = .now) throws -> URL {
    var text = "Agello diagnostics, \(now.formatted(date: .abbreviated, time: .standard))\n"
    let info = Bundle.main.infoDictionary
    text += "Version \(info?["CFBundleShortVersionString"] as? String ?? "?")"
    text += " (\(info?["CFBundleVersion"] as? String ?? "?")), \(DeviceProfile.current.summary)\n\n"
    let folder = try directory()
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
