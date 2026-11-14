import XCTest

@testable import Agello

extension ProbeScenarioTests {
  /// Probe 25: the replay ceiling of a GPU-resident speculative round (PERFORMANCE.md, "The
  /// engine review, adopted", step 7). With `AGELLO_MTP_REPLAY=1` our runtime runs every round
  /// twice: the real round, then the same round with its four GPU runs committed back to back and
  /// one wait, no logits read and no picks (replies unchanged). Per reply, from the engine's
  /// telemetry: the real round's mean (`mtp.round`) against the replayed one's (`mtp.replay`), the
  /// ceiling as their ratio, decode speed and the thermal state. Replies run back to back, each in
  /// a new chat (short context), for `REPLAY_MINUTES`, so the ceiling shows cool and hot. The
  /// resident round is dropped if the ceiling is under about +8 % once the phone is hot.
  ///
  /// - `TEST_RUNNER_AGELLO_MTP_REPLAY=1`: the runtime's switch (read once, at the first round).
  /// - `TEST_RUNNER_REPLAY_MINUTES`: how long to keep replying (default 10).
  /// For the ceiling with the window filled, run probe 24 with the same switch.
  func test25_ReplayCeiling() async throws {
    let env = ProcessInfo.processInfo.environment
    guard env["AGELLO_MTP_REPLAY"] == "1" else { throw XCTSkip("Set TEST_RUNNER_AGELLO_MTP_REPLAY=1") }
    let minutes = Double(env["REPLAY_MINUTES"] ?? "") ?? 10
    try await requireLoadedModel()

    let tools = appState.enableTools
    let preset = appState.options.samplerPreset
    defer {
      appState.enableTools = tools
      appState.options.samplerPreset = preset
    }
    appState.enableTools = false
    appState.options.samplerPreset = .precise

    let topics = [
      "the history of lighthouses", "how bees make honey", "the first transatlantic telegraph cable",
      "why the sky is blue", "how bread rises", "the life of a glacier", "how tides work",
      "the invention of the printing press", "how a violin makes sound", "the migration of eels",
    ]
    let started = Date()
    var replies: [[String: Any]] = []
    var index = 0
    while Date().timeIntervalSince(started) < minutes * 60 {
      let topic = topics[index % topics.count]
      index += 1
      EngineTelemetry.reset()
      let exchange = await harness.ask("Write about 300 words on \(topic).", in: harness.newThread())
      let telemetry = EngineTelemetry.snapshot() ?? [:]
      let counters = telemetry["counters"] as? [String: Any] ?? [:]
      let spans = telemetry["spans"] as? [String: Any] ?? [:]
      func total(_ name: String) -> Double { (spans[name] as? [String: Any])?["total_ms"] as? Double ?? 0 }
      func count(_ name: String) -> Double { Double(counters[name] as? Int ?? 0) }
      let rounds = count("mtp_rounds")
      let replays = count("mtp_replay_rounds")
      let round = rounds > 0 ? total("mtp.round") / rounds : 0
      let replay = replays > 0 ? total("mtp.replay") / replays : 0
      var entry: [String: Any] = [
        "minute": (Date().timeIntervalSince(started) / 6).rounded() / 10,
        "accepted": exchange.accepted, "topic": topic,
        "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
        "rounds": rounds, "replayRounds": replays,
        "tokensPerRound": rounds > 0 ? count("tokens_decoded") / rounds : 0,
        "roundMs": round, "replayMs": replay,
        "ceiling": replay > 0 ? round / replay - 1 : 0,
        "gpuRoundMs": rounds > 0 ? (total("gpu.verify") + total("gpu.drafter")) / rounds : 0,
        "gpuReplayMs": replays > 0 ? total("gpu.replay") / replays : 0,
      ]
      entry.merge(DeviceHarness.stats(exchange.reply?.stats)) { a, _ in a }
      replies.append(entry)
      print("probe25 reply \(index): \(entry)")
      harness.record("probe25_replayCeiling", ["minutes": minutes, "replies": replies], in: self)
      XCTAssertTrue(exchange.accepted, appState.generationError ?? "")
      XCTAssertGreaterThan(replays, 0, "AGELLO_MTP_REPLAY=1 but no round was replayed (Google's runtime, or MTP off)")
      if !exchange.accepted { break }
    }
  }
}
