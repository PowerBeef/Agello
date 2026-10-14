import SwiftData
import UIKit
import XCTest

@testable import Agello

enum HarnessError: Error, CustomStringConvertible {
  case downloadFailed(String)
  case downloadTimedOut(progress: Double)
  case timedOut(String)

  var description: String {
    switch self {
    case .downloadFailed(let message): return "Download failed: \(message)"
    case .downloadTimedOut(let progress):
      return String(format: "Download timed out at %.0f%%", progress * 100)
    case .timedOut(let what): return "Timed out waiting for \(what)"
    }
  }
}

/// One real engine shared by every on-device scenario (loading Gemma per
/// test would dominate the run). Runs inside the app process (hosted tests),
/// so it sees the app's downloaded models.
@MainActor
final class DeviceHarness {
  static let shared = DeviceHarness()

  let container: ModelContainer
  let appState: AppState
  /// Options every scenario starts from; scenarios that change options
  /// restore this in tearDown.
  let baselineOptions = InferenceOptions()
  /// Web search as a fresh install has it (allowed, not automatic): the
  /// phone's own saved settings must not decide whether scenarios search.
  let baselineWeb = WebSearchSettings()

  private static let defaultsKeys = [
    "inferenceOptions", "enableTools", "selectedThreadID", "benchmarkReport", "memoryEnabled",
    "personalization", "webSearch",
  ]
  private var savedDefaults: [String: Any] = [:]
  private var report: [String: Any] = [:]

  var context: ModelContext { container.mainContext }
  var liveEngine: LiteRTChatEngine? { appState.engine as? LiteRTChatEngine }

  private init() {
    // The harness shares UserDefaults with the real app: snapshot the user's
    // settings so ``restoreUserDefaults()`` can put them back.
    for key in Self.defaultsKeys {
      savedDefaults[key] = UserDefaults.standard.object(forKey: key)
    }
    container = try! ModelContainer(
      for: ChatStore.schema,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    appState = AppState(useMockEngine: false)
    appState.modelContext = container.mainContext
    appState.options = baselineOptions
    appState.enableTools = true
    appState.webSettings = baselineWeb
    // Long downloads and generations must not be interrupted by auto-lock.
    UIApplication.shared.isIdleTimerDisabled = true
    report["device"] = [
      "model": UIDevice.current.model,
      "system": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
      "memoryGB": DeviceProfile.current.memoryGB,
      "profile": DeviceProfile.current.summary,
    ]
    report["startedAt"] = ISO8601DateFormatter().string(from: Date())
    // XCTest relaunches the app after a crash and continues with the next
    // test: keep the results recorded before the crash in the same run
    // (scripts/device-harness.sh passes HARNESS_RUN_ID) instead of
    // overwriting them.
    let runID = ProcessInfo.processInfo.environment["HARNESS_RUN_ID"] ?? UUID().uuidString
    report["runID"] = runID
    if let url = Self.reportURL,
      let data = try? Data(contentsOf: url),
      let previous = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      previous["runID"] as? String == runID
    {
      report["scenarios"] = previous["scenarios"]
      report["startedAt"] = previous["startedAt"]
      report["relaunches"] = (previous["relaunches"] as? Int ?? 0) + 1
    }
  }

  private static var reportURL: URL? {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
      .appendingPathComponent("harness-report.json")
  }

  func restoreUserDefaults() {
    for key in Self.defaultsKeys {
      if let value = savedDefaults[key] {
        UserDefaults.standard.set(value, forKey: key)
      } else {
        UserDefaults.standard.removeObject(forKey: key)
      }
    }
  }

  /// Put options back to the baseline (and apply them to a loaded engine).
  func resetOptions() async {
    guard
      appState.options != baselineOptions || !appState.enableTools
        || appState.webSettings != baselineWeb
    else { return }
    appState.options = baselineOptions
    appState.enableTools = true
    appState.webSettings = baselineWeb
    await appState.applyCurrentOptions()
  }

  // MARK: - Model files

  /// Download `spec` through the app's own ModelStore if it is missing.
  /// Resumes automatically after transient network pauses.
  func ensureDownloaded(_ spec: ModelSpec, timeout: TimeInterval = 3600) async throws
    -> TimeInterval
  {
    let store = appState.store
    store.refreshStates()
    if store.isDownloaded(spec) { return 0 }
    let started = Date()
    var lastLoggedPercent = -1
    var lastProgress = 0.0
    store.startDownload(spec)
    while true {
      switch store.states[spec.id] ?? .notDownloaded {
      case .ready:
        return Date().timeIntervalSince(started)
      case .failed(let message):
        throw HarnessError.downloadFailed(message)
      case .paused:
        try await Task.sleep(for: .seconds(5))
        store.startDownload(spec)
      case .downloading(let progress):
        lastProgress = progress
        let percent = Int(progress * 100)
        if percent / 5 != lastLoggedPercent / 5 {
          lastLoggedPercent = percent
          Log.lifecycle.info("harness download \(spec.id.rawValue, privacy: .public) \(percent)%")
        }
      case .notDownloaded:
        break
      }
      if Date().timeIntervalSince(started) > timeout {
        throw HarnessError.downloadTimedOut(progress: lastProgress)
      }
      try await Task.sleep(for: .seconds(2))
    }
  }

  // MARK: - Conversations

  func newThread() -> ChatThread {
    appState.newThread(in: context)
  }

  struct Exchange {
    let accepted: Bool
    let reply: ChatTurn?
    let seconds: TimeInterval
    var text: String { reply?.text ?? "" }
  }

  /// Send through the real app pipeline (``AppState/send``) and wait for the reply.
  func ask(
    _ prompt: String, in thread: ChatThread, image: Data? = nil, audio: URL? = nil,
    webSearch: Bool = false
  ) async -> Exchange {
    let started = Date()
    let accepted = await appState.send(
      text: prompt, imageData: image, audioFileURL: audio, webSearch: webSearch, in: thread)
    let reply = accepted ? thread.orderedTurns.last(where: { !$0.isUser }) : nil
    return Exchange(accepted: accepted, reply: reply, seconds: Date().timeIntervalSince(started))
  }

  /// Poll `condition` on the main actor until true or `timeout`.
  func waitUntil(
    _ what: String, timeout: TimeInterval, condition: () -> Bool
  ) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
      if Date() > deadline { throw HarnessError.timedOut(what) }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  // MARK: - Reporting

  /// Record a scenario result: attached to the xcresult, logged, and merged
  /// into Documents/harness-report.json (pull it with `devicectl device copy from`).
  func record(_ scenario: String, _ values: [String: Any], in testCase: XCTestCase) {
    var entry = values
    entry["memory.footprintGB"] = Double(MemoryProbe.footprintBytes()) / 1e9
    entry["memory.availableGB"] = Double(MemoryProbe.availableBytes()) / 1e9
    entry["recordedAt"] = ISO8601DateFormatter().string(from: Date())
    var scenarios = report["scenarios"] as? [String: Any] ?? [:]
    scenarios[scenario] = entry
    report["scenarios"] = scenarios

    guard
      let data = try? JSONSerialization.data(
        withJSONObject: entry, options: [.prettyPrinted, .sortedKeys])
    else { return }
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "\(scenario).json"
    attachment.lifetime = .keepAlways
    testCase.add(attachment)
    Log.lifecycle.info(
      "harness \(scenario, privacy: .public): \(String(decoding: data, as: UTF8.self), privacy: .public)"
    )
    writeReport()
  }

  private func writeReport() {
    guard
      let url = Self.reportURL,
      let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(to: url, options: .atomic)
  }

  func resolvedSummary() -> [String: Any] {
    guard let r = appState.resolved else { return ["resolved": "nil"] }
    return [
      "backend": r.backendLabel,
      "kvTokens": r.maxNumTokens,
      "vision": r.enableVision,
      "audio": r.enableAudio,
      "mtp": r.enableSpeculativeDecoding,
      "thinkingBudget": r.thinkingBudget ?? 0,
      "visualTokenBudget": Int(r.visualTokenBudget ?? 0),
    ]
  }

  static func stats(_ stats: GenerationStats?) -> [String: Any] {
    guard let stats else { return ["stats": "nil"] }
    return [
      "ttftSeconds": stats.timeToFirstToken ?? -1,
      "totalSeconds": stats.totalTime,
      "inputTokens": stats.inputTokens ?? -1,
      "outputTokens": stats.outputTokens ?? -1,
      "decodeTokPerSec": stats.decodeTokensPerSecond ?? -1,
      "backend": stats.backend,
    ]
  }
}

/// Base class: skips on the simulator (no Metal LLM path) and gives each
/// scenario a clean option set.
@MainActor
class DeviceTestCase: XCTestCase {
  var harness: DeviceHarness { DeviceHarness.shared }
  var appState: AppState { harness.appState }

  override func setUp() async throws {
    #if targetEnvironment(simulator)
      throw XCTSkip("On-device inference only: run on a physical iPhone.")
    #else
      continueAfterFailure = true
    #endif
  }

  override func tearDown() async throws {
    await harness.resetOptions()
  }

  override class func tearDown() {
    MainActor.assumeIsolated { DeviceHarness.shared.restoreUserDefaults() }
    super.tearDown()
  }

  /// Ensure the model (E4B) is downloaded and loaded; skips the scenario otherwise.
  func requireLoadedModel() async throws {
    _ = try await harness.ensureDownloaded(ModelCatalog.e4b, timeout: 5400)
    let loaded = await appState.ensureEngineLoaded()
    guard loaded else {
      XCTFail("E4B failed to load: \(appState.engineState)")
      throw XCTSkip("Engine not loaded")
    }
  }
}
