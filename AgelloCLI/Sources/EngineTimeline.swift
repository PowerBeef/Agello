import Foundation
import Synchronization

/// What the engine did over a reply, second by second.
///
/// The runtime's telemetry gives totals for a turn, and its event trace only holds the last few
/// seconds of a long reply. Snapshots taken while the reply is written give the rest: each row
/// is the totals so far (tokens, decode steps, drafts kept, GPU and host time by kind, memory),
/// so the difference of two rows says what a stretch of the reply cost. `scripts/cli-timeline.py`
/// reads them.
final class EngineTimeline: Sendable {
  private final class Rows: Sendable {
    let all = Mutex<[[String: Double]]>([])
  }

  private let rows = Rows()
  private let sampler: Task<Void, Never>

  /// Totals kept from each snapshot: counters, then spans' total milliseconds.
  static let counters = [
    "tokens_decoded", "tokens_prefilled", "mtp_rounds", "mtp_drafted", "mtp_accepted", "runs_verify",
    "runs_drafter", "runs_decode", "command_buffers", "gpu_waits", "host_lock_copy_bytes",
    "host_unlock_copy_bytes", "embedding_lookups", "stream_chunks",
  ]
  static let spans = [
    "decode.step", "run.verify", "run.drafter", "run.decode", "gpu.verify", "gpu.drafter", "gpu.decode",
    "gpu.prefill", "gpu.wait.decode", "gpu.queue_delay", "host.lock_read", "host.unlock_write",
    "embedding_lookup", "sample", "detokenize", "stream_callback", "turn.prefill", "turn.decode",
  ]

  /// Starts sampling every `interval` seconds, off the main thread.
  init(interval: Double = 1) {
    let started = ContinuousClock.now
    let rows = self.rows
    sampler = Task.detached(priority: .utility) {
      while !Task.isCancelled {
        if let row = Self.row(since: started) { rows.all.withLock { $0.append(row) } }
        try? await Task.sleep(for: .seconds(interval))
      }
      if let row = Self.row(since: started) { rows.all.withLock { $0.append(row) } }
    }
  }

  /// Stops and returns the rows, the last one taken now.
  func finish() async -> [[String: Double]] {
    sampler.cancel()
    await sampler.value
    return rows.all.withLock { $0 }
  }

  private static func row(since started: ContinuousClock.Instant) -> [String: Double]? {
    guard let snapshot = EngineProbe.snapshot() else { return nil }
    var row: [String: Double] = ["seconds": (ContinuousClock.now - started) / .seconds(1)]
    let counters = snapshot["counters"] as? [String: Any] ?? [:]
    for name in Self.counters { row[name] = (counters[name] as? NSNumber)?.doubleValue ?? 0 }
    let spans = snapshot["spans"] as? [String: Any] ?? [:]
    for name in Self.spans {
      let span = spans[name] as? [String: Any]
      row[name + ".ms"] = (span?["total_ms"] as? NSNumber)?.doubleValue ?? 0
      row[name + ".n"] = (span?["count"] as? NSNumber)?.doubleValue ?? 0
    }
    let memory = snapshot["memory"] as? [String: Any] ?? [:]
    row["footprintMB"] = (memory["footprint_mb"] as? NSNumber)?.doubleValue ?? 0
    row["graphicsMB"] = (memory["graphics_footprint_mb"] as? NSNumber)?.doubleValue ?? 0
    row["thermal"] = Double(ProcessInfo.processInfo.thermalState.rawValue)
    return row
  }
}
