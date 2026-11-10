import Foundation

/// `agello bench`: the iPhone bench's cases (`AgelloUITests/BenchCases.swift`) through the app's
/// engine on this Mac, one record per reply.
///
/// A record is one line of JSON with `agello-bench`'s keys (the fork's `BenchKit.CaseRecord`),
/// so its `compare.py` and `telemetry.py` read a run unchanged, plus what only the app knows:
/// the settings in effect, why the reply ended, the reasoning, the path of the app's trace.
@MainActor
struct Bench {
  struct Options {
    var only: Set<String> = []
    var repeats = 1
    var warmup = false
    var label = "arm"
    var out: String
    var helpers = true
    var telemetryLevel: Int32?
    var caseTimeout: Double?

    init(_ arguments: inout Arguments) {
      only = Set(arguments.values("only").flatMap { $0.split(separator: ",").map(String.init) })
      repeats = max(1, arguments.value("repeat").flatMap(Int.init) ?? 1)
      warmup = arguments.flag("warmup")
      label = arguments.value("label") ?? "arm"
      out = Setup.expand(arguments.value("out") ?? Setup.defaultRunFile(label: label))
      helpers = !arguments.flag("no-helpers")
      telemetryLevel = arguments.value("telemetry").flatMap(Int32.init)
      caseTimeout = arguments.value("timeout").flatMap(Double.init)
    }
  }

  let session: Session
  let options: Options
  /// This process: one engine load, one machine, one set of options.
  let run = String(UUID().uuidString.prefix(8)).lowercased()
  var loadSeconds = 0.0
  var cache = "warm"
  private var problems = 0

  static let warmupPrompt = "Reply with one short sentence about the sea."

  static func main(_ arguments: inout Arguments, paths: [String: String]) async -> Int32 {
    var settings: Session.Settings
    do {
      settings = try Session.Settings(&arguments)
    } catch {
      note(error.message)
      return 2
    }
    let options = Options(&arguments)
    guard arguments.rest.isEmpty else {
      note("Not understood: \(arguments.rest.joined(separator: " "))")
      return 2
    }
    let cases = BenchCase.all.filter { options.only.isEmpty || options.only.contains($0.id) }
    let unknown = options.only.subtracting(BenchCase.all.map(\.id))
    guard unknown.isEmpty, !cases.isEmpty else {
      note("No such case: \(unknown.sorted().joined(separator: ", ")). Cases: \(BenchCase.all.map(\.id).joined(separator: ", "))")
      return 2
    }
    // Each case sets Think itself; the first one's setting saves a reseed after the load.
    settings.think = cases[0].think
    settings.thinkingBudget = cases[0].thinkingBudget
    let session: Session
    do {
      session = try Session(settings)
    } catch {
      note("The chat store didn't open: \(error)")
      return 1
    }
    var bench = Bench(session: session, options: options)
    let stop = StopSignal { session.appState.stop() }
    defer { stop.cancel() }
    return await bench.run(cases, paths: paths)
  }

  mutating func run(_ cases: [BenchCase], paths: [String: String]) async -> Int32 {
    try? FileManager.default.createDirectory(
      atPath: (options.out as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    if let level = options.telemetryLevel { EngineProbe.level = level }
    let cacheFolder = paths["engineCache"] ?? ""
    cache = ((try? FileManager.default.contentsOfDirectory(atPath: cacheFolder)) ?? []).isEmpty ? "cold" : "warm"
    let started = ContinuousClock.now
    guard await session.load() else {
      note("The model didn't load: \(session.appState.engineState)")
      return 1
    }
    loadSeconds = (ContinuousClock.now - started) / .seconds(1)
    // The level the load left (it raises a lower one to 2, where the app's reply stats come from).
    if let level = options.telemetryLevel, level > EngineProbe.level { EngineProbe.level = level }
    writeSidecar(paths: paths, cases: cases)
    note(String(format: "Loaded in %.1f s (%@ cache), window %d, run %@ → %@", loadSeconds, cache,
      session.appState.resolved?.maxNumTokens ?? 0, run, options.out))

    if options.warmup {
      let warm = BenchCase(id: "warmup", prompt: Self.warmupPrompt, think: false)
      await run(warm, repetition: 0, warmup: true)
    }
    for repetition in 1...options.repeats {
      for bench in cases {
        await run(bench, repetition: repetition, warmup: false)
      }
    }
    await session.unload()
    note(problems == 0 ? "Done: \(options.out)" : "Done with \(problems) turn(s) that didn't end by themselves: \(options.out)")
    return problems == 0 ? 0 : 1
  }

  private mutating func run(_ bench: BenchCase, repetition: Int, warmup: Bool) async {
    let appState = session.appState
    // Think and its budget, as the driver sets them on the phone before each case.
    var changed = appState.options
    changed.enableThinking = bench.think
    if let budget = bench.thinkingBudget { changed.thinkingBudget = budget }
    if changed != appState.options {
      appState.options = changed
      await appState.applyCurrentOptions()
    }
    let thread = session.newThread()
    let files = SampleDocuments.named(in: bench.launchArguments).map { [$0] } ?? []
    for (index, prompt) in ([bench.prompt] + bench.followUps).enumerated() {
      let id = index == 0 ? bench.id : "\(bench.id)/\(index + 1)"
      let before = Machine.state()
      EngineProbe.reset()
      let limit = options.caseTimeout ?? bench.timeout
      let timedOut = Task { @MainActor in
        try await Task.sleep(for: .seconds(limit))
        appState.stop()
        return true
      }
      let exchange = await session.ask(
        prompt, search: bench.search && index == 0, files: index == 0 ? files : [], in: thread
      ) { _ in }
      timedOut.cancel()
      let ranOut = (try? await timedOut.value) ?? false
      // The engine's account of this turn alone, before the helpers add theirs.
      let telemetry = EngineProbe.snapshot()
      let totals = RuntimeTelemetry.totals()
      if options.helpers { await session.runHelpers() }
      var record = record(id: id, bench: bench, exchange: exchange, repetition: repetition, warmup: warmup)
      record["prompt"] = prompt
      record["telemetry"] = telemetry ?? NSNull()
      if let totals, totals.prefillMilliseconds > 0 {
        record["prefillTPS"] = Double(totals.tokensPrefilled) / (totals.prefillMilliseconds / 1000)
      }
      record["timeout"] = ranOut
      record["load"] = ["before": before, "after": Machine.state()]
      if let level = options.telemetryLevel, level >= 3, let trace = exchange.tracePath {
        let path = (trace as NSString).deletingPathExtension + ".engine.json"
        if EngineProbe.writeTrace(to: path) { record["engineTrace"] = path }
      }
      append(record)
      let ended = record["ended"] as? String ?? "?"
      if !warmup, ended != "model" { problems += 1 }
      note(String(
        format: "%@ %d/%d: %d tokens, %.1f tok/s, first token %.2f s, %.1f s, ended %@",
        id, repetition, options.repeats, record["decode"] as? Int ?? 0, record["decodeTPS"] as? Double ?? 0,
        record["ttft"] as? Double ?? 0, exchange.seconds, ended))
      guard exchange.accepted, appState.generationError == nil else { break }
    }
  }

  private func record(
    id: String, bench: BenchCase, exchange: Session.Exchange, repetition: Int, warmup: Bool
  ) -> [String: Any] {
    let appState = session.appState
    let stats = exchange.reply?.stats
    let resolved = appState.resolved
    let trace = exchange.tracePath.flatMap { FileManager.default.contents(atPath: $0) }
      .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    let footprint = Machine.footprint()
    let options = appState.options
    var record: [String: Any] = [
      "schema": 1, "kind": "app-reply", "id": id, "label": self.options.label, "run": run,
      "rep": repetition, "warmup": warmup,
      // agello-bench's keys.
      "backend": (resolved?.backendLabel ?? "?").lowercased(), "activation": "default",
      "model": appState.store.activeSpec.fileName, "sentences": 0, "late": false, "seed": 0,
      "prefill": stats?.inputTokens ?? 0, "decode": stats?.outputTokens ?? 0,
      "output": exchange.reply?.text ?? "", "seconds": exchange.seconds,
      "mtp": resolved?.enableSpeculativeDecoding ?? false,
      "prefillTPS": 0.0, "decodeTPS": stats?.decodeTokensPerSecond ?? 0,
      "kv": resolved?.maxNumTokens ?? 0, "ttft": stats?.timeToFirstToken ?? 0,
      "thermal": ProcessInfo.processInfo.thermalState.label,
      "footprintMB": Double(footprint.bytes) / 1e6, "peakFootprintMB": Double(footprint.peakBytes) / 1e6,
      "loadSeconds": loadSeconds, "cache": cache, "machine": Machine.record,
      // What the app knows.
      "thought": exchange.reply?.thought ?? "",
      "accepted": exchange.accepted,
      "ended": trace?["ended"] ?? (exchange.accepted ? "unknown" : "refused"),
      "error": appState.generationError ?? NSNull(), "notice": appState.notice ?? NSNull(),
      "reachedLimit": stats?.reachedLimit ?? false,
      "sources": exchange.reply?.parts.sources.count ?? 0,
      "trace": exchange.tracePath ?? NSNull(),
      "settings": [
        "think": options.enableThinking, "thinkingBudget": options.thinkingBudget,
        "search": bench.search, "tools": appState.enableTools,
        "sampler": options.samplerPreset.rawValue,
        "memoryLimitGB": MemoryProbe.appMemoryLimitBytes().map { Double($0) / 1e9 } ?? NSNull(),
        "telemetryLevel": Int(EngineProbe.level),
        "environment": ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("AGELLO_") },
      ],
    ]
    // The step the phone's traces are compared on: what reached the engine.
    if let events = trace?["events"] as? [[String: Any]],
      let send = events.first(where: { $0["name"] as? String == "engine send" })
    {
      record["engineSend"] = send.filter { !["name", "seconds", "footprintGB", "availableGB"].contains($0.key) }
    }
    return record
  }

  private func append(_ record: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return }
    let line = data + Data("\n".utf8)
    if let handle = FileHandle(forWritingAtPath: options.out) {
      handle.seekToEndOfFile()
      handle.write(line)
      try? handle.close()
    } else {
      FileManager.default.createFile(atPath: options.out, contents: line)
    }
  }

  /// What the run was, beside its records: the options, the machine, the cases asked for.
  private func writeSidecar(paths: [String: String], cases: [BenchCase]) {
    let sidecar: [String: Any] = [
      "run": run, "label": options.label, "started": ISO8601DateFormatter().string(from: Date()),
      "cases": cases.map(\.id), "repeat": options.repeats, "warmup": options.warmup,
      "environment": Machine.environment(paths: paths), "loadSeconds": loadSeconds, "cache": cache,
      "arguments": Array(CommandLine.arguments.dropFirst()),
    ]
    let path = (options.out as NSString).deletingPathExtension + ".\(run).run.json"
    try? jsonText(sidecar).write(toFile: path, atomically: true, encoding: .utf8)
  }
}
