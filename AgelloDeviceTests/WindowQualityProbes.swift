import Foundation
import LiteRTLM
import XCTest

@testable import Agello

/// The 64K window's quality gates (PERFORMANCE.md, "Quality gates at 64K"), on a lab model file in
/// Documents/lab and a raw greedy engine, so the app's budgets and prompts stay out of the way.
///
/// - `WINDOW_MODEL`: the model file in Documents/lab, e.g. `w128k/gemma-4-E4B-it-fp16-rope.litertlm`.
/// - `WINDOW_KV`: the window (maxNumTokens), default 65,536.
extension ProbeScenarioTests {
  /// Probe 27: the needle table. At each size, crate records with 18 unique names spread from 3 %
  /// to 97 % depth, read once with the first question; then each other name is asked in its own
  /// follow-up in the same conversation. The gate is 15 of 18 found at every size.
  ///
  /// - `NEEDLE_SIZES`: prompt sizes in tokens, default `21000,32000,44000,50000,57000`.
  func test27_NeedleTable() async throws {
    let env = ProcessInfo.processInfo.environment
    let (model, kv) = try Self.windowModel(env)
    let sizes = (env["NEEDLE_SIZES"] ?? "21000,32000,44000,50000,57000")
      .split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    await appState.engine.unload()
    ExperimentalFlags.optIntoExperimentalAPIs()
    let speculative = ExperimentalFlags.enableSpeculativeDecoding
    ExperimentalFlags.enableSpeculativeDecoding = true  // as in the app's chats
    defer { ExperimentalFlags.enableSpeculativeDecoding = speculative }
    let engine = Engine(
      engineConfig: try EngineConfig(
        modelPath: model.path, backend: .gpu, maxNumTokens: kv, cacheDir: EngineCache.disabled))
    try await engine.initialize()
    var results: [[String: Any]] = []
    for size in sizes {
      let table = Self.needleRecords(tokens: size, seed: UInt64(size))
      let started = Date()
      let run = try await Self.askEach(engine: engine, records: table.records, needles: table.needles)
      let found = run.rows.filter(\.found).count
      results.append([
        "tokens": size, "prefill": run.prefill, "kv": kv, "found": found, "of": table.needles.count,
        "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10,
        "rows": run.rows.map {
          ["name": $0.name, "depth": $0.depth, "expected": $0.expected, "reply": $0.reply, "found": $0.found]
        },
      ])
      harness.record("probe27_needleTable", ["model": model.lastPathComponent, "results": results], in: self)
      let misses = run.rows.filter { !$0.found }.map { "\($0.name)@\($0.depth)%: \($0.reply)" }
      print("probe27 \(size) (prefill \(run.prefill)) at \(kv): \(found)/\(table.needles.count); missed \(misses)")
    }
    for result in results {
      XCTAssertGreaterThanOrEqual(result["found"] as? Int ?? 0, 15, "needles at \(result["tokens"] ?? "")")
    }
  }

  /// Probe 28: 48-digit copies at exact positions. The reference at depths 0–95 % of a 57,000-token
  /// prompt; the reference, then the reply, across position 32,768; and replies whose digits fill
  /// the window's last positions (to 65,534, the end token at 65,535). Prompts are sized with the
  /// engine's tokenizer, so the positions are the runtime's own. Every copy must be exact.
  ///
  /// - `WINDOW_CASES`: names to run (comma-separated prefixes), default all.
  func test28_WindowPositions() async throws {
    let env = ProcessInfo.processInfo.environment
    let (model, kv) = try Self.windowModel(env)
    let filter = env["WINDOW_CASES"]?.split(separator: ",").map(String.init)
    var cases: [PositionCase] = [0, 10, 25, 50, 75, 90, 95].enumerated().map { index, percent in
      PositionCase(
        name: "depth\(percent)-57000", seed: 11 + index, depth: Double(percent) / 100, metric: .prefill,
        target: 57_000)
    }
    cases += [
      PositionCase(name: "reference-across-32768", seed: 21, depth: 1, metric: .reference, target: 32_744),
      PositionCase(name: "reply-across-32768-late", seed: 22, depth: 1, metric: .prefill, target: 32_744),
      PositionCase(name: "reply-across-32768-early", seed: 23, depth: 0, metric: .prefill, target: 32_744),
      PositionCase(name: "window-end-late", seed: 24, depth: 1, metric: .prefill, target: kv - 49),
      PositionCase(name: "window-end-early", seed: 25, depth: 0, metric: .prefill, target: kv - 49),
    ]
    if let filter { cases = cases.filter { item in filter.contains { item.name.hasPrefix($0) } } }
    await appState.engine.unload()
    ExperimentalFlags.optIntoExperimentalAPIs()
    let speculative = ExperimentalFlags.enableSpeculativeDecoding
    // No speculative rounds: a verify round past the reply would run beyond the window's end.
    ExperimentalFlags.enableSpeculativeDecoding = false
    defer { ExperimentalFlags.enableSpeculativeDecoding = speculative }
    let engine = Engine(
      engineConfig: try EngineConfig(
        modelPath: model.path, backend: .gpu, maxNumTokens: kv, cacheDir: EngineCache.disabled))
    try await engine.initialize()
    var results: [[String: Any]] = []
    for item in cases {
      let started = Date()
      let run = try await Self.positionedCopy(engine: engine, kv: kv, item: item)
      results.append([
        "name": item.name, "depth": item.depth, "target": item.target, "prefill": run.prefill,
        "referencePosition": run.reference, "maxOutput": run.maxOutput, "cachedAfter": run.cachedAfter,
        "exact": run.copy.firstMismatch == nil, "firstMismatch": run.copy.firstMismatch ?? -1,
        "expected": run.copy.expected, "output": run.copy.output,
        "seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10,
      ])
      harness.record("probe28_windowPositions", ["model": model.lastPathComponent, "kv": kv, "results": results], in: self)
      print(
        "probe28 \(item.name): prefill \(run.prefill), reference at \(run.reference), cached after \(run.cachedAfter): \(run.copy.summary)"
      )
    }
    for result in results {
      XCTAssertEqual(result["exact"] as? Bool, true, "\(result["name"] ?? ""): \(result["output"] ?? "")")
    }
  }

  /// Probe 29: the history probe. Ten facts, each told in its own turn after about 5,000 tokens
  /// of prose, so the chat's history grows past 50,000 tokens; then each fact asked in a
  /// follow-up of the same conversation (greedy). The gate is all ten recalled.
  ///
  /// - `HISTORY_SENTENCES`: prose sentences per turn, default 330 (about 5,200 tokens).
  func test29_HistoryFacts() async throws {
    let env = ProcessInfo.processInfo.environment
    let (model, kv) = try Self.windowModel(env)
    let sentences = Int(env["HISTORY_SENTENCES"] ?? "") ?? 330
    await appState.engine.unload()
    ExperimentalFlags.optIntoExperimentalAPIs()
    let speculative = ExperimentalFlags.enableSpeculativeDecoding
    ExperimentalFlags.enableSpeculativeDecoding = true  // as in the app's chats
    defer { ExperimentalFlags.enableSpeculativeDecoding = speculative }
    let engine = Engine(
      engineConfig: try EngineConfig(
        modelPath: model.path, backend: .gpu, maxNumTokens: kv, cacheDir: EngineCache.disabled))
    try await engine.initialize()
    let run = try await Self.historyRun(engine: engine, sentences: sentences)
    let recalled = run.rows.filter(\.found).count
    harness.record(
      "probe29_historyFacts",
      [
        "model": model.lastPathComponent, "kv": kv, "sentences": sentences, "historyTokens": run.historyTokens,
        "finalTokens": run.finalTokens, "recalled": recalled,
        "rows": run.rows.map { ["question": $0.question, "expected": $0.expected, "reply": $0.reply, "found": $0.found] },
      ], in: self)
    let misses = run.rows.filter { !$0.found }.map { "\($0.question) → \($0.reply)" }
    print("probe29 history \(run.historyTokens) tokens, \(recalled)/10 recalled; missed \(misses)")
    XCTAssertEqual(recalled, run.rows.count, "\(misses)")
  }

  nonisolated static let historyFacts: [(fact: String, question: String, answer: String)] = [
    ("My locker code at the swimming pool is 4417.", "What is my locker code at the swimming pool?", "4417"),
    ("My cousin Odalys moved to Tromsø last spring.", "Which city did my cousin Odalys move to?", "Troms"),
    ("The ferry to Brindle Island leaves at 7:45.", "When does the ferry to Brindle Island leave?", "7:45"),
    ("My bicycle is a green Vellacorte with a wicker basket.", "What brand is my bicycle?", "Vellacorte"),
    ("The book club meets on Thursdays at the Larkspur café.", "Where does the book club meet?", "Larkspur"),
    ("My dentist is Dr. Okonkwo-Lindqvist.", "What is my dentist's name?", "Okonkwo"),
    ("My neighbour's parrot is called Brigadier Pip.", "What is my neighbour's parrot called?", "Brigadier"),
    ("I keep the spare key under the blue heron statue.", "Where do I keep the spare key?", "heron"),
    ("My flight number to Lisbon is TP 1953.", "What is my flight number to Lisbon?", "1953"),
    ("The wifi password at the cabin is marmalade-otter.", "What is the wifi password at the cabin?", "marmalade-otter"),
  ]

  struct HistoryRow: Sendable {
    let question: String
    let expected: String
    let reply: String
    let found: Bool
  }

  nonisolated static func historyRun(engine: Engine, sentences: Int) async throws
    -> (historyTokens: Int, finalTokens: Int, rows: [HistoryRow])
  {
    let conversation = try await engine.createConversation(
      with: ConversationConfig(samplerConfig: try SamplerConfig(topK: 1, topP: 1, temperature: 0)))
    let prose = filler(sentences: sentences)
    for item in historyFacts {
      let message = prose + "\n\nAlso, remember this for later: \(item.fact) For now, reply only with OK."
      _ = try await conversation.sendMessage(LiteRTLM.Message(message), maxOutputTokens: 8)
    }
    let historyTokens = try conversation.getTokenCount()
    var rows: [HistoryRow] = []
    for item in historyFacts {
      let reply = try await conversation.sendMessage(
        LiteRTLM.Message(item.question + " Answer in a few words."), maxOutputTokens: 24
      ).toString
      rows.append(
        HistoryRow(
          question: item.question, expected: item.answer, reply: String(reply.prefix(120)),
          found: reply.localizedCaseInsensitiveContains(item.answer)))
    }
    return (historyTokens, try conversation.getTokenCount(), rows)
  }

  /// Probe 30: identity at 32K and below between two windows of the same file: prose prompts
  /// (short, and about 2K, 10K and 24K tokens) answered greedily with the app's system prompt,
  /// at 32,768 and at 65,536 positions. The replies must be the same text.
  ///
  /// - `WINDOW_SMALL_KV`: the smaller window, default 32,768.
  /// - `WINDOW_MTP=0`: without speculative decoding (on by default, as in the app's chats).
  func test30_WindowIdentity() async throws {
    let env = ProcessInfo.processInfo.environment
    let (model, kv) = try Self.windowModel(env)
    let small = Int(env["WINDOW_SMALL_KV"] ?? "") ?? 32_768
    await appState.engine.unload()
    ExperimentalFlags.optIntoExperimentalAPIs()
    let speculative = ExperimentalFlags.enableSpeculativeDecoding
    ExperimentalFlags.enableSpeculativeDecoding = env["WINDOW_MTP"] != "0"
    defer { ExperimentalFlags.enableSpeculativeDecoding = speculative }
    let prompts = Self.identityPrompts
    let atSmall = try await Self.greedyReplies(model: model, kv: small, prompts: prompts)
    let atLarge = try await Self.greedyReplies(model: model, kv: kv, prompts: prompts)
    let rows = zip(atSmall, atLarge).enumerated().map { index, pair in
      ["prompt": index, "small": pair.0, "large": pair.1, "identical": pair.0 == pair.1] as [String: Any]
    }
    harness.record(
      "probe30_windowIdentity",
      ["model": model.lastPathComponent, "small": small, "large": kv, "mtp": env["WINDOW_MTP"] != "0", "rows": rows],
      in: self)
    for (index, pair) in zip(atSmall, atLarge).enumerated() {
      print("probe30 prompt \(index): \(pair.0 == pair.1 ? "identical" : "DIFFERENT")")
      XCTAssertEqual(pair.0, pair.1, "prompt \(index)")
    }
  }

  /// Probe 30's prompts: short, and about 2K, 10K and 24K tokens.
  nonisolated static var identityPrompts: [String] {
    [
      "Explain how a heat pump works, in three short paragraphs.",
      filler(sentences: 120) + "\n\nSummarize the notes above in five bullet points.",
      filler(sentences: 640) + "\n\nWhat do the notes above say about fog? Answer in two sentences.",
      filler(sentences: 1_500) + "\n\nList three things the volunteers did, according to the notes.",
    ]
  }

  /// Probe 31: probe 30's prompts at one window per process, so the runtime's dumps
  /// (`AGELLO_TELEMETRY_GRAPH_DIR`, `AGELLO_TELEMETRY_LOGITS_OUT`) belong to that window alone.
  /// The replies go to the report and, with `WINDOW_REPLIES_OUT`, to a JSON file.
  ///
  /// - `WINDOW_PROMPTS`: which prompts, by index (default all).
  /// - `WINDOW_MTP=0`: without speculative decoding.
  /// - `WINDOW_FP32=1`: float32 activations, the reference for rounding.
  func test31_WindowReplies() async throws {
    let env = ProcessInfo.processInfo.environment
    let (model, kv) = try Self.windowModel(env)
    let all = Self.identityPrompts
    let indices = env["WINDOW_PROMPTS"]?.split(separator: ",").compactMap { Int($0) } ?? Array(all.indices)
    await appState.engine.unload()
    ExperimentalFlags.optIntoExperimentalAPIs()
    let speculative = ExperimentalFlags.enableSpeculativeDecoding
    ExperimentalFlags.enableSpeculativeDecoding = env["WINDOW_MTP"] != "0"
    defer { ExperimentalFlags.enableSpeculativeDecoding = speculative }
    let fp32 = env["WINDOW_FP32"] == "1"
    let replies = try await Self.greedyReplies(
      model: model, kv: kv, prompts: indices.map { all[$0] }, fp32: fp32)
    let record: [String: Any] = [
      "model": model.lastPathComponent, "kv": kv, "mtp": env["WINDOW_MTP"] != "0", "fp32": fp32, "prompts": indices,
      "replies": replies,
    ]
    harness.record("probe31_windowReplies", record, in: self)
    if let path = env["WINDOW_REPLIES_OUT"] {
      try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: path))
    }
  }

  /// Each prompt in a conversation of its own on a new engine of `kv` positions, released after.
  nonisolated static func greedyReplies(model: URL, kv: Int, prompts: [String], fp32: Bool = false)
    async throws -> [String]
  {
    let engine = Engine(
      engineConfig: try EngineConfig(
        modelPath: model.path, backend: .gpu, maxNumTokens: kv, cacheDir: EngineCache.disabled,
        activationDataType: fp32 ? .float32 : nil))
    try await engine.initialize()
    var replies: [String] = []
    for prompt in prompts { replies.append(try await greedyWhole(engine: engine, prompt: prompt, maxOutputTokens: 200)) }
    return replies
  }

  // MARK: - Helpers

  static func windowModel(_ env: [String: String]) throws -> (URL, Int) {
    guard let file = env["WINDOW_MODEL"] else { throw XCTSkip("Set WINDOW_MODEL") }
    let lab = try FileManager.default.url(
      for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("lab", isDirectory: true)
    let model = lab.appendingPathComponent(file)
    guard FileManager.default.fileExists(atPath: model.path) else {
      throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: model.path])
    }
    return (model, Int(env["WINDOW_KV"] ?? "") ?? 65_536)
  }

  /// The 18 names, each placed once.
  static let needleNames = [
    "Zephyrine", "Quillon", "Marisol", "Thaddeus", "Ysolde", "Bartholomew", "Esmeralda", "Cornelius",
    "Philippa", "Leopold", "Rosalind", "Ignatius", "Seraphina", "Montgomery", "Wilhelmina", "Octavius",
    "Genevieve", "Barnaby",
  ]

  /// About `tokens` tokens of crate records (about 21 tokens each, as in probe 24), with the 18
  /// names spread evenly from 3 % to 97 % depth. Their crates are five digits, the others four.
  static func needleRecords(tokens: Int, seed: UInt64)
    -> (records: String, needles: [Needle])
  {
    var state = seed &+ 0x9E37_79B9_7F4A_7C15
    func next(_ bound: Int) -> Int {
      state = state &+ 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return Int((z ^ (z >> 31)) % UInt64(bound))
    }
    let names = ["Gita", "Ines", "Bram", "Jun", "Odile", "Tariq", "Mira", "Lev", "Ana", "Kofi"]
    let count = max(60, tokens / 21)
    var placements: [Int: Int] = [:]
    for k in needleNames.indices {
      placements[count * (3 + (94 * k) / (needleNames.count - 1)) / 100] = k
    }
    var lines: [String] = []
    var needles: [Needle] = []
    for i in 0..<count {
      if let k = placements[i] {
        let crate = 10_000 + next(89_999)
        needles.append(Needle(name: needleNames[k], crate: String(crate), depth: 100 * i / count))
        lines.append("(\(i + 1)) \(needleNames[k]) stored crate number \(crate) in aisle \(1 + next(40)).")
      }
      lines.append(
        "(\(i + 1)) \(names[next(names.count)]) stored crate number \(1_000 + next(8_999)) in aisle \(1 + next(40)).")
    }
    return ("Warehouse log:\n" + lines.joined(separator: "\n"), needles)
  }

  struct Needle: Sendable {
    let name: String
    let crate: String
    let depth: Int
  }

  struct NeedleRow: Sendable {
    let name: String
    let depth: Int
    let expected: String
    let reply: String
    let found: Bool
  }

  /// The records read once with the first question, then each other name asked in turn.
  nonisolated static func askEach(engine: Engine, records: String, needles: [Needle]) async throws
    -> (prefill: Int, rows: [NeedleRow])
  {
    let conversation = try await engine.createConversation(
      with: ConversationConfig(samplerConfig: try SamplerConfig(topK: 1, topP: 1, temperature: 0)))
    var prefill = 0
    var rows: [NeedleRow] = []
    for (index, needle) in needles.enumerated() {
      let question = "Which crate number did \(needle.name) store? Answer with the number only."
      let message = index == 0 ? records + "\n\n" + question : question
      let reply = try await conversation.sendMessage(LiteRTLM.Message(message), maxOutputTokens: 24).toString
      if index == 0 { prefill = try conversation.getTokenCount() }
      rows.append(
        NeedleRow(
          name: needle.name, depth: needle.depth, expected: needle.crate, reply: String(reply.prefix(80)),
          found: reply.contains(needle.crate)))
    }
    return (prefill, rows)
  }

  struct PositionCase: Sendable {
    let name: String
    let seed: Int
    /// Where the reference sits in the filler: 0 before it, 1 after it.
    let depth: Double
    /// What `target` places: the prompt's length, or the reference's first digit.
    let metric: PositionMetric
    let target: Int
  }

  struct PositionRun: Sendable {
    let prefill: Int
    let reference: Int
    let maxOutput: Int
    let cachedAfter: Int
    let copy: CopyRun
  }

  /// A digit copy sized so that `item.metric` lands exactly on `item.target`: whole filler
  /// sentences first, then one-token words.
  nonisolated static func positionedCopy(engine: Engine, kv: Int, item: PositionCase) async throws -> PositionRun {
    let digits = referenceDigits(seed: item.seed)
    let conversation = try await engine.createConversation(
      with: ConversationConfig(samplerConfig: try SamplerConfig(topK: 1, topP: 1, temperature: 0)))
    func prompt(_ total: Int, _ pad: Int) -> String {
      let before = Int((Double(total) * item.depth).rounded())
      let padding = String(repeating: " so", count: pad)
      let reference = "REFERENCE: \(digits)"
      var parts: [String] = []
      if before > 0 { parts.append(filler(sentences: before) + padding) }
      parts.append(reference)
      if total - before > 0 { parts.append(filler(sentences: total - before) + (before > 0 ? "" : padding)) }
      return parts.joined(separator: "\n\n")
        + "\n\nCopy the REFERENCE number exactly, digit for digit. Reply with only the digits."
    }
    func measure(_ text: String) async throws -> (prefill: Int, reference: Int) {
      let rendered = try conversation.renderMessageIntoString(LiteRTLM.Message(text))
      guard let start = rendered.range(of: "REFERENCE: ")?.upperBound else { return (0, 0) }
      // The first send adds BOS, which the rendered text doesn't show.
      let prefill = try await engine.countTokens(rendered) + 1
      return (prefill, try await engine.countTokens(String(rendered[..<start])) + 1)
    }
    func value(_ total: Int, _ pad: Int) async throws -> Int {
      let measured = try await measure(prompt(total, pad))
      return item.metric == .prefill ? measured.prefill : measured.reference
    }
    let perSentence = 15.73 * (item.metric == .prefill ? 1 : max(item.depth, 0.05))
    var total = max(1, Int(Double(item.target - 100) / perSentence))
    for _ in 0..<8 {
      let step = Int(Double(item.target - (try await value(total, 0))) / perSentence)
      if step == 0 { break }
      total = max(1, total + step)
    }
    while try await value(total, 0) > item.target, total > 1 { total -= 1 }
    var pad = 0
    while pad < 64, try await value(total, pad + 1) <= item.target { pad += 1 }
    let text = prompt(total, pad)
    let measured = try await measure(text)
    let maxOutput = min(80, kv - measured.prefill)
    let reply = try await conversation.sendMessage(LiteRTLM.Message(text), maxOutputTokens: maxOutput)
    let copy = CopyRun(expected: digits, output: reply.toString, prefill: measured.prefill, decode: 0)
    return PositionRun(
      prefill: measured.prefill, reference: measured.reference, maxOutput: maxOutput,
      cachedAfter: try conversation.getTokenCount(), copy: copy)
  }
}

/// What a ``ProbeScenarioTests/PositionCase`` places at its target.
enum PositionMetric: Sendable { case prefill, reference }
