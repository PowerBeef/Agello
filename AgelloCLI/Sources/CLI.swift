import Foundation

/// `agello`: Agello's engine from a command line on a Mac (docs/CLI.md). A development tool for
/// working on the runtime, built with SwiftPM against the runtime of your choice; the app's own
/// code decides everything it decides on the phone.
@main
struct AgelloCommand {
  static let usage = """
    Usage:
      agello env                      this Mac, the runtime build, the models and folders in use
      agello ask "prompt" [options]   one message through the app's engine; the reply on stdout
      agello bench [options]          the iPhone bench's cases through the app's engine, one record per reply

    Options for ask:
      --mock                 the scripted engine: no model, no GPU
      --think[=N]            Think on, with a reasoning budget of N tokens (default 4096)
      --search               Search on for this message
      --no-tools             without the on-device tools
      --kv N                 a window of N tokens instead of the one memory allows
      --backend gpu|cpu      (default gpu)
      --no-mtp               without speculative decoding
      --sampler precise|balanced|creative
      --file PATH            attach a file (PDF, text, image of a page); may be repeated
      --image PATH           attach an image
      --audio PATH           attach a voice message (16 kHz mono WAV, as the app records)
      --follow-up "text"     send this next in the same chat; may be repeated
      --helpers              run the title and memory helpers after the reply
      --show-thought         print the reasoning before the answer
      --json                 one JSON object instead of the streamed reply

    Options for bench (and --mock, --no-tools, --kv, --backend, --no-mtp, --sampler):
      --only id,id           some cases (default: all of AgelloUITests/BenchCases.swift)
      --repeat N             every case N times (default 1)
      --warmup               one short reply first, left out of comparisons
      --label NAME           the build's name in the records (default arm)
      --out FILE.jsonl       where records are appended (default build/cli/runs/<time>-<label>.jsonl);
                             traces go beside it, in FILE.traces/
      --telemetry 0-4        the runtime's telemetry level (3 also writes each reply's event trace)
      --timeout SECONDS      per turn, instead of each case's own
      --no-helpers           skip the title and memory helpers after each reply

    Everywhere:
      --models DIR           the models folder, read only (default ~/Models/agello)
      --cache DIR            the engine cache root (default ~/Models/agello/cache/agello-cli)
      --trace-dir DIR        where reply traces go (default build/cli/traces)
      --memory-limit GB|metal|none   the app memory limit the engine sees (default 8.59, the iPhone 17 Pro's)
      --memory-pressure real pass this Mac's memory-pressure events to the app (default: count them)
      --verbose              show the runtime's log lines (default: appended to build/cli/runtime.log)

    Ctrl-C stops the reply and keeps its text, as the Stop button does; twice quits.
    """

  @MainActor
  static func main() async {
    setvbuf(stdout, nil, _IOLBF, 0)
    var arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
    if arguments.flag("help") {
      print(usage)
      return
    }
    guard let command = arguments.next() else {
      note(usage)
      exit(2)
    }
    let paths = Setup.prepare(&arguments, command: command)
    switch command {
    case "env":
      print(jsonText(Machine.environment(paths: paths)))
    case "ask":
      exit(await ask(&arguments, paths: paths))
    case "bench":
      exit(await Bench.main(&arguments, paths: paths))
    default:
      note("Unknown command: \(command)\n\n\(usage)")
      exit(2)
    }
  }

  @MainActor
  static func ask(_ arguments: inout Arguments, paths: [String: String]) async -> Int32 {
    let settings: Session.Settings
    do {
      settings = try Session.Settings(&arguments)
    } catch {
      note(error.message)
      return 2
    }
    let search = arguments.flag("search")
    let helpers = arguments.flag("helpers")
    let asJSON = arguments.flag("json")
    let showThought = arguments.flag("show-thought")
    let followUps = arguments.values("follow-up")
    let attachments: Attachments
    do {
      attachments = try await Attachments(&arguments)
    } catch {
      note(error.message)
      return 2
    }
    guard let prompt = arguments.next(), arguments.rest.isEmpty else {
      note(arguments.rest.isEmpty ? "ask needs a prompt." : "Not understood: \(arguments.rest.joined(separator: " "))")
      return 2
    }

    let session: Session
    do {
      session = try Session(settings)
    } catch {
      note("The chat store didn't open: \(error)")
      return 1
    }
    let stop = StopSignal { session.appState.stop() }
    defer { stop.cancel() }
    let loadStarted = ContinuousClock.now
    guard await session.load() else {
      note("The model didn't load: \(session.appState.engineState)")
      return 1
    }
    let loadSeconds = (ContinuousClock.now - loadStarted) / .seconds(1)
    let thread = session.newThread()
    var turns: [[String: Any]] = []
    var failed = false
    for (index, text) in ([prompt] + followUps).enumerated() {
      if index > 0, !asJSON { print("\n> \(text)\n") }
      let exchange = await session.ask(
        text, search: search && index == 0, files: index == 0 ? attachments.files : [],
        image: index == 0 ? attachments.image : nil, audio: index == 0 ? attachments.audio : nil, in: thread
      ) { delta in
        if !asJSON { FileHandle.standardOutput.write(Data(delta.utf8)) }
      }
      if helpers { await session.runHelpers() }
      var summary = Self.summary(exchange, appState: session.appState)
      if index == 0 { summary["loadSeconds"] = loadSeconds }
      if asJSON {
        summary["prompt"] = text
        summary["text"] = exchange.reply?.text ?? ""
        summary["thought"] = exchange.reply?.thought ?? ""
        turns.append(summary)
      } else {
        print("")
        if showThought, let thought = exchange.reply?.thought, !thought.isEmpty { note("Reasoning:\n\(thought)\n") }
        note(line(summary))
      }
      failed = failed || !exchange.accepted || session.appState.generationError != nil
      if failed { break }
    }
    if asJSON { print(jsonText(["title": thread.title, "turns": turns])) }
    await session.unload()
    return failed ? 1 : 0
  }

  /// What a reply came back with, for the stats line and the JSON output.
  @MainActor
  static func summary(_ exchange: Session.Exchange, appState: AppState) -> [String: Any] {
    let stats = exchange.reply?.stats
    var summary: [String: Any] = [
      "accepted": exchange.accepted,
      "seconds": exchange.seconds,
      "window": appState.resolved?.maxNumTokens ?? NSNull(),
      "backend": stats?.backend ?? appState.resolved?.backendLabel ?? NSNull(),
      "error": appState.generationError ?? NSNull(),
      "notice": appState.notice ?? NSNull(),
      "trace": exchange.tracePath ?? NSNull(),
      "sources": exchange.reply?.parts.sources.count ?? 0,
      "memoryPressureEvents": MemoryPressureMonitor.events.withLock { $0.warnings },
    ]
    if let stats {
      summary["outputTokens"] = stats.outputTokens ?? NSNull()
      summary["inputTokens"] = stats.inputTokens ?? NSNull()
      summary["decodeTokensPerSecond"] = stats.decodeTokensPerSecond ?? NSNull()
      summary["timeToFirstToken"] = stats.timeToFirstToken ?? NSNull()
      summary["reachedLimit"] = stats.reachedLimit ?? false
    }
    return summary
  }

  /// The stats line under a reply, as the app's "performance details" would give it.
  static func line(_ summary: [String: Any]) -> String {
    func number(_ key: String, _ format: String) -> String? {
      (summary[key] as? Double).map { String(format: format, $0) }
        ?? (summary[key] as? Int).map { String(format: format, Double($0)) }
    }
    var parts: [String] = []
    if let tokens = number("outputTokens", "%.0f tokens") { parts.append(tokens) }
    if let speed = number("decodeTokensPerSecond", "%.1f tok/s") { parts.append(speed) }
    if let first = number("timeToFirstToken", "first token %.2f s") { parts.append(first) }
    if let seconds = number("seconds", "%.1f s") { parts.append(seconds) }
    if let window = number("window", "window %.0f") { parts.append(window) }
    if let backend = summary["backend"] as? String { parts.append(backend) }
    if let load = number("loadSeconds", "load %.1f s") { parts.append(load) }
    if let error = summary["error"] as? String { parts.append("error: \(error)") }
    if let notice = summary["notice"] as? String { parts.append("notice: \(notice)") }
    if let trace = summary["trace"] as? String { parts.append("trace \(trace)") }
    return parts.joined(separator: " · ")
  }
}
