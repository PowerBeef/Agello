import XCTest

@testable import Agello

extension ProbeScenarioTests {
  /// Probe 24: what a window costs on the iPhone (PERFORMANCE.md, "The window: 32K growing to
  /// 64K"): a model file opened past 32K (the fork's `window_128k.py`, its folder copied into
  /// Documents/lab with devicectl) at each window, through the app's own pipeline. Per window:
  /// the footprint after load; per prompt (crate records with three unique needles at 10, 50 and
  /// 90 % depth): first token, the footprint's peak (sampled every 100 ms) and after, whether the
  /// three needles came back, then a 300-word follow-up for decode speed with the window filled.
  ///
  /// - `TEST_RUNNER_AGELLO_MODELS_DIR`: the folder, e.g. `~/Documents/lab/w128k` (read only).
  /// - `TEST_RUNNER_AGELLO_EXPORT_WINDOW`: the file's export window, 131101.
  /// - `TEST_RUNNER_WINDOW_COST`: `window:tokens+tokens,…`, e.g. `32768:5000+21000,65536:5000+21000+44000`.
  func test24_WindowCost() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let spec = env["WINDOW_COST"] else { throw XCTSkip("Set TEST_RUNNER_WINDOW_COST") }
    guard let folder = ModelStore.externalModelsDirectory,
      FileManager.default.fileExists(atPath: folder.appendingPathComponent(ModelCatalog.e4b.fileName).path)
    else {
      throw XCTSkip(
        "Set TEST_RUNNER_AGELLO_MODELS_DIR to a folder holding \(ModelCatalog.e4b.fileName) (home: \(NSHomeDirectory()))")
    }
    XCTAssertGreaterThan(ContextBudget.exportWindow, 65_536, "Set TEST_RUNNER_AGELLO_EXPORT_WINDOW")

    let tools = appState.enableTools
    let preset = appState.options.samplerPreset
    defer {
      appState.enableTools = tools
      appState.options.samplerPreset = preset
    }
    appState.enableTools = false  // as the Mac's runs (`agello ask --no-tools`)
    appState.options.samplerPreset = .precise

    var results: [[String: Any]] = []
    for part in spec.split(separator: ",") {
      let fields = part.split(separator: ":")
      guard fields.count == 2, let window = Int(fields[0]) else {
        XCTFail("WINDOW_COST entry \(part): want window:tokens+tokens")
        continue
      }
      let sizes = fields[1].split(separator: "+").compactMap { Int($0) }
      await appState.engine.unload()
      appState.options.maxNumTokensOverride = window
      await appState.applyCurrentOptions()
      let loadStarted = Date()
      try await requireLoadedModel()
      let loadSeconds = Date().timeIntervalSince(loadStarted)
      let afterLoad = Self.gigabytes(MemoryProbe.footprintBytes())
      var windowEntry: [String: Any] = [
        "window": window, "allocated": appState.resolved?.maxNumTokens ?? -1,
        "loadSeconds": loadSeconds, "footprintAfterLoadGB": afterLoad,
        "limitGB": Self.gigabytes(MemoryProbe.appMemoryLimitBytes() ?? 0),
      ]
      var prompts: [[String: Any]] = []
      for tokens in sizes {
        let (prompt, needles) = Self.crateRecords(tokens: tokens, seed: UInt64(tokens))
        let thread = harness.newThread()
        let sampler = PeakSampler()
        sampler.start()
        let exchange = await harness.ask(prompt, in: thread)
        let peak = sampler.stop()
        let found = needles.filter { exchange.text.contains($0) }.count
        var entry: [String: Any] = [
          "tokens": tokens, "accepted": exchange.accepted,
          "generationError": appState.generationError ?? "",
          "needlesFound": found, "needles": needles.count, "reply": String(exchange.text.prefix(400)),
          "peakGB": Self.gigabytes(peak), "afterGB": Self.gigabytes(MemoryProbe.footprintBytes()),
          "seconds": exchange.seconds,
        ]
        entry.merge(DeviceHarness.stats(exchange.reply?.stats)) { a, _ in a }
        if exchange.accepted {
          let followUpSampler = PeakSampler()
          followUpSampler.start()
          let followUp = await harness.ask(
            "Now write about 300 words on the history of lighthouses.", in: thread)
          let followUpPeak = followUpSampler.stop()
          entry["followUp"] = DeviceHarness.stats(followUp.reply?.stats).merging([
            "accepted": followUp.accepted, "peakGB": Self.gigabytes(followUpPeak),
            "words": followUp.text.split(separator: " ").count,
          ]) { a, _ in a }
        }
        prompts.append(entry)
        windowEntry["prompts"] = prompts
        harness.record("probe24_windowCost", ["results": results + [windowEntry]], in: self)
        print("probe24 window \(window) tokens \(tokens): \(entry)")
        XCTAssertTrue(exchange.accepted, appState.generationError ?? "")
      }
      results.append(windowEntry)
      harness.record("probe24_windowCost", ["results": results], in: self)
    }
    await appState.engine.unload()
  }

  static func gigabytes(_ bytes: UInt64) -> Double { (Double(bytes) / 1e7).rounded() / 100 }

  /// About `tokens` tokens of crate records (about 21 tokens each, measured), with three records of unique
  /// names at 10, 50 and 90 % depth, and a question about them. Returns the prompt and the three
  /// crate numbers the answer should hold.
  static func crateRecords(tokens: Int, seed: UInt64) -> (String, [String]) {
    var state = seed &+ 0x9E37_79B9_7F4A_7C15
    func next(_ bound: Int) -> Int {
      state = state &+ 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return Int((z ^ (z >> 31)) % UInt64(bound))
    }
    let names = ["Gita", "Ines", "Bram", "Jun", "Odile", "Tariq", "Mira", "Lev", "Ana", "Kofi"]
    let special = ["Zephyrine", "Quillon", "Marisol"]
    let count = max(30, tokens / 21)
    let depths = [count / 10, count / 2, count * 9 / 10]
    var lines: [String] = []
    var needles: [String] = []
    for i in 0..<count {
      if let k = depths.firstIndex(of: i) {
        let crate = 10_000 + next(89_999)
        needles.append(String(crate))
        lines.append("(\(i + 1)) \(special[k]) stored crate number \(crate) in aisle \(1 + next(40)).")
      }
      lines.append(
        "(\(i + 1)) \(names[next(names.count)]) stored crate number \(1_000 + next(8_999)) in aisle \(1 + next(40)).")
    }
    let question =
      "Which crate numbers did Zephyrine, Quillon and Marisol store? Answer with one line per name and its crate number."
    return ("Warehouse log:\n" + lines.joined(separator: "\n") + "\n\n" + question, needles)
  }
}

/// The process footprint's highest value while a reply runs, sampled every 100 ms.
final class PeakSampler: @unchecked Sendable {
  private let lock = NSLock()
  private var peak: UInt64 = 0
  private var task: Task<Void, Never>?

  func start() {
    task = Task.detached { [weak self] in
      while !Task.isCancelled {
        let footprint = MemoryProbe.footprintBytes()
        self?.lock.withLock { self?.peak = max(self?.peak ?? 0, footprint) }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }

  func stop() -> UInt64 {
    task?.cancel()
    return lock.withLock { max(peak, MemoryProbe.footprintBytes()) }
  }
}
