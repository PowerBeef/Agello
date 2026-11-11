import Foundation
import SwiftData

/// One run of the app's engine without its interface: the same ``AppState``, set up as a fresh
/// install has it and sent to as the chat screen sends (`ChatView.send()`), so a prompt takes
/// the path it takes on the phone. Chats live in memory and nothing of the app's is touched.
@MainActor
final class Session {
  struct Settings {
    var mock = false
    var think = false
    var thinkingBudget: Int?
    var tools = true
    var windowTokens: Int?
    var speculativeDecoding = true
    var sampler: SamplerPreset?

    /// From `ask`'s options; throws what to tell the user when one doesn't read.
    init(_ arguments: inout Arguments) throws(UsageError) {
      mock = arguments.flag("mock")
      let think = arguments.think()
      self.think = think.given && !arguments.flag("no-think")
      thinkingBudget = think.budget
      tools = !arguments.flag("no-tools")
      windowTokens = arguments.value("kv").flatMap(Int.init)
      speculativeDecoding = !arguments.flag("no-mtp")
      if let name = arguments.value("sampler") {
        guard let preset = SamplerPreset(rawValue: name) else {
          throw UsageError("--sampler takes precise, balanced or creative.")
        }
        sampler = preset
      }
    }
  }

  /// What one message came back as.
  struct Exchange {
    var accepted: Bool
    var reply: ChatTurn?
    var seconds: Double
    var tracePath: String?
  }

  let container: ModelContainer
  let appState: AppState

  /// The settings a launch reads: cleared, so each run starts as a fresh install.
  private static let defaultsKeys = [
    "inferenceOptions", "enableTools", "selectedThreadID", "benchmarkReport", "memoryEnabled",
    "personalization", "webSearch",
  ]

  init(_ settings: Settings) throws {
    for key in Self.defaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
    // A command line has nothing to put in Spotlight.
    UserDefaults.standard.set(false, forKey: SpotlightIndex.enabledKey)
    container = try ModelContainer(
      for: ChatStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    appState = AppState(useMockEngine: settings.mock)
    appState.modelContext = container.mainContext
    var options = InferenceOptions.launch(saved: nil)
    options.enableThinking = settings.think
    if let budget = settings.thinkingBudget { options.thinkingBudget = budget }
    options.enableSpeculativeDecoding = settings.speculativeDecoding
    options.maxNumTokensOverride = settings.windowTokens
    if let sampler = settings.sampler { options.samplerPreset = sampler }
    appState.options = options
    appState.enableTools = settings.tools
    appState.webSettings = WebSearchSettings()
  }

  /// Loads the model (the scripted engine needs none). False with the reason in `engineState`.
  func load() async -> Bool {
    await appState.ensureEngineLoaded()
  }

  func newThread() -> ChatThread {
    appState.newThread(in: container.mainContext)
  }

  /// Sends `prompt` and waits for the whole reply. `onText` gets the answer as it grows, at the
  /// pace the chat screen sees it (the app writes streamed text into the turn every 100 ms).
  func ask(
    _ prompt: String, search: Bool, files: [ExtractedDocument] = [], image: Data? = nil, audio: URL? = nil,
    in thread: ChatThread, onText: @escaping @MainActor (String) -> Void
  ) async -> Exchange {
    // Files belong to the chat from the send on and index in the background, as in the app.
    let documents = files.compactMap { appState.knowledge.add($0, threadID: thread.id) }
    let records = documents.map {
      FileRecord(id: $0.id, name: $0.name, kind: $0.kindRaw, pageCount: $0.pageCount)
    }
    let exchange = await exchange(in: thread, onText: onText) {
      await self.appState.send(
        text: prompt, imageData: image, audioFileURL: audio, files: records, webSearch: search, in: thread)
    }
    if !exchange.accepted {
      for document in documents { appState.knowledge.delete(document) }
    }
    return exchange
  }

  /// Answers `reply`'s prompt again, as the Regenerate button does: sampled, without
  /// speculative decoding, here with a fixed `seed` so a run can be repeated.
  func regenerate(_ reply: ChatTurn, in thread: ChatThread, seed: Int) async -> Exchange {
    await exchange(in: thread, onText: { _ in }, perform: {
      await self.appState.regenerate(reply, in: thread, seed: seed)
    })
  }

  /// Runs one send and gathers what came back: the new reply turn, the time, the trace file.
  private func exchange(
    in thread: ChatThread, onText: @escaping @MainActor (String) -> Void,
    perform: @MainActor () async -> Bool
  ) async -> Exchange {
    let earlier = Set(thread.turns.map(\.id))
    let tracesBefore = Self.traceFiles()
    let started = ContinuousClock.now
    let watcher = Task { @MainActor in
      var shown = ""
      while true {
        if let reply = thread.orderedTurns.last(where: { !$0.isUser && !earlier.contains($0.id) }),
          reply.text != shown
        {
          let text = reply.text
          onText(text.hasPrefix(shown) ? String(text.dropFirst(shown.count)) : "\n" + text)
          shown = text
        }
        if Task.isCancelled { return }
        try? await Task.sleep(for: .milliseconds(100))
      }
    }
    let accepted = await perform()
    watcher.cancel()
    await watcher.value
    let seconds = (ContinuousClock.now - started) / .seconds(1)
    let reply = thread.orderedTurns.last { !$0.isUser && !earlier.contains($0.id) }
    let trace = Self.traceFiles().subtracting(tracesBefore).max()
    return Exchange(accepted: accepted, reply: reply, seconds: seconds, tracePath: trace)
  }

  /// `text` as the model's tokenizer encodes it (nil on the scripted engine).
  func tokenIDs(_ text: String) async -> [Int]? {
    await (appState.engine as? LiteRTChatEngine)?.tokenIDs(text)
  }

  /// The title and memory helpers the app runs a few seconds after a reply, run now.
  func runHelpers() async {
    await appState.runPendingHelpers()
  }

  func unload() async {
    await appState.engine.unload()
  }

  private static func traceFiles() -> Set<String> {
    guard let folder = try? ReplyTrace.directory() else { return [] }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return Set(names.filter { $0.hasSuffix(".json") }.map { folder.appendingPathComponent($0).path })
  }
}
