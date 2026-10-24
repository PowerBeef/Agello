import LiteRTLM
import XCTest

@testable import Agello

extension ProbeScenarioTests {
  /// Probe 20: the #3913 research suites (agello-bench's digit-copy format: `id`, `sentences`,
  /// `late`, `seed`) on lab models copied into Documents/lab with devicectl, so the iPhone runs
  /// the same cases as the Macs on the issue. `copyRun` builds the same prompt as BenchKit.
  ///
  /// - `TEST_RUNNER_LAB_ARMS`: `name:file:fp16|fp32`, comma-separated, one engine at a time.
  /// - `TEST_RUNNER_LAB_SUITES`: suite files in Documents/lab, without `.json`.
  /// - `TEST_RUNNER_LAB_KV`: the window (maxNumTokens), default 8,192.
  ///
  /// Lab models load without an engine cache, so they leave nothing behind but themselves
  /// (`test13_RemoveLabModels` deletes those).
  func test20_LabSuites() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let armSpecs = env["LAB_ARMS"], let suiteNames = env["LAB_SUITES"] else {
      throw XCTSkip("Set TEST_RUNNER_LAB_ARMS and TEST_RUNNER_LAB_SUITES")
    }
    let lab = try FileManager.default.url(
      for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
    ).appendingPathComponent("lab")
    let kv = Int(env["LAB_KV"] ?? "") ?? 8_192
    let suites = try suiteNames.split(separator: ",").map { name in
      let data = try Data(contentsOf: lab.appendingPathComponent("\(name).json"))
      return (name: String(name), cases: try JSONDecoder().decode([LabCase].self, from: data))
    }

    await appState.engine.unload()
    ExperimentalFlags.optIntoExperimentalAPIs()
    ExperimentalFlags.enableBenchmark = true
    ExperimentalFlags.enableSpeculativeDecoding = false
    var results: [[String: Any]] = []
    for spec in armSpecs.split(separator: ",") {
      let parts = spec.split(separator: ":").map(String.init)
      guard parts.count == 3, ["fp16", "fp32"].contains(parts[2]) else {
        XCTFail("Arm \(spec): want name:file:fp16|fp32")
        continue
      }
      let (arm, file, activation) = (parts[0], parts[1], parts[2])
      let model = lab.appendingPathComponent(file)
      guard FileManager.default.fileExists(atPath: model.path) else {
        XCTFail("Copy \(file) to Documents/lab first")
        continue
      }
      // One engine at a time: released at the end of each iteration.
      let loadStarted = Date()
      let engine = Engine(
        engineConfig: try EngineConfig(
          modelPath: model.path, backend: .gpu, maxNumTokens: kv, cacheDir: EngineCache.disabled,
          activationDataType: activation == "fp32" ? .float32 : nil))
      try await engine.initialize()
      let loadSeconds = (Date().timeIntervalSince(loadStarted) * 10).rounded() / 10
      for suite in suites {
        for item in suite.cases {
          let late = item.late ?? false
          let run = try await Self.copyRun(
            engine: engine, digits: Self.referenceDigits(seed: item.seed), sentences: item.sentences, late: late)
          var entry = run.record(arm: arm, seed: item.seed, sentences: item.sentences, late: late)
          entry["id"] = item.id
          entry["suite"] = suite.name
          entry["model"] = file
          entry["activation"] = activation
          entry["kv"] = kv
          entry["loadSeconds"] = loadSeconds
          entry["footprintGB"] = (Double(MemoryProbe.footprintBytes()) / 1e7).rounded() / 100
          results.append(entry)
          harness.record("probe20_labSuites", ["results": results], in: self)
          print("probe20 \(arm) \(suite.name)/\(item.id) prefill=\(run.prefill) \(run.summary)")
        }
      }
    }
  }
}

/// One digit-copy case of an agello-bench suite.
private struct LabCase: Decodable {
  let id: String
  let sentences: Int
  let late: Bool?
  let seed: Int
}
