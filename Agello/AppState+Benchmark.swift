import Foundation
import LiteRTLM
import SwiftData

/// The developer benchmark (Settings → five taps on the version line). Part of ``AppState``, split by area (2026-11-16).
extension AppState {
  // MARK: - Benchmark

  /// Run a text benchmark (1024 prefill / 256 decode, without MTP) on the
  /// active model. Unloads the chat engine first so the benchmark has full
  /// memory; the engine reloads lazily on the next chat.
  func runBenchmark() async {
    await serialized { await self.runBenchmarkLocked() }
  }

  func runBenchmarkLocked() async {
    guard !isBenchmarking, !isGenerating, !isPreparing, !isTranscribing, isInForeground, GPUGate.isOpen
    else { return }
    let spec = store.activeSpec
    guard store.isDownloaded(spec), let url = store.localURL(for: spec) else {
      generationError = "\(spec.displayName) is not downloaded."
      return
    }
    isBenchmarking = true
    await unloadEngine()
    guard isInForeground, GPUGate.isOpen else {
      isBenchmarking = false
      engineState = .idle
      return
    }
    engineState = .loading(progress: "Benchmarking \(spec.displayName)…")
    let benchGuard = BackgroundTaskGuard.begin(name: "AgelloBenchmark")
    defer {
      benchGuard.end()
      isBenchmarking = false
      engineState = .idle
    }
    do {
      // A one-off 1,312-token engine: caching it would keep another 2.2 GB
      // copy of the weights (see EngineCache).
      let cacheDir = EngineCache.disabled
      // A new engine reads the global MTP flag, which still holds the last
      // chat load's value: measure without MTP every time (its drafts don't
      // fit synthetic tokens), then put the flag back.
      ExperimentalFlags.optIntoExperimentalAPIs()
      let chatMTP = ExperimentalFlags.enableSpeculativeDecoding
      ExperimentalFlags.enableSpeculativeDecoding = false
      defer { ExperimentalFlags.enableSpeculativeDecoding = chatMTP }
      // Extract Sendable scalars inside the task: BenchmarkInfo itself is not Sendable.
      let result = try await Task.detached(priority: .userInitiated) {
        () -> (prefill: Double, decode: Double, ttft: Double) in
        let info = try await LiteRTLM.benchmark(
          modelPath: url.path,
          backend: .gpu,
          prefillTokens: 1024,
          decodeTokens: 256,
          cacheDir: cacheDir
        )
        return (
          info.lastPrefillTokensPerSecond, info.lastDecodeTokensPerSecond,
          info.timeToFirstTokenInSecond)
      }.value
      benchmarkReport = BenchmarkReport(
        modelID: spec.id,
        backend: "GPU",
        prefillTokensPerSecond: result.prefill,
        decodeTokensPerSecond: result.decode,
        timeToFirstToken: result.ttft,
        date: Date()
      )
    } catch {
      generationError =
        "Benchmark failed: \((error as? ChatError)?.displayMessage ?? error.localizedDescription)"
    }
  }
}
