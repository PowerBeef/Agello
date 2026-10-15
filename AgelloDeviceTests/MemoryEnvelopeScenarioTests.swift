import Darwin
import UIKit
import XCTest

@testable import Agello

/// Simulates the smaller memory limit of an 8 GB iPhone (iPhone 15 Pro class)
/// on a larger device: incompressible "ballast" memory shrinks the app's
/// usable memory to a target limit, then the real workload runs. If iOS
/// kills the app, XCTest relaunches and the report shows the last step that
/// completed. Opt-in: HARNESS_MEMORY=1.
///
/// Limits of the simulation: speed is not simulated (GPU and memory
/// bandwidth differ), and the device still has its full physical RAM, so the
/// memory-mapped model file is under less eviction pressure than on a real
/// 8 GB phone. Results are an optimistic bound.
final class MemoryEnvelopeScenarioTests: DeviceTestCase {
  private let ballast = MemoryBallast()
  private var memoryWarnings = 0
  private var warningObserver: NSObjectProtocol?

  override func setUp() async throws {
    try await super.setUp()
    guard ProcessInfo.processInfo.environment["HARNESS_MEMORY"] == "1" else {
      throw XCTSkip("Set HARNESS_MEMORY=1 to run the 8 GB memory simulation")
    }
    memoryWarnings = 0
    warningObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.memoryWarnings += 1 }
    }
  }

  override func tearDown() async throws {
    if let warningObserver { NotificationCenter.default.removeObserver(warningObserver) }
    await appState.engine.unload()
    ballast.release()
    try await super.tearDown()
  }

  func test01_E4B_at5_0GB() async throws { try await run(.e4b, limitGB: 5.0) }
  func test02_E4B_at4_0GB() async throws { try await run(.e4b, limitGB: 4.0) }
  func test03_E4B_at3_5GB() async throws { try await run(.e4b, limitGB: 3.5) }

  private func run(_ model: ModelID, limitGB: Double) async throws {
    let spec = ModelCatalog.spec(for: model)
    guard appState.store.isDownloaded(spec) else { throw XCTSkip("\(spec.displayName) not downloaded") }
    let name = "memory_\(model.rawValue)_\(String(format: "%.1f", limitGB))GB"

    // Measure the real limit with nothing loaded, then shrink it.
    await appState.engine.unload()
    // What the app holds with no engine loaded. Before the test host stayed
    // idle, its own warmed-up engine showed here as 1.4-1.9 GB (probe 16).
    let leftover = MemoryProbe.breakdown()
    let realLimit = Double(MemoryProbe.footprintBytes() + MemoryProbe.availableBytes())
    let target = limitGB * 1e9
    try ballast.grow(toBytes: max(0, Int(realLimit - target)))
    var steps: [[String: Any]] = []
    func step(_ label: String, _ extra: [String: Any] = [:]) {
      var entry = extra
      entry["step"] = label
      entry["footprintGB"] = Double(MemoryProbe.footprintBytes()) / 1e9
      entry["availableGB"] = Double(MemoryProbe.availableBytes()) / 1e9
      entry["memoryWarnings"] = memoryWarnings
      steps.append(entry)
      // Saved after every step: if iOS kills the app, the report keeps
      // everything up to the last step that completed.
      harness.record(
        name,
        [
          "realLimitGB": realLimit / 1e9, "simulatedLimitGB": limitGB,
          "ballastGB": Double(ballast.bytes) / 1e9, "steps": steps,
          "leftoverGB": leftover,
        ], in: self)
    }
    step("ballast")

    appState.options.maxNumTokensOverride = 8_192
    await appState.applyCurrentOptions()
    await appState.ensureEngineLoaded()
    let loaded = appState.resolved != nil && appState.engineState == .ready
    step("load 8K", ["loaded": loaded, "loadLog": await harness.liveEngine?.loadLog ?? []])
    guard loaded else {
      XCTFail("\(spec.displayName) failed to load under \(limitGB) GB: \(appState.engineState)")
      return
    }

    let chat = await harness.ask(
      "Explain in about 150 words how tides work.", in: harness.newThread())
    step("text", ["ok": Self.ok(chat), "decodeTokPerSec": chat.reply?.stats?.decodeTokensPerSecond ?? -1])

    let image = await harness.ask(
      "What is the dominant color of this image? Answer with one word.", in: harness.newThread(),
      image: TestMedia.solidColorJPEG(.red))
    step("image", ["ok": Self.ok(image), "reply": image.text])

    let audio = try await TestMedia.spokenWAV("The quick brown fox jumps over the lazy dog.")
    defer { try? FileManager.default.removeItem(at: audio) }
    let heard = await harness.ask("Transcribe this audio exactly.", in: harness.newThread(), audio: audio)
    step("audio", ["ok": Self.ok(heard), "reply": heard.text])

    let long = await harness.ask(
      CalibrationScenarioTests.filler(bytes: 8_192) + "\n\nSummarize the text above in one sentence.",
      in: harness.newThread())
    step(
      "long 8K",
      ["ok": Self.ok(long), "inputTokens": long.reply?.stats?.inputTokens ?? -1,
       "ttftSeconds": long.reply?.stats?.timeToFirstToken ?? -1])

    appState.options.maxNumTokensOverride = 16_384
    await appState.applyCurrentOptions()
    let reloaded = appState.resolved?.maxNumTokens == 16_384
    let longer = await harness.ask(
      CalibrationScenarioTests.filler(bytes: 16_384) + "\n\nSummarize the text above in one sentence.",
      in: harness.newThread())
    step(
      "long 16K",
      ["loaded": reloaded, "ok": Self.ok(longer),
       "inputTokens": longer.reply?.stats?.inputTokens ?? -1,
       "ttftSeconds": longer.reply?.stats?.timeToFirstToken ?? -1])

    XCTAssertTrue(Self.ok(chat), "Text failed under \(limitGB) GB")
    XCTAssertTrue(Self.ok(image), "Image failed under \(limitGB) GB")
    XCTAssertTrue(Self.ok(heard), "Audio failed under \(limitGB) GB")
    XCTAssertTrue(Self.ok(long), "8K input failed under \(limitGB) GB")
  }

  private static func ok(_ exchange: DeviceHarness.Exchange) -> Bool {
    exchange.accepted && !exchange.text.isEmpty && !exchange.text.hasPrefix(ChatTurn.errorPrefix)
  }
}

/// Incompressible resident memory that counts toward the app's footprint.
final class MemoryBallast {
  private var regions: [(pointer: UnsafeMutableRawPointer, size: Int)] = []
  private(set) var bytes = 0

  func grow(toBytes target: Int) throws {
    let chunk = 128 << 20
    while bytes < target {
      let size = min(chunk, target - bytes)
      let pointer = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
      guard let pointer, pointer != MAP_FAILED else { throw POSIXError(.ENOMEM) }
      // Random bytes: the memory compressor can't shrink them.
      arc4random_buf(pointer, size)
      regions.append((pointer, size))
      bytes += size
    }
  }

  func release() {
    for region in regions { munmap(region.pointer, region.size) }
    regions.removeAll()
    bytes = 0
  }
}
