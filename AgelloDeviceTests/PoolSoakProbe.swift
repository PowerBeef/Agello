import XCTest

@testable import Agello

/// Probe 38: the GPU memory pool across a long session (B5, PERFORMANCE.md "On the Mac, now",
/// item 2; 2026-11-17). 200 turns through the app, short replies, with what makes the pool free
/// and rebuild: a long message every 10th turn (the 1,024-token prefill's private pool), a reply
/// stopped mid-stream every 25th, a helper conversation every 30th (the chat's cache copied
/// aside and back), an image every 40th, and the engine released and loaded again every 50th.
/// The footprint after each turn; the session's last turns may hold at most 150 MB more than
/// its early ones. On the Mac, malloc's cache of freed large blocks holds the encoders' buffers
/// (1.3 GB of growth, gone with `MallocLargeCache=0`, which `scripts/cli-test.sh` sets): the
/// runtime and the app leak nothing here (2026-11-17).
extension ProbeScenarioTests {
  func test38_PoolSoak() async throws {
    try await requireLoadedModel()
    let saved = appState.options
    defer { appState.options = saved }
    appState.options.enableThinking = false
    appState.options.maxOutputTokens = 40
    await appState.applyCurrentOptions()
    let turns = Int(ProcessInfo.processInfo.environment["POOL_SOAK_TURNS"] ?? "") ?? 200
    let paragraph =
      "The harbor town keeps its old customs: the boats go out before dawn, the market opens when they return, and the "
      + "lighthouse keeper writes the weather in a ledger that has been kept for a hundred and forty years. "
    let longMessage = "Here is a text.\n\n" + String(repeating: paragraph, count: 28) + "\n\nSay in one sentence what it is about."
    let questions = [
      "Name a fruit that is red.", "What is 7 times 8?", "Give me a synonym for happy.", "Which planet is largest?",
      "Say hello in Spanish.", "What color is the sky on a clear day?", "Name an ocean.", "What is the capital of Italy?",
    ]
    var footprints: [Double] = []
    var events: [String] = []
    var breakdowns: [[String: Any]] = []
    var vmmaps: [[String: Any]] = []
    // POOL_SOAK_SKIP=image,helper,stop,long,reload leaves those events out, to find which one
    // leaves memory behind.
    let skip = Set((ProcessInfo.processInfo.environment["POOL_SOAK_SKIP"] ?? "").split(separator: ",").map(String.init))
    var thread = harness.newThread()
    let started = Date()
    for turn in 1...turns {
      if turn % 20 == 1 { thread = harness.newThread() }
      if turn % 50 == 0, !skip.contains("reload") {
        await appState.unloadEngine()
        _ = await appState.ensureEngineLoaded()
        let unload = await harness.liveEngine?.loadLog.first ?? "no unload report"
        events.append("\(turn): engine released and loaded (\(unload))")
        #if os(macOS)
          // POOL_SOAK_VMMAP=1: what the process holds right after the reload, by region type.
          if ProcessInfo.processInfo.environment["POOL_SOAK_VMMAP"] == "1" {
            let vmmap = Process()
            vmmap.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
            vmmap.arguments = ["--summary", String(ProcessInfo.processInfo.processIdentifier)]
            let pipe = Pipe()
            vmmap.standardOutput = pipe
            vmmap.standardError = Pipe()
            try? vmmap.run()
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            vmmap.waitUntilExit()
            vmmaps.append(["turn": turn, "summary": text])
          }
        #endif
      }
      if turn % 30 == 0, !skip.contains("helper") {
        _ = await appState.planSearch(question: "Who won the 2026 Tour de France?", history: [])
        events.append("\(turn): helper")
      }
      if turn % 25 == 0, !skip.contains("stop") {
        let state = appState
        let current = thread
        let sending = Task { @MainActor in
          await state.send(text: "Write a 300-word story about a fox.", imageData: nil, audioFileURL: nil, in: current)
        }
        try await harness.waitUntil("a partial reply", timeout: 60) {
          (current.orderedTurns.last(where: { !$0.isUser })?.text.count ?? 0) > 20
        }
        appState.stop()
        _ = await sending.value
        events.append("\(turn): stopped mid-reply")
      } else if turn % 40 == 0, !skip.contains("image") {
        _ = await harness.ask("What color is this image? One word.", in: thread, image: TestMedia.solidColorJPEG(.red))
        events.append("\(turn): image")
      } else if turn % 10 == 0, !skip.contains("long") {
        _ = await harness.ask(longMessage, in: thread)
        events.append("\(turn): long message")
      } else {
        _ = await harness.ask(questions[turn % questions.count], in: thread)
      }
      footprints.append(Double(MemoryProbe.footprintBytes()) / 1e6)
      if turn % 10 == 0 || turn % 10 == 9 {
        let parts = MemoryProbe.breakdown().mapValues { ($0 * 1000).rounded() / 1000 }
        breakdowns.append(["turn": turn, "footprintMB": Int(footprints.last ?? 0), "parts": parts])
      }
    }
    func median(_ values: ArraySlice<Double>) -> Double {
      let sorted = values.sorted()
      return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
    let early = median(footprints[min(9, footprints.count - 1)..<min(30, footprints.count)])
    let late = median(footprints[max(0, footprints.count - 20)...])
    let growth = late - early
    harness.record(
      "probe38_poolSoak",
      [
        "turns": turns, "seconds": Date().timeIntervalSince(started), "footprintMB": footprints.map { ($0 * 10).rounded() / 10 },
        "earlyMedianMB": early, "lateMedianMB": late, "growthMB": growth, "peakMB": footprints.max() ?? 0,
        "events": events, "breakdowns": breakdowns, "vmmaps": vmmaps, "error": appState.generationError ?? "",
      ], in: self)
    print("probe38 turns \(turns): early \(Int(early)) MB, late \(Int(late)) MB, growth \(Int(growth)) MB, peak \(Int(footprints.max() ?? 0)) MB")
    XCTAssertLessThan(growth, 150, "The footprint grew \(Int(growth)) MB over \(turns) turns")
  }
}
