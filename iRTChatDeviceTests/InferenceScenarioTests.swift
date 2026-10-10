import LiteRTLM
import SwiftData
import UIKit
import XCTest

@testable import iRTChat

/// End-to-end on-device scenarios for Gemma 4 E4B, run through the real app
/// pipeline (AppState → LiteRTChatEngine → LiteRT-LM). Tests run in name
/// order; the model loads once and is shared.
///
/// Results: xcresult attachments + Documents/harness-report.json on device.
final class InferenceScenarioTests: DeviceTestCase {

  func test00_ModelAvailable() async throws {
    let downloadSeconds = try await harness.ensureDownloaded(ModelCatalog.e4b, timeout: 5400)
    XCTAssertTrue(appState.store.isDownloaded(ModelCatalog.e4b))
    harness.record("00_model", ["downloadSeconds": downloadSeconds], in: self)
  }

  func test01_LoadModel() async throws {
    _ = try await harness.ensureDownloaded(ModelCatalog.e4b, timeout: 5400)
    // Measure a cold load: drop whatever an earlier scenario left loaded.
    await appState.engine.unload()
    let before = MemoryProbe.footprintBytes()
    let started = Date()
    let loaded = await appState.ensureEngineLoaded()
    let seconds = Date().timeIntervalSince(started)
    let loadLog = await harness.liveEngine?.loadLog ?? []
    var values = harness.resolvedSummary()
    values["loaded"] = loaded
    values["loadSeconds"] = seconds
    values["footprintDeltaGB"] = Double(MemoryProbe.footprintBytes()) / 1e9 - Double(before) / 1e9
    values["loadLog"] = loadLog
    values["engineState"] = "\(appState.engineState)"
    harness.record("01_load", values, in: self)
    XCTAssertTrue(loaded, "Load failed: \(appState.engineState)\n\(loadLog.joined(separator: "\n"))")
    XCTAssertEqual(appState.resolved?.useGPU, true, "Expected GPU backend; ladder: \(loadLog)")
  }

  func test02_TextReply() async throws {
    try await requireLoadedModel()
    let thread = harness.newThread()
    let exchange = await harness.ask(
      "What is the capital of France? Answer in one short sentence.", in: thread)
    var values = DeviceHarness.stats(exchange.reply?.stats)
    values["reply"] = exchange.text
    values["seconds"] = exchange.seconds
    harness.record("02_text", values, in: self)
    XCTAssertTrue(exchange.accepted)
    XCTAssertFalse(exchange.text.hasPrefix("Error:"), exchange.text)
    XCTAssertTrue(exchange.text.localizedCaseInsensitiveContains("Paris"), exchange.text)
    XCTAssertNotNil(exchange.reply?.stats)
  }

  /// Regression for audit #2: context must not bleed between chats.
  func test03_ThreadIsolation() async throws {
    try await requireLoadedModel()
    let a = harness.newThread()
    let b = harness.newThread()
    let seed = await harness.ask(
      "Remember this secret code word: ZORBLAX. Reply only with the word 'noted'.", in: a)
    let leak = await harness.ask(
      "What secret code word did I ask you to remember? If I never gave you one, reply exactly 'none'.",
      in: b)
    let recall = await harness.ask("What secret code word did I ask you to remember?", in: a)
    harness.record(
      "03_isolation",
      ["seed": seed.text, "otherThread": leak.text, "sameThread": recall.text], in: self)
    XCTAssertFalse(
      leak.text.localizedCaseInsensitiveContains("ZORBLAX"),
      "Context leaked into another chat: \(leak.text)")
    XCTAssertTrue(
      recall.text.localizedCaseInsensitiveContains("ZORBLAX"),
      "Lost context when returning to the chat: \(recall.text)")
  }

  /// Audit #10: Stop must end as a cancellation, not an error.
  func test04_StopMidReply() async throws {
    try await requireLoadedModel()
    let thread = harness.newThread()
    let state = appState
    let sending = Task { @MainActor in
      await state.send(
        text: "Write a detailed 600-word story about a lighthouse keeper.", imageData: nil,
        audioFileURL: nil, in: thread)
    }
    try await harness.waitUntil("partial reply", timeout: 90) {
      (thread.orderedTurns.last(where: { !$0.isUser })?.text.count ?? 0) > 40
    }
    let partialLength = thread.orderedTurns.last(where: { !$0.isUser })?.text.count ?? 0
    let stopAt = Date()
    appState.stop()
    // User-facing latency: until the reply stops and the composer is usable
    // (send() itself returns later, after the post-reply title helper).
    try await harness.waitUntil("reply to stop", timeout: 10) { !state.isGenerating }
    let stopLatency = Date().timeIntervalSince(stopAt)
    _ = await sending.value
    let reply = thread.orderedTurns.last(where: { !$0.isUser })
    harness.record(
      "04_stop",
      [
        "stopLatencySeconds": stopLatency,
        "partialLength": partialLength,
        "finalLength": reply?.text.count ?? 0,
        "finalPrefix": String(reply?.text.prefix(120) ?? ""),
        "hasStats": reply?.stats != nil,
        "generationError": appState.generationError ?? "",
      ], in: self)
    XCTAssertLessThan(stopLatency, 3, "Stop took too long")
    XCTAssertFalse(reply?.text.hasPrefix("Error:") ?? false, "Stop surfaced as an error")
    XCTAssertLessThan(
      reply?.text.count ?? 0, 3000, "Generation kept running after Stop")
    // The same chat must keep working right after a stop (LiteRT-LM leaves a
    // cancelled conversation failing with "CANCELLED" unless it is rebuilt).
    let after = await harness.ask("Say 'ready'.", in: thread)
    XCTAssertFalse(after.text.isEmpty, "No reply after stop")
    XCTAssertFalse(after.text.hasPrefix("Error:"), "Chat broken after stop: \(after.text)")
  }

  func test05_ToolCall() async throws {
    try await requireLoadedModel()
    let thread = harness.newThread()
    let cursor = ToolActivity.cursor
    let exchange = await harness.ask(
      "Use the calculate tool to compute 1234 * 5678 and tell me the result.", in: thread)
    let invoked = ToolActivity.invocations(since: cursor)
    let digits = exchange.text.filter(\.isNumber)
    harness.record(
      "05_tools",
      [
        "reply": exchange.text, "toolNames": exchange.reply?.toolNames ?? [],
        "toolsInvoked": invoked,
        "modelDeclaresFunctionCalling": "see 01_load caps",
      ], in: self)
    XCTAssertTrue(digits.contains("7006652"), "Wrong/missing result: \(exchange.text)")
    XCTAssertTrue(invoked.contains(CalculatorTool.name), "The model never ran the calculate tool")
    XCTAssertEqual(
      exchange.reply?.parts.toolActivity.first?.name, CalculatorTool.name,
      "Tool activity not saved on the reply")
    XCTAssertFalse(
      exchange.reply?.toolNames.isEmpty ?? true,
      "Tool chip not recorded (toolNames empty) even though tools are enabled")
  }

  func test06_Thinking() async throws {
    try await requireLoadedModel()
    appState.options.enableThinking = true
    appState.options.thinkingBudget = 512
    await appState.applyCurrentOptions()
    guard appState.resolved?.thinkingBudget != nil else {
      throw XCTSkip("Model file does not support thinking")
    }
    let exchange = await harness.ask("What is 17 * 23?", in: harness.newThread())
    var values = DeviceHarness.stats(exchange.reply?.stats)
    values["reply"] = exchange.text
    values["thoughtLength"] = exchange.reply?.thought.count ?? 0
    values["thoughtPrefix"] = String(exchange.reply?.thought.prefix(200) ?? "")
    harness.record("06_thinking", values, in: self)
    XCTAssertFalse(exchange.reply?.thought.isEmpty ?? true, "No reasoning streamed")
    XCTAssertTrue(exchange.text.contains("391"), exchange.text)
  }

  /// The model file reports thinking=false, and the app hides thinking based
  /// on that — but it also reports tools=false while tools demonstrably work.
  /// Ask LiteRT-LM directly (bypassing the app's capability gate) whether
  /// this file can stream reasoning.
  func test06b_ThinkingProbeBypassingCapabilityGate() async throws {
    try await requireLoadedModel()
    guard let url = appState.store.localURL(for: ModelCatalog.e4b) else {
      throw XCTSkip("No model file")
    }
    // Free the app's engine first: two GPU engines won't fit the memory limit.
    await appState.engine.unload()
    let config = try EngineConfig(
      modelPath: url.path, backend: .gpu, maxNumTokens: 2048,
      cacheDir: try LiteRTChatEngine.cacheDirectory())
    let engine = Engine(engineConfig: config)
    try await engine.initialize()
    let conversation = try await engine.createConversation(
      with: ConversationConfig(
        thinkingConfig: ThinkingConfig(enableThinking: true, thinkingTokenBudget: 512)))
    var thought = ""
    var text = ""
    for try await chunk in conversation.sendMessageStream(
      LiteRTLM.Message("What is 17 * 23? Think it through."), maxOutputTokens: 768)
    {
      thought += chunk.channels["thought"] ?? ""
      text += chunk.toString
    }
    harness.record(
      "06b_thinkingProbe",
      [
        "thoughtLength": thought.count, "thoughtPrefix": String(thought.prefix(200)),
        "reply": String(text.prefix(300)),
        "capabilityGateSaysThinking": appState.resolved?.thinkingBudget != nil,
      ], in: self)
    XCTAssertTrue(text.contains("391"), text)
    // Informational: if this passes, the capability flag is wrong and the
    // app should stop hiding thinking for this model.
    XCTAssertFalse(thought.isEmpty, "No reasoning channel even with thinking forced on")
  }

  func test07_ImageInput() async throws {
    try await requireLoadedModel()
    guard appState.resolved?.enableVision == true else {
      throw XCTSkip("Session is text-only: \(harness.resolvedSummary())")
    }
    let image = TestMedia.solidColorJPEG(.red)
    let exchange = await harness.ask(
      "What is the dominant color of this image? Answer with one word.", in: harness.newThread(),
      image: image)
    var values = DeviceHarness.stats(exchange.reply?.stats)
    values["reply"] = exchange.text
    harness.record("07_image", values, in: self)
    XCTAssertTrue(exchange.accepted, appState.generationError ?? "")
    XCTAssertTrue(exchange.text.localizedCaseInsensitiveContains("red"), exchange.text)
  }

  func test08_AudioInput() async throws {
    try await requireLoadedModel()
    guard appState.resolved?.enableAudio == true else {
      throw XCTSkip("Session has no audio: \(harness.resolvedSummary())")
    }
    let audio = try await TestMedia.spokenWAV("The quick brown fox jumps over the lazy dog.")
    defer { try? FileManager.default.removeItem(at: audio) }
    let exchange = await harness.ask(
      "Transcribe this audio exactly.", in: harness.newThread(), audio: audio)
    var values = DeviceHarness.stats(exchange.reply?.stats)
    values["reply"] = exchange.text
    harness.record("08_audio", values, in: self)
    XCTAssertTrue(exchange.accepted, appState.generationError ?? "")
    XCTAssertTrue(exchange.text.localizedCaseInsensitiveContains("fox"), exchange.text)
  }

  /// Audit #4: vision is an engine-level setting; toggling it off and on must
  /// leave a session that can still see images.
  func test09a_VisionToggleRoundTrip() async throws {
    try await requireLoadedModel()
    appState.options.enableVision = false
    await appState.applyCurrentOptions()
    let off = harness.resolvedSummary()
    appState.options.enableVision = true
    await appState.applyCurrentOptions()
    let on = harness.resolvedSummary()
    let exchange = await harness.ask(
      "What is the dominant color of this image? Answer with one word.", in: harness.newThread(),
      image: TestMedia.solidColorJPEG(.red))
    harness.record(
      "09a_visionToggle",
      [
        "resolvedOff": off, "resolvedOn": on, "reply": exchange.text,
        "generationError": appState.generationError ?? "",
      ], in: self)
    XCTAssertTrue(exchange.accepted, appState.generationError ?? "")
    XCTAssertFalse(exchange.text.hasPrefix("Error:"), exchange.text)
    XCTAssertTrue(exchange.text.localizedCaseInsensitiveContains("red"), exchange.text)
  }

  /// Audit #4, dangerous direction: the engine is (re)built while vision is
  /// off — so it has no vision executor — and vision is then switched on.
  func test09b_VisionEnabledAfterTextOnlyLoad() async throws {
    try await requireLoadedModel()
    appState.options.enableVision = false
    appState.options.maxNumTokensOverride = 2048  // engine-level: forces a rebuild without vision
    await appState.applyCurrentOptions()
    let textOnlyLog = await harness.liveEngine?.loadLog ?? []
    appState.options.enableVision = true
    await appState.applyCurrentOptions()
    let afterLog = await harness.liveEngine?.loadLog ?? []
    let exchange = await harness.ask(
      "What is the dominant color of this image? Answer with one word.", in: harness.newThread(),
      image: TestMedia.solidColorJPEG(.red))
    harness.record(
      "09b_visionAfterTextOnlyLoad",
      [
        "textOnlyLoadLog": textOnlyLog, "afterToggleLoadLog": afterLog,
        "resolved": harness.resolvedSummary(), "accepted": exchange.accepted,
        "reply": exchange.text, "generationError": appState.generationError ?? "",
      ], in: self)
    XCTAssertTrue(exchange.accepted, appState.generationError ?? "")
    XCTAssertFalse(exchange.text.hasPrefix("Error:"), exchange.text)
    XCTAssertTrue(exchange.text.localizedCaseInsensitiveContains("red"), exchange.text)
  }

  /// Audit #15: a long chat against a small KV cache must degrade gracefully.
  func test10_LongChatNearContextLimit() async throws {
    try await requireLoadedModel()
    appState.options.maxNumTokensOverride = 1024
    await appState.applyCurrentOptions()
    let thread = harness.newThread()
    var replies: [String] = []
    for topic in ["volcanoes", "glaciers", "coral reefs", "deserts", "rainforests", "tundra"] {
      let exchange = await harness.ask(
        "Write about 120 words on \(topic).", in: thread)
      replies.append(String(exchange.text.prefix(80)))
      if exchange.text.isEmpty || exchange.text.hasPrefix("Error:") { break }
    }
    harness.record(
      "10_contextLimit",
      [
        "kvTokens": appState.resolved?.maxNumTokens ?? 0, "replies": replies,
        "generationError": appState.generationError ?? "",
      ], in: self)
    XCTAssertFalse(
      replies.contains { $0.isEmpty || $0.hasPrefix("Error:") },
      "Chat broke near the context limit (empty or error reply): \(replies)")
  }

  /// Audit #15: a message that can't fit the window is refused, not sent.
  func test10b_OversizedMessageRejected() async throws {
    try await requireLoadedModel()
    appState.options.maxNumTokensOverride = 1024
    await appState.applyCurrentOptions()
    let thread = harness.newThread()
    let huge = String(repeating: "Please summarize this sentence carefully. ", count: 120)
    let rejected = await harness.ask(huge, in: thread)
    let errorShown = appState.generationError ?? ""
    let after = await harness.ask("Say 'ready'.", in: thread)
    harness.record(
      "10b_oversized",
      [
        "promptBytes": huge.utf8.count, "accepted": rejected.accepted, "error": errorShown,
        "followUp": after.text,
      ], in: self)
    XCTAssertFalse(rejected.accepted, "Oversized message was sent to the engine")
    XCTAssertEqual(errorShown, ChatError.messageTooLong.displayMessage)
    XCTAssertTrue(thread.turns.contains { $0.text == after.text } && !after.text.isEmpty)
  }

  /// Helper task: a model-written title after the first exchange. The helper
  /// wipes the engine's conversation, so the chat must be rebuilt intact.
  func test11_TitleAndContextAfterHelper() async throws {
    try await requireLoadedModel()
    let thread = harness.newThread()
    let prompt = "Remember the code word ZORBLAX. Then explain in two sentences how lighthouses warn ships."
    let first = await harness.ask(prompt, in: thread)
    let provisional = AppState.title(prompt: prompt, hasImage: false)
    let recall = await harness.ask("What code word did I ask you to remember?", in: thread)
    harness.record(
      "11_title",
      [
        "title": thread.title, "provisional": provisional, "firstReply": String(first.text.prefix(120)),
        "recall": recall.text,
      ], in: self)
    XCTAssertNotEqual(thread.title, provisional, "Title was not generated")
    XCTAssertLessThanOrEqual(thread.title.count, HelperTasks.maxTitleLength)
    XCTAssertTrue(
      recall.text.localizedCaseInsensitiveContains("ZORBLAX"),
      "Context lost after the title helper: \(recall.text)")
  }

  /// Memory with the real model: a fact is learned from a personal message
  /// and shapes a later, unrelated chat.
  func test12_Memory() async throws {
    try await requireLoadedModel()
    appState.memoryEnabled = true
    defer {
      for memory in (try? harness.context.fetch(FetchDescriptor<MemoryItem>())) ?? [] {
        harness.context.delete(memory)
      }
      appState.memoryEnabled = false
    }
    let first = await harness.ask(
      "I'm vegetarian and I live in Montreal. Suggest a quick dinner.", in: harness.newThread())
    let learned = ((try? harness.context.fetch(FetchDescriptor<MemoryItem>())) ?? []).map(\.text)
    let later = await harness.ask("Suggest a dinner recipe for tonight.", in: harness.newThread())
    let meats = ["chicken", "beef", "pork", "fish", "salmon", "shrimp", "bacon", "lamb", "turkey"]
    let mentionsMeat = meats.filter { later.text.localizedCaseInsensitiveContains($0) }
    harness.record(
      "12_memory",
      [
        "learned": learned, "firstSeconds": first.seconds, "laterReply": String(later.text.prefix(500)),
        "laterMentionsMeat": mentionsMeat,
        "memoryNote": first.reply?.parts.toolActivity.map(\.summary) ?? [],
      ], in: self)
    XCTAssertFalse(first.text.hasPrefix(ChatTurn.errorPrefix), first.text)
    XCTAssertTrue(
      learned.contains { $0.localizedCaseInsensitiveContains("vegetarian") }, "Learned: \(learned)")
    XCTAssertTrue(appState.effectiveOptions.systemPrompt.localizedCaseInsensitiveContains("vegetarian"))
    XCTAssertFalse(later.text.hasPrefix(ChatTurn.errorPrefix), later.text)
  }

  /// Dictation through Gemma's audio input: synthesized speech in English
  /// and French, scored by word error rate.
  func test13_Dictation() async throws {
    try await requireLoadedModel()
    guard appState.resolved?.enableAudio == true else {
      throw XCTSkip("Session has no audio: \(harness.resolvedSummary())")
    }
    let samples = [
      ("en-US", "Please book a table for four people at seven thirty tomorrow evening, near the train station."),
      ("en-US", "Remind me to call the dentist on Monday and to buy milk, eggs, and coffee on the way home."),
      ("fr-CA", "Peux-tu m'aider à planifier une fin de semaine à Québec avec deux enfants en octobre?"),
    ]
    var results: [[String: Any]] = []
    for (language, sentence) in samples {
      let audio = try await TestMedia.spokenWAV(sentence, language: language)
      defer { try? FileManager.default.removeItem(at: audio) }
      let started = Date()
      let text = await appState.transcribe(audio) ?? ""
      let wer = Dictation.wordErrorRate(reference: sentence, hypothesis: text)
      results.append([
        "language": language, "reference": sentence, "transcript": text, "wer": wer,
        "seconds": Date().timeIntervalSince(started),
      ])
      harness.record("13_dictation", ["results": results], in: self)
      XCTAssertLessThanOrEqual(wer, language.hasPrefix("en") ? 0.15 : 0.25, "\(language): \(text)")
    }
    // Chat still works after dictation replaced the conversation.
    let after = await harness.ask("Say 'ready'.", in: harness.newThread())
    XCTAssertFalse(after.text.hasPrefix(ChatTurn.errorPrefix), after.text)
  }

  /// Voice mode with the real model: spoken turns (synthesized speech)
  /// come back as "transcript, then a short answer"; measures the time to
  /// the first speakable sentence.
  func test14_VoiceTurns() async throws {
    try await requireLoadedModel()
    guard appState.resolved?.enableAudio == true else { throw XCTSkip("No audio in this session") }
    let thread = harness.newThread()
    var results: [[String: Any]] = []
    appState.voiceModeActive = true
    defer {
      appState.voiceModeActive = false
      appState.onVoiceReply = nil
    }
    for (language, sentence) in [
      ("en-US", "What's a good name for a golden retriever puppy?"),
      ("en-US", "And one that starts with the letter M?"),
      ("fr-CA", "Merci! Et quelle est la capitale du Canada?"),
    ] {
      let audio = try await TestMedia.spokenWAV(sentence, language: language)
      defer { try? FileManager.default.removeItem(at: audio) }
      var stream = VoiceText.SentenceStream()
      var firstSentence: Double?
      let started = Date()
      appState.onVoiceReply = { answer, final in
        if firstSentence == nil, !stream.next(from: answer, final: final).isEmpty {
          firstSentence = Date().timeIntervalSince(started)
        }
      }
      let accepted = await appState.sendVoiceTurn(audioFileURL: audio, imageData: nil, in: thread)
      let user = thread.orderedTurns.last(where: \.isUser)
      let reply = thread.orderedTurns.last
      results.append([
        "language": language, "said": sentence, "heard": user?.text ?? "",
        "wer": Dictation.wordErrorRate(reference: sentence, hypothesis: user?.text ?? ""),
        "answer": reply?.text ?? "", "firstSentenceSeconds": firstSentence ?? -1,
        "totalSeconds": Date().timeIntervalSince(started),
      ])
      harness.record("14_voiceTurns", ["results": results, "title": thread.title], in: self)
      XCTAssertTrue(accepted)
      XCTAssertLessThanOrEqual(
        Dictation.wordErrorRate(reference: sentence, hypothesis: user?.text ?? ""), 0.25,
        "Heard: \(user?.text ?? "")")
      XCTAssertFalse(reply?.text.contains("⟦") ?? true, reply?.text ?? "")
      XCTAssertFalse(reply?.text.isEmpty ?? true)
      XCTAssertNotNil(firstSentence)
    }
    XCTAssertNotEqual(thread.title, "Voice message")
    // Back to text: the voice turns replay as text and chat works.
    appState.voiceModeActive = false
    let after = await harness.ask("Summarize what we talked about in one sentence.", in: thread)
    XCTAssertFalse(after.text.hasPrefix(ChatTurn.errorPrefix), after.text)
    harness.record("14_voiceTurns", ["results": results, "title": thread.title, "after": after.text], in: self)
  }

  func test90_Benchmark() async throws {
    _ = try await harness.ensureDownloaded(ModelCatalog.e4b, timeout: 5400)
    await appState.runBenchmark()
    guard let report = appState.benchmarkReport else {
      XCTFail("No benchmark report: \(appState.generationError ?? "")")
      return
    }
    harness.record(
      "90_benchmark",
      [
        "backend": report.backend,
        "prefillTokPerSec": report.prefillTokensPerSecond,
        "decodeTokPerSec": report.decodeTokensPerSecond,
        "ttftSeconds": report.timeToFirstToken,
        "googleReferenceE4B": "1189 prefill / 25 decode tok/s (iPhone 17 Pro GPU, no MTP)",
      ], in: self)
    XCTAssertGreaterThan(report.decodeTokensPerSecond, 0)
  }
}
