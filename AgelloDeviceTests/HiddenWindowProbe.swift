#if os(macOS)
  import AppKit
  import XCTest

  @testable import Agello

  extension ProbeScenarioTests {
    /// Probe 21 (Agello for Mac): a hidden window never stops or slows a reply. Two replies with
    /// the app shown, five minutes of replies with it hidden and ``WorkActivity`` held as the app
    /// holds it, then one after a minute hidden and idle with no activity, when App Nap could
    /// have set in (docs/MAC.md, M3). Each reply is a fresh chat of about 300 words.
    func test21_RepliesWhileHidden() async throws {
      try await requireLoadedModel()
      let prompt = "Write about 300 words on how a lighthouse works, for a curious child."
      var rows: [[String: Any]] = []
      func reply(_ label: String) async -> Double {
        let exchange = await harness.ask(prompt, in: harness.newThread())
        let stats = exchange.reply?.stats
        let speed = stats?.decodeTokensPerSecond ?? -1
        let row: [String: Any] = [
          "label": label, "accepted": exchange.accepted, "seconds": exchange.seconds,
          "decodeTokPerSec": speed, "outputTokens": stats?.outputTokens ?? -1,
          "appHidden": NSApp.isHidden,
          "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
        ]
        rows.append(row)
        print("PROBE21 \(row)")
        harness.record("probe21_replies_while_hidden", ["rows": rows], in: self)
        XCTAssertTrue(exchange.accepted, appState.generationError ?? "rejected")
        return speed
      }

      var shown: [Double] = []
      for _ in 0..<2 { shown.append(await reply("shown")) }

      var activity: WorkActivity? = WorkActivity(appState: appState)
      NSApp.hide(nil)
      var hidden: [Double] = []
      let until = Date().addingTimeInterval(300)
      while Date() < until { hidden.append(await reply("hidden")) }
      activity = nil

      try await Task.sleep(for: .seconds(60))
      let napped = await reply("hidden-idle-no-activity")
      NSApp.unhide(nil)
      _ = activity

      let baseline = shown.sorted()[shown.count / 2]
      XCTAssertGreaterThan(baseline, 0)
      for speed in hidden {
        XCTAssertGreaterThan(speed, baseline * 0.75, "a hidden reply slowed: \(speed) against \(baseline) tok/s shown")
      }
      // Recorded, not asserted: whether App Nap slows a reply that starts with nothing held.
      print("PROBE21 shown \(baseline) tok/s, hidden \(hidden), hidden and idle without activity \(napped)")
    }
  }
#endif
