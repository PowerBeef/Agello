import Foundation
import MetricKit
import Synchronization

/// Subscribes to iOS 27's Swift `MetricKit.MetricManager` async streams for `.memoryException`
/// diagnostics and structured `MetricReport`s (peak memory, GPU time, CPU time, Metal frame rate),
/// saving JSON snapshots alongside classic `MXMetricManager` payloads.
final class MetricKitStream: Sendable {
  static let shared = MetricKitStream()

  private struct State: Sendable {
    var started = false
    var diagnosticTask: Task<Void, Never>?
    var metricTask: Task<Void, Never>?
  }

  private let state = Mutex(State())

  func start() {
    let shouldStart = state.withLock { current -> Bool in
      guard !current.started else { return false }
      current.started = true
      return true
    }
    guard shouldStart else { return }

    let manager = MetricManager()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    let diagTask = Task.detached(priority: .utility) {
      for await report in manager.diagnosticReports {
        Self.log(report)
        if let data = try? encoder.encode(report) {
          MetricsReporter.save(data, kind: "diagnostics-v2")
        }
      }
    }
    let metricTask = Task.detached(priority: .utility) {
      for await report in manager.metricReports {
        if let data = try? encoder.encode(report) {
          MetricsReporter.save(data, kind: "metrics-v2")
        }
      }
    }
    state.withLock { current in
      current.diagnosticTask = diagTask
      current.metricTask = metricTask
    }
  }

  private static func log(_ report: DiagnosticReport) {
    switch report.result {
    case .memoryException(let diagnostic):
      Log.lifecycle.error(
        "metrickit: memoryException diagnostic (\(diagnostic.callStackTree.callStackThreads.count) threads)")
    case .crash:
      Log.lifecycle.error("metrickit: crash diagnostic received")
    case .hang:
      Log.lifecycle.warning("metrickit: hang diagnostic received")
    case .cpuException:
      Log.lifecycle.warning("metrickit: cpuException diagnostic received")
    case .diskWriteException:
      Log.lifecycle.warning("metrickit: diskWriteException diagnostic received")
    case .appLaunch:
      Log.lifecycle.info("metrickit: appLaunch diagnostic received")
    @unknown default:
      Log.lifecycle.info("metrickit: diagnostic received")
    }
  }
}
