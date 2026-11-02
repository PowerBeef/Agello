import Foundation

/// Result of an on-demand benchmark run (1024 prefill / 256 decode tokens,
/// matching Google's published methodology).
struct BenchmarkReport: Codable, Sendable, Equatable {
  var modelID: ModelID
  var backend: String
  var prefillTokensPerSecond: Double
  var decodeTokensPerSecond: Double
  var timeToFirstToken: Double
  var date: Date

  var summaryLine: String {
    String(
      format: "%.0f prefill · %.0f decode tok/s · TTFT %.1fs",
      prefillTokensPerSecond, decodeTokensPerSecond, timeToFirstToken)
  }
}
