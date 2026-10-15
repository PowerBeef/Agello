import XCTest

@testable import Agello

/// Measures what context size (KV cache) each model can afford on this
/// device: load time, prefill speed, memory footprint and headroom while a
/// third of the window is filled. Opt-in: HARNESS_CALIBRATE=1.
///
/// Each size is recorded before the next is tried, so if the system kills
/// the app for memory, the report still holds the largest size that worked.
final class CalibrationScenarioTests: DeviceTestCase {
  static let windows = [4_096, 8_192, 16_384, 32_768]

  override func setUp() async throws {
    try await super.setUp()
    guard ProcessInfo.processInfo.environment["HARNESS_CALIBRATE"] == "1" else {
      throw XCTSkip("Set HARNESS_CALIBRATE=1 to run context calibration")
    }
  }

  func test01_CalibrateE4B() async throws {
    try await calibrate(.e4b)
  }

  private func calibrate(_ model: ModelID) async throws {
    _ = try await harness.ensureDownloaded(ModelCatalog.e4b, timeout: 5400)
    let limitGB = Double(DeviceProfile.current.appMemoryLimitBytes ?? 0) / 1e9
    for window in Self.windows {
      appState.options.maxNumTokensOverride = window
      await appState.applyCurrentOptions()
      await appState.ensureEngineLoaded()
      let loadLog = await harness.liveEngine?.loadLog ?? []
      let afterLoad = MemoryProbe.footprintBytes()
      // The model file may cap its context.
      let effective = appState.resolved?.maxNumTokens ?? 0
      let loaded = appState.engineState == .ready && effective >= min(window, 32_000)
      var values: [String: Any] = [
        "model": model.rawValue, "window": window, "effectiveWindow": effective,
        "appLimitGB": limitGB, "loaded": loaded,
        "loadLog": loadLog,
        "footprintAfterLoadGB": Double(afterLoad) / 1e9,
        // 0 nominal, 1 fair, 2 serious, 3 critical: throttling changes every number here.
        "thermalStateAfterLoad": ProcessInfo.processInfo.thermalState.rawValue,
        "lowPowerMode": ProcessInfo.processInfo.isLowPowerModeEnabled,
      ]
      guard loaded else {
        harness.record("calibration_\(model.rawValue)_\(window)", values, in: self)
        XCTFail("\(model.rawValue) failed to load with a \(window)-token window")
        return
      }
      // Fill roughly a third of the window (estimate is pessimistic, so the
      // real token count is lower than the byte-based estimate).
      let filler = Self.filler(bytes: effective * Int(ContextBudget.bytesPerToken) / 3)
      let thread = harness.newThread()
      let exchange = await harness.ask(
        filler + "\n\nIn one sentence, what is the text above about?", in: thread)
      let stats = exchange.reply?.stats
      values["accepted"] = exchange.accepted
      values["inputTokens"] = stats?.inputTokens ?? -1
      values["ttftSeconds"] = stats?.timeToFirstToken ?? -1
      values["prefillTokPerSec"] =
        (stats?.inputTokens).flatMap { tokens in
          stats?.timeToFirstToken.map { $0 > 0 ? Double(tokens) / $0 : -1 }
        } ?? -1
      values["decodeTokPerSec"] = stats?.decodeTokensPerSecond ?? -1
      values["footprintPeakGB"] = Double(MemoryProbe.footprintBytes()) / 1e9
      values["availableGB"] = Double(MemoryProbe.availableBytes()) / 1e9
      values["replyPrefix"] = String(exchange.text.prefix(120))
      values["outputTokens"] = stats?.outputTokens ?? -1
      values["thermalStateAfterReply"] = ProcessInfo.processInfo.thermalState.rawValue
      harness.record("calibration_\(model.rawValue)_\(window)", values, in: self)
      XCTAssertTrue(exchange.accepted, appState.generationError ?? "")
      XCTAssertFalse(exchange.text.hasPrefix(ChatTurn.errorPrefix), exchange.text)
      // The one-sentence reply above decodes 30-60 tokens, too few for a steady
      // rate (runs differ by about 10%); a longer follow-up in the same chat
      // measures decode over a few hundred.
      let followUp = await harness.ask(
        "List ten details from the text, one short sentence each.", in: thread)
      let followUpStats = followUp.reply?.stats
      values["longDecodeTokPerSec"] = followUpStats?.decodeTokensPerSecond ?? -1
      values["longOutputTokens"] = followUpStats?.outputTokens ?? -1
      values["longReplyAccepted"] = followUp.accepted
      values["footprintAfterFollowUpGB"] = Double(MemoryProbe.footprintBytes()) / 1e9
      values["thermalStateAfterFollowUp"] = ProcessInfo.processInfo.thermalState.rawValue
      harness.record("calibration_\(model.rawValue)_\(window)", values, in: self)
      XCTAssertTrue(followUp.accepted, appState.generationError ?? "")
    }
  }

  /// Varied English prose (repetitive text tokenizes unrealistically well).
  static func filler(bytes: Int) -> String {
    let topics = [
      "The lighthouse keeper logged the weather every hour, noting wind, swell and visibility.",
      "Supply boats arrived on Thursdays with fuel, flour, letters and the occasional visitor.",
      "In winter the lamp burned for sixteen hours, and the lens had to be polished at dawn.",
      "Seabirds nested in the cliffs below, and their numbers were counted every spring.",
      "The keeper's daughter learned navigation from old charts kept in a cedar chest.",
      "Storms in 1911 cracked the gallery glass, which was replaced with thicker panes.",
      "A radio arrived in 1934, ending the island's long silence between supply runs.",
      "Automation came decades later, and the last keeper left with a box of logbooks.",
    ]
    var text = ""
    var index = 0
    while text.utf8.count < bytes {
      text += "\(index + 1). " + topics[index % topics.count] + " "
      index += 1
    }
    return text
  }
}
