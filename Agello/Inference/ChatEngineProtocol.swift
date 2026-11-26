import Foundation
import LiteRTLMTools

// MARK: - Engine boundary types

enum ChatRole: Sendable {
  case user
  case model
}

enum ChatEvent: Sendable {
  case chunk(ChatChunk)
  case finished(GenerationStats)
}

/// Shared tool registry so live (`LiteRTChatEngine`) and Simulator-bridge (`RemoteChatEngine`)
/// engines expose the exact same Swift tools and schemas.
enum ActiveTools {
  static func make(toolsEnabled: Bool, options: InferenceOptions) -> [any Tool] {
    var tools: [any Tool] = []
    if toolsEnabled {
      tools.append(CurrentDateTimeTool())
      tools.append(CalculatorTool())
      tools.append(ConvertUnitsTool())
      tools.append(SearchPastChatsTool())
      if options.workspaceFileTools {
        tools.append(SearchFilesTool())
        tools.append(ReadDocumentPagesTool())
        tools.append(QueryTableOrJsonTool())
      }
      if options.personalTools.calendar {
        tools.append(ReadCalendarTool())
        tools.append(ManageCalendarEventTool())
      }
      if options.personalTools.reminders {
        tools.append(ListRemindersTool())
        tools.append(ManageReminderTool())
      }
      if options.personalTools.contacts {
        tools.append(SearchContactsTool())
        tools.append(PrepareMessageTool())
      }
      if options.personalTools.maps {
        tools.append(SearchPlacesTool())
        tools.append(EstimateTravelTimeTool())
      }
      if options.personalTools.weather {
        tools.append(GetWeatherTool())
      }
      if options.personalTools.alarms {
        tools.append(ListAlarmsTool())
        tools.append(ManageAlarmTool())
      }
      if options.personalTools.photos {
        tools.append(SearchPhotosTool())
      }
      if !options.shortcutAllowlistKey.isEmpty {
        tools.append(RunShortcutTool())
      }
    }
    if options.webSearchTool { tools.append(WebSearchTool()) }
    return tools
  }
}

protocol ChatEngineProtocol: Sendable {
  /// Whether `load(...)` expects a downloaded model file on disk (false for Mock / Remote engines).
  nonisolated var requiresLocalModelFile: Bool { get }
  /// Human-readable engine label shown in Developer Settings.
  nonisolated var engineDisplayName: String { get }

  /// Load (or reload) a model with the given options. Returns resolved settings.
  func load(
    spec: ModelSpec, modelURL: URL, options: InferenceOptions, memoryBytes: UInt64,
    enableTools: Bool
  ) async throws -> ResolvedInference
  func unload() async
  var isLoaded: Bool { get async }
  var currentModelID: ModelID? { get async }
  /// Whether engine-level settings changed (requires full reload rather than conversation reseed).
  func engineSettingsChanged(for newOptions: InferenceOptions) async -> Bool
  /// Apply conversation-level options (sampler, thinking, tools, system prompt) without reload.
  func updateConversationOptions(
    _ newOptions: InferenceOptions, enableTools: Bool, history: [(role: ChatRole, text: String)]
  ) async throws -> ResolvedInference
  /// Recreate the conversation, re-seeding text history (used after option changes).
  func reseed(history: [(role: ChatRole, text: String)]) async throws
  /// Rebuild the conversation from `history` to sample its next reply (Regenerate): MTP off
  /// (it decodes greedily) and `seed` (every new conversation otherwise starts at 0 and repeats
  /// its reply; probe 18). Kept through `fitContext`; the next `reseed(history:)` or `load` ends it.
  func reseedSampling(history: [(role: ChatRole, text: String)], seed: Int) async throws
  /// Make room in the context window for the next message plus a reply,
  /// replaying a trimmed `history` (the thread's turns before this message)
  /// when needed. Returns true when older turns were dropped.
  /// - Throws: ``ChatError/messageTooLong`` when the message alone can't fit.
  func fitContext(
    text: String, imageData: Data?, audioFileURL: URL?,
    history: [(role: ChatRole, text: String)]
  ) async throws -> Bool
  nonisolated func send(
    text: String, imageData: Data?, audioFileURL: URL?
  ) -> AsyncThrowingStream<ChatEvent, Error>
  func cancel() async
  /// Cancels any active generation or helper and waits until native C++ threads finish draining
  /// in-flight GPU work.
  func cancelAndDrain() async
  /// Run a structured helper prompt (JSON-schema constrained) in a throwaway
  /// conversation. The runtime keeps the main conversation beside it when
  /// memory allows (``lastHelperKeptConversation``). When it doesn't, the main
  /// one is released first and replaced by an empty one: the caller must
  /// re-seed history before the next send.
  func helperJSON(prompt: String, schemaJSON: String, maxOutputTokens: Int) async throws -> Data
  /// Run plain-text helper prompts one after another (e.g. summarizing a
  /// long document section by section), each in a throwaway conversation.
  /// Like ``helperJSON``, this leaves the main conversation empty unless kept.
  /// `progress` receives the number of prompts completed. Stops early (with
  /// the outputs so far) when the calling task is cancelled.
  func helperTexts(
    _ prompts: [String], maxOutputTokens: Int, progress: @Sendable (Int) async -> Void
  ) async throws -> [String]
  /// Transcribe a recording (dictation) in a throwaway conversation with
  /// greedy decoding. Leaves the main conversation empty unless kept, like
  /// the helpers.
  func transcribe(audioFileURL: URL) async throws -> String
  /// Whether the last helper (``helperJSON``, ``helperTexts``, ``transcribe``)
  /// finished with the main conversation as it was. False when it was replaced
  /// by an empty one, or the helper failed: reseed before the next send.
  var lastHelperKeptConversation: Bool { get async }
  /// Older turns dropped by the most recent ``fitContext`` trim (empty when nothing was trimmed),
  /// available for semantic recall of evicted context.
  var lastEvictedHistory: [(role: ChatRole, text: String)] { get async }
  /// The most vision tokens per image the loaded model file accepts (nil when it doesn't say).
  var maxVisionTokenBudget: Int? { get async }
}

extension ChatEngineProtocol {
  nonisolated var requiresLocalModelFile: Bool { true }
  nonisolated var engineDisplayName: String { "LiteRT-LM" }
  func engineSettingsChanged(for newOptions: InferenceOptions) async -> Bool { false }
}

// MARK: - Mock engine (previews, UI tests)

/// Deterministic scripted engine. No model required.
///
/// It models what the runtime does to the conversation, so tests check behavior: the texts
/// the "native" conversation holds (``held``), helpers that keep it or, short of memory, wipe
/// it, a cancelled conversation that rejects the next send until it is
/// reseeded, injected stream errors, and a gate that holds the next helper.
actor MockChatEngine: ChatEngineProtocol {
  nonisolated let requiresLocalModelFile = false
  nonisolated let engineDisplayName = "Mock"

  var script: [ChatChunk]
  var stats: GenerationStats
  private(set) var loadedModel: ModelID?
  var loadResult: ResolvedInference
  /// Test instrumentation: how often `load` ran and every reseeded history.
  private(set) var loadCount = 0
  private(set) var reseedLog: [[String]] = []
  /// Texts the native conversation holds, oldest first (the KV cache's contents).
  private(set) var held: [String] = []
  /// What the conversation held when each send started.
  private(set) var heldAtSend: [[String]] = []
  /// Cancelled: LiteRT-LM rejects the next message ("CANCELLED") until a reseed or load.
  private(set) var poisoned = false
  /// Fail the next send with `error` after `afterChunks` chunks (tests).
  private var streamFailure: (afterChunks: Int, error: ChatError)?
  func failNextSend(afterChunks: Int, with error: ChatError) {
    streamFailure = (afterChunks, error)
  }
  /// Hold the next helper until ``releaseHelper()`` (tests interleave sends with it).
  private var gateNextHelper = false
  private var gate: CheckedContinuation<Void, Never>?
  /// A helper is waiting at the gate.
  private(set) var helperWaiting = false
  /// Stop arrived while a helper ran: it ends with ``ChatError/generationCancelled``.
  private var helperCancelRequested = false
  private var helperRunning = false
  func holdNextHelper() { gateNextHelper = true }
  func releaseHelper() {
    gate?.resume()
    gate = nil
  }

  /// Runs at the start of every helper: busy check, gate, then the conversation as a helper
  /// leaves it on this runtime.
  private func beginHelper() async throws {
    if generating { throw ChatError.underlying(message: "Busy generating.") }
    helperRunning = true
    helperCancelRequested = false
    defer { helperRunning = false }
    if gateNextHelper {
      gateNextHelper = false
      helperWaiting = true
      await withCheckedContinuation { gate = $0 }
      helperWaiting = false
    }
    if !helpersKeepConversation { held = [] }
    if helperCancelRequested {
      lastHelperKeptConversation = false
      throw ChatError.generationCancelled
    }
    lastHelperKeptConversation = helpersKeepConversation
  }
  /// Simulated load latency (exposes overlapping-load races in tests).
  var loadDelay: Duration = .zero

  func setLoadDelay(_ delay: Duration) { loadDelay = delay }

  init(
    script: [ChatChunk] = [
      ChatChunk(textDelta: "Hello", thoughtDelta: "Drafting"),
      ChatChunk(textDelta: " from", thoughtDelta: " a reply"),
      ChatChunk(textDelta: " the mock engine!", thoughtDelta: nil),
    ],
    modelID: ModelID = .e4b
  ) {
    self.script = script
    self.stats = GenerationStats(
      timeToFirstToken: 0.2, totalTime: 0.6, inputTokens: 8, outputTokens: 12,
      decodeTokensPerSecond: 40, backend: "Mock", modelID: modelID)
    self.loadResult = InferencePlanner.resolve(
      options: InferenceOptions(), model: modelID, memoryBytes: 8_000_000_000)
  }

  func load(
    spec: ModelSpec, modelURL: URL, options: InferenceOptions, memoryBytes: UInt64,
    enableTools: Bool
  ) async throws -> ResolvedInference {
    loadCount += 1
    applyConversationOptions(options)
    loadedModel = nil
    held = []
    poisoned = false
    if loadDelay > .zero { try? await Task.sleep(for: loadDelay) }
    loadedModel = spec.id
    loadResult = InferencePlanner.resolve(options: options, model: spec.id, memoryBytes: memoryBytes)
    return loadResult
  }

  func unload() async { loadedModel = nil }
  var isLoaded: Bool { loadedModel != nil }
  var currentModelID: ModelID? { loadedModel }

  func updateConversationOptions(
    _ newOptions: InferenceOptions, enableTools: Bool, history: [(role: ChatRole, text: String)]
  ) async throws -> ResolvedInference {
    applyConversationOptions(newOptions)
    let resolved = InferencePlanner.resolve(
      options: newOptions, model: loadedModel ?? .e4b,
      memoryBytes: DeviceProfile.current.physicalMemoryBytes)
    loadResult = resolved
    try await reseed(history: history)
    return resolved
  }

  func reseed(history: [(role: ChatRole, text: String)]) async throws {
    reseedLog.append(history.map(\.text))
    held = history.map(\.text)
    poisoned = false
  }

  /// Seeds of the sampling conversations (Regenerate), in order.
  private(set) var samplingSeeds: [Int] = []
  func reseedSampling(history: [(role: ChatRole, text: String)], seed: Int) async throws {
    samplingSeeds.append(seed)
    try await reseed(history: history)
  }

  /// Scripted `fitContext` outcome (tests): `.success(true)` = trimmed.
  private(set) var fitResult: Result<Bool, ChatError> = .success(false)
  private(set) var fitCalls = 0
  private(set) var lastEvictedHistory: [(role: ChatRole, text: String)] = []
  func setFitResult(_ result: Result<Bool, ChatError>) { fitResult = result }
  func setEvictedHistory(_ evicted: [(role: ChatRole, text: String)]) {
    lastEvictedHistory = evicted
  }

  func fitContext(
    text: String, imageData: Data?, audioFileURL: URL?,
    history: [(role: ChatRole, text: String)]
  ) async throws -> Bool {
    fitCalls += 1
    // Like the live engine: a message too long even alone is found on an empty conversation.
    if case .failure = fitResult { held = [] }
    return try fitResult.get()
  }

  nonisolated func send(
    text: String, imageData: Data?, audioFileURL: URL?
  ) -> AsyncThrowingStream<ChatEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        // Like the real model: reasoning only streams when thinking is on.
        let thinking = await self.thinkingEnabled
        let stats = await self.stats
        await self.recordSend(text)
        if await self.poisoned {
          continuation.finish(throwing: ChatError.underlying(message: "CANCELLED"))
          return
        }
        let failure = await self.takeStreamFailure()
        await self.setGenerating(true)
        let script: [ChatChunk]
        #if DEBUG
          if let uiTestChunks = await Self.uiTestScript(for: text) {
            let stopRequested = await self.cancelRequested
            if Task.isCancelled || stopRequested {
              await self.setGenerating(false)
              await self.poison()
              continuation.finish(throwing: ChatError.generationCancelled)
              return
            }
            script = uiTestChunks
          } else if text.localizedCaseInsensitiveContains("show me markdown") {
            // A user asking for markdown ("Show me markdown"; UI tests), not an instruction
            // that mentions it.
            script = MockChatEngine.markdownSample
          } else {
            script = await self.script
          }
        #else
          script =
            text.localizedCaseInsensitiveContains("show me markdown")
            ? MockChatEngine.markdownSample : await self.script
        #endif
        var reply = ""
        for (index, chunk) in script.enumerated() {
          if let failure, index == failure.afterChunks {
            await self.setGenerating(false)
            continuation.finish(throwing: failure.error)
            return
          }
          try? await Task.sleep(for: .milliseconds(60))
          let stopRequested = await self.cancelRequested
          if Task.isCancelled || stopRequested {
            await self.setGenerating(false)
            await self.poison()
            continuation.finish(throwing: ChatError.generationCancelled)
            return
          }
          var chunk = chunk
          if !thinking { chunk.thoughtDelta = nil }
          reply += chunk.textDelta
          continuation.yield(.chunk(chunk))
        }
        await self.setGenerating(false)
        await self.hold(text, reply)
        continuation.yield(.finished(stats))
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private var generating = false
  private(set) var cancelRequested = false
  private(set) var thinkingEnabled = false
  /// Test instrumentation: the system prompt of the current conversation.
  private(set) var systemPrompt = ""
  func applyConversationOptions(_ options: InferenceOptions) {
    thinkingEnabled = options.enableThinking
    systemPrompt = options.systemPrompt
  }
  /// Test instrumentation: every prompt sent.
  private(set) var sendLog: [String] = []
  private func recordSend(_ text: String) {
    sendLog.append(text)
    heldAtSend.append(held)
  }
  private func takeStreamFailure() -> (afterChunks: Int, error: ChatError)? {
    defer { streamFailure = nil }
    return streamFailure
  }
  private func poison() { poisoned = true }
  private func hold(_ text: String, _ reply: String) { held += [text, reply] }

  private func setGenerating(_ value: Bool) {
    generating = value
    if value { cancelRequested = false }
  }

  private(set) var drainCount = 0

  func cancel() async {
    if generating { cancelRequested = true }
    if helperRunning { helperCancelRequested = true }
  }

  func cancelAndDrain() async {
    drainCount += 1
    await cancel()
  }

  /// Rich reply for UI checks of markdown rendering (prompt contains "markdown").
  static let markdownSample: [ChatChunk] = {
    let text = """
      ## Lighthouse facts

      Lighthouses use **Fresnel lenses** to focus light. A beam is visible for about *20 nautical miles*.

      1. Lamp
      2. Lens
         - Fresnel rings
      3. Gallery

      ```swift
      let range = 20 // nautical miles
      print("Visible for \\(range) nm")
      ```

      | Part | Purpose |
      | :--- | :--- |
      | Lens | Focus the light |
      | Gallery | Maintenance access |

      Since $d \\approx 1.17\\sqrt{h}$, a taller tower sees farther:

      $$
      d = 1.17 \\sqrt{h}
      $$

      > Keep the lens polished.
      """
    // Stream in a few chunks like a real reply.
    let parts = stride(from: 0, to: text.count, by: 120).map { offset -> String in
      let start = text.index(text.startIndex, offsetBy: offset)
      let end = text.index(start, offsetBy: min(120, text.count - offset))
      return String(text[start..<end])
    }
    return parts.map { ChatChunk(textDelta: $0, thoughtDelta: nil) }
  }()

  /// Scripted helper output (tests) and a log of prompts.
  private(set) var helperResponse = Data(#"{"title":"Mock chat"}"#.utf8)
  private(set) var helperPrompts: [String] = []
  func setHelperResponse(_ json: String) { helperResponse = Data(json.utf8) }
  func setScript(_ text: String) { script = [ChatChunk(textDelta: text, thoughtDelta: nil)] }
  func setScriptChunks(_ chunks: [ChatChunk]) { script = chunks }
  /// Whether helpers keep the main conversation, as our runtime does (tests).
  private(set) var helpersKeepConversation = false
  func setHelpersKeepConversation(_ value: Bool) { helpersKeepConversation = value }
  var maxVisionTokenBudget: Int? { nil }
  private(set) var lastHelperKeptConversation = false

  func helperJSON(prompt: String, schemaJSON: String, maxOutputTokens: Int) async throws -> Data {
    try await beginHelper()
    helperPrompts.append(prompt)
    return helperResponse
  }

  /// Test instrumentation: recordings transcribed.
  private(set) var transcribed: [URL] = []
  var transcript = "Dictated text."
  func setTranscript(_ text: String) { transcript = text }

  func transcribe(audioFileURL: URL) async throws -> String {
    try await beginHelper()
    transcribed.append(audioFileURL)
    return transcript
  }

  /// Test instrumentation: every plain-text helper prompt.
  private(set) var helperTextPrompts: [String] = []

  func helperTexts(
    _ prompts: [String], maxOutputTokens: Int, progress: @Sendable (Int) async -> Void
  ) async throws -> [String] {
    try await beginHelper()
    var outputs: [String] = []
    for prompt in prompts {
      helperTextPrompts.append(prompt)
      outputs.append("- Key point \(outputs.count + 1) of this part.")
      await progress(outputs.count)
    }
    return outputs
  }
}

#if DEBUG
  extension MockChatEngine {
    /// Deterministic UI-test triggers (`--mock-engine` only, DEBUG builds only).
    /// Never matches normal user or unit-test prompts.
    fileprivate static func uiTestScript(for text: String) async -> [ChatChunk]? {
      if text.contains("__uitest_long__") {
        return longScrollSample
      }
      if text.contains("__uitest_cards__") {
        return actionCardsSample
      }
      if text.contains("__uitest_live_cards__") {
        return liveActionCardsSample
      }
      if text.contains("__uitest_confirm__") {
        let decision = await ToolConfirmationGate.confirm(sampleConfirmationRequest)
        let outcome =
          decision == .approved
          ? "Confirmed and deleted Board Review."
          : "Cancelled deleting Board Review."
        return [ChatChunk(textDelta: outcome, thoughtDelta: nil)]
      }
      if text.contains("__uitest_plan__") {
        let decision = await ToolConfirmationGate.confirm(samplePlanConfirmationRequest)
        let outcome: String
        switch decision {
        case .approved:
          outcome = "Approved all plan steps."
        case .approvedSteps(let indices):
          let list = indices.sorted().map(String.init).joined(separator: ",")
          outcome = "Approved plan steps: \(list)."
        case .denied:
          outcome = "Denied plan."
        }
        return [ChatChunk(textDelta: outcome, thoughtDelta: nil)]
      }
      return nil
    }

    private static let longScrollSample: [ChatChunk] = {
      let paragraphs = (1...24).map { idx in
        "Section \(idx): On-device inference keeps private notes, documents, and conversations local while streaming structured responses cleanly across long threads."
      }
      return stride(from: 0, to: paragraphs.count, by: 4).map { start in
        let end = min(start + 4, paragraphs.count)
        let body = paragraphs[start..<end].joined(separator: "\n\n") + (end < paragraphs.count ? "\n\n" : "")
        return ChatChunk(textDelta: body, thoughtDelta: nil)
      }
    }()

    private static var actionCardsSample: [ChatChunk] {
      let now = Date(timeIntervalSince1970: 1_795_564_800)
      let cards: [ActionCardRecord] = [
        ActionCardRecord(
          payload: .places(
            PlacesCard(
              query: "coffee", areaLabel: "Downtown",
              places: [
                .init(
                  name: "Cafe Saint-Henri", category: "cafe", address: "123 Rue Peel",
                  phone: "+1 514-555-0100", websiteURL: "https://example.com",
                  latitude: 45.5017, longitude: -73.5673, distanceMeters: 280),
                .init(
                  name: "Crew Collective", category: "cafe", address: "360 Rue Saint-Jacques",
                  latitude: 45.5021, longitude: -73.5594, distanceMeters: 520),
              ]))),
        ActionCardRecord(
          payload: .route(
            RouteCard(
              originName: "Current location", originLatitude: 45.5017, originLongitude: -73.5673,
              originIsCurrentLocation: true, destinationName: "Cafe Saint-Henri",
              destinationAddress: "123 Rue Peel", destinationLatitude: 45.5025,
              destinationLongitude: -73.5690, destinationMapItemIdentifier: nil,
              transport: "driving", distanceMeters: 1_100, expectedTravelSeconds: 240,
              routeName: "Rue Peel",
              steps: [
                .init(id: 0, instruction: "Head north on Rue Peel", distanceMeters: 400),
                .init(id: 1, instruction: "Turn right onto Rue Sainte-Catherine", distanceMeters: 700),
              ]))),
        ActionCardRecord(
          payload: .calendarEvent(
            CalendarEventCard(
              status: .created, eventIdentifier: "ui-ev-1", title: "Design Sync",
              startDate: now, endDate: now.addingTimeInterval(3_600), isAllDay: false,
              location: "Room 4B", calendarName: "Work"))),
        ActionCardRecord(
          payload: .reminder(
            ReminderCard(
              status: .created, reminderIdentifier: "ui-rem-1", title: "Buy espresso beans",
              dueDate: now, listName: "Errands", isCompleted: false))),
        ActionCardRecord(
          payload: .contact(
            ContactCard(
              contactIdentifier: "ui-c-1", fullName: "Ada Lovelace",
              organization: "Analytical Engine", phones: ["+1 514-555-0142"],
              emails: ["ada@example.com"], postalAddress: "123 Rue Peel, Montreal"))),
        ActionCardRecord(
          payload: .messageDraft(
            MessageDraftCard(
              channel: .email, recipients: ["ada@example.com", "unknown@example.org"],
              subject: "Design Sync", body: "See you at 3 PM in Room 4B.",
              unverifiedRecipients: ["unknown@example.org"]))),
      ]
      return [
        ChatChunk(
          textDelta: "Here are your places, route, event, reminder, contact, and draft.",
          thoughtDelta: nil, actionCards: cards)
      ]
    }

    private static var liveActionCardsSample: [ChatChunk] {
      let base = Date(timeIntervalSince1970: 1_795_564_800)
      let cards: [ActionCardRecord] = [
        ActionCardRecord(
          payload: .weather(
            WeatherCard(
              locationName: "Montréal, QC", temperature: "18°C", feelsLike: "17°C",
              condition: "Partly Cloudy", conditionSymbol: "cloud.sun.fill",
              high: "21°C", low: "12°C", humidityPercent: 55, windSpeed: "12 km/h",
              hourly: [
                .init(date: base, temperature: "18°C", symbolName: "cloud.sun.fill", precipitationPercent: 10),
                .init(
                  date: base.addingTimeInterval(3_600), temperature: "19°C",
                  symbolName: "sun.max.fill", precipitationPercent: 0),
              ],
              daily: [
                .init(
                  date: base, label: "Today", high: "21°C", low: "12°C",
                  symbolName: "cloud.sun.fill", precipitationPercent: 20),
                .init(
                  date: base.addingTimeInterval(86_400), label: "Tue", high: "20°C", low: "11°C",
                  symbolName: "sun.max.fill", precipitationPercent: 0),
              ],
              alerts: [
                .init(
                  summary: "Wind Advisory", severity: "moderate",
                  detailsURL: "https://weatherkit.apple.com/legal-attribution.html")
              ],
              attributionLegalURL: "https://weatherkit.apple.com/legal-attribution.html"))),
        ActionCardRecord(
          payload: .alarm(
            AlarmCard(
              alarmID: "ui-alm-1", kind: .alarm, label: "Morning Run",
              fireDate: nil, hour: 7, minute: 30, weekdays: ["mon", "wed"],
              durationSeconds: nil, state: .scheduled))),
        ActionCardRecord(
          payload: .automationHandoff(
            AutomationHandoffCard(
              shortcutID: "log_expense", shortcutName: "Log Expense",
              inputSummary: "Coffee $5", state: .completed,
              resultSummary: "Logged Coffee $5", callbackRequestID: "ui-cb-1"))),
      ]
      return [
        ChatChunk(
          textDelta: "Here are your weather, alarm, and shortcut cards.",
          thoughtDelta: nil, actionCards: cards)
      ]
    }

    private static var sampleConfirmationRequest: ToolConfirmationRequest {
      ToolConfirmationRequest(
        toolName: "manage_calendar_event",
        title: "Delete calendar event",
        summary: "Delete \"Board Review\" from Work calendar.",
        parameters: [
          .init(name: "event", value: "Board Review"),
          .init(name: "calendar", value: "Work"),
        ],
        risk: .destructive,
        untrustedSources: ["web_search"])
    }

    private static var samplePlanConfirmationRequest: ToolConfirmationRequest {
      ToolConfirmationRequest(
        toolName: "plan",
        title: "Confirm 2 actions",
        summary: "Review and choose which actions Agello should run.",
        parameters: [],
        risk: .destructive,
        steps: [
          .init(
            index: 0, toolName: "manage_calendar_event", title: "Create calendar event",
            summary: "Design Sync tomorrow at 10 AM",
            parameters: [.init(name: "title", value: "Design Sync")],
            risk: .standard),
          .init(
            index: 1, toolName: "manage_reminder", title: "Delete reminder",
            summary: "Remove Old Errand from Reminders",
            parameters: [.init(name: "title", value: "Old Errand")],
            risk: .destructive),
        ],
        untrustedSources: ["file:notes.txt"])
    }
  }
#endif
