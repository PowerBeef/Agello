import XCTest

@testable import Agello

extension ProbeScenarioTests {
  /// Probe 16: nothing stays after the engine is freed. Each step loads the
  /// app's engine, runs one kind of work through `AppState`, frees the engine,
  /// and records `MemoryProbe.breakdown()`. It found the "memory left between
  /// tests" (1.1-1.9 GB, 0.77 GB of it Metal, with Google's binary as with
  /// ours): the test host's own UI had warmed up a second engine, which
  /// `AgelloApp` no longer does while hosting tests. `PROBE_HOLD=<s>`
  /// (`TEST_RUNNER_PROBE_HOLD`) keeps the app alive at the end, for
  /// `footprint` and `vmmap` on the Mac.
  func test16_MemoryAfterUnload() async throws {
    _ = try await harness.ensureDownloaded(ModelCatalog.e4b)
    await appState.engine.unload()
    var rows: [[String: Any]] = []
    func row(_ label: String, _ ok: Bool? = nil) async {
      let unload = await harness.liveEngine?.lastUnload ?? ""
      var entry: [String: Any] = ["step": label, "memoryGB": MemoryProbe.breakdown(), "unload": unload]
      if let ok { entry["ok"] = ok }
      rows.append(entry)
      print("PROBE16 \(label): \(unload) \(MemoryProbe.breakdown())")
      harness.record("probe16_memory_after_unload", ["rows": rows], in: self)
    }
    func run(
      _ label: String, tokens: Int = 8_192, _ work: () async -> DeviceHarness.Exchange
    ) async {
      appState.options.maxNumTokensOverride = tokens
      await appState.applyCurrentOptions()
      let loaded = await appState.ensureEngineLoaded()
      XCTAssertTrue(loaded, "\(label): \(appState.engineState)")
      let exchange = await work()
      await appState.engine.unload()
      await row(label, exchange.accepted && !exchange.text.isEmpty && !exchange.text.hasPrefix(ChatTurn.errorPrefix))
      // No engine's Metal buffers remain (a fresh launch holds none).
      XCTAssertLessThan(MemoryProbe.breakdown()["graphics"] ?? 0, 0.1, "\(label): Metal memory left")
    }
    let summarize = "\n\nSummarize the text above in one sentence."

    await row("start")
    await run("text") { await harness.ask("Explain in about 150 words how tides work.", in: harness.newThread()) }
    await run("image") {
      await harness.ask(
        "What is the dominant color of this image? Answer with one word.", in: harness.newThread(),
        image: TestMedia.solidColorJPEG(.red))
    }
    await run("image again") {
      await harness.ask(
        "What is the dominant color of this image? Answer with one word.", in: harness.newThread(),
        image: TestMedia.solidColorJPEG(.blue))
    }
    let audio = try await TestMedia.spokenWAV("The quick brown fox jumps over the lazy dog.")
    defer { try? FileManager.default.removeItem(at: audio) }
    await row("speech synthesized")
    await run("audio") { await harness.ask("Transcribe this audio exactly.", in: harness.newThread(), audio: audio) }
    await run("long 8K") {
      await harness.ask(CalibrationScenarioTests.filler(bytes: 8_192) + summarize, in: harness.newThread())
    }
    await run("long 16K", tokens: 16_384) {
      await harness.ask(CalibrationScenarioTests.filler(bytes: 16_384) + summarize, in: harness.newThread())
    }
    await run("text again") { await harness.ask("Name three planets.", in: harness.newThread()) }

    if let hold = ProcessInfo.processInfo.environment["PROBE_HOLD"], let seconds = Double(hold) {
      print("PROBE16 holding \(seconds) s, pid \(ProcessInfo.processInfo.processIdentifier)")
      try await Task.sleep(for: .seconds(seconds))
    }
  }
}
