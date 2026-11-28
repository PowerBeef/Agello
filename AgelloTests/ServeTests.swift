#if os(macOS)
  import Darwin
  import LiteRTLM
#endif
import Foundation
import XCTest

@testable import Agello

/// Unit tests for `agello serve` (`Serve`, `ServeProtocol`, `ServeMessages`, `ServeTurnQueue`)
/// and `AgelloSim` wire/budget contracts (`INF-15`, `W3-22..24`):
/// - `/health` `runtime_build` provenance
/// - `/v1/tokenize` request/response encoding
/// - Single-session prefix-KV extension matching vs new-chat/branch/edit/system/tool invalidation
/// - `ServeTurnQueue` strict FIFO serialization across suspensions and thrown errors
/// - HTTP `413 Payload Too Large` (`<= 64 MiB` `Content-Length` & chunked) and 64-bit integer clamping
/// - Immediate halt after SSE error frames and mandatory `data: [DONE]` before EOF
/// - `/v1/embeddings` `index` sorting and `ContextBudget.fits` / `ToolBudget` parity
final class ServeTests: XCTestCase {
  // MARK: - Cross-platform ContextBudget & ToolBudget parity (RemoteChatEngine W3-24)

  func testContextBudgetFitsRejectsOversizedSingleMessageUnlikeClampedHistoryBudget() {
    let window = 65_536
    let thinking = 4_096

    // `historyBudget` clamps at 0, so checking `historyBudget >= 0` never detected oversized inputs.
    // `RemoteChatEngine.fitContext` now checks `ContextBudget.fits` directly.
    let oversizedAlone = 62_000
    XCTAssertEqual(
      ContextBudget.historyBudget(
        maxNumTokens: window, input: oversizedAlone, thinkingBudget: thinking, preamble: 0),
      0
    )
    XCTAssertFalse(
      ContextBudget.fits(
        used: oversizedAlone, input: 0, maxNumTokens: window, thinkingBudget: thinking),
      "62K input + 8,192 replyReserve + 64 safetyMargin exceeds 65,536 and must fail fits()"
    )

    // Large 56K single prompt fits cleanly at 64K with Think ON (`replyReserve` = 8,192).
    let validLargePrompt = 56_000
    XCTAssertTrue(
      ContextBudget.fits(
        used: validLargePrompt, input: 0, maxNumTokens: window, thinkingBudget: thinking)
    )
  }

  func testContextBudgetOutputCapAndToolBudgetFollowUpThinkingParity() {
    let window = 65_536
    // Fewer than `minReplyTokens` (96) remaining after `safetyMargin` (64) -> nil (`contextFull`).
    XCTAssertNil(ContextBudget.outputCap(maxNumTokens: window, used: window - 150, input: 0))
    XCTAssertEqual(
      ContextBudget.outputCap(maxNumTokens: window, used: window - 200, input: 0),
      200 - ContextBudget.safetyMargin
    )

    // Tight post-tool follow-up cap clamps `followUpThinkingBudget` to preserve answer tokens.
    let plan = ToolBudget.plan(
      room: 4_096, toolsOffered: true, thinkingBudget: 4_096, maxOutputTokens: nil)
    let followThink = try! XCTUnwrap(plan.followUpThinkingBudget)
    XCTAssertLessThan(followThink, plan.followUpCap)
    XCTAssertGreaterThanOrEqual(plan.followUpCap - followThink, ToolBudget.answerTokens)
  }

  #if os(macOS)
    // MARK: - /health & /v1/tokenize encoding

    func testHealthObjectIncludesRuntimeBuildProvenance() {
      let health = ServeProtocol.healthObject(
        modelID: "google/gemma-4-E4B-it",
        allocatedPositions: 65_536,
        hasEmbedder: true,
        runtimeBuildID: "8931ed8d5a23"
      )
      XCTAssertEqual(health["status"] as? String, "ok")
      XCTAssertEqual(health["model"] as? String, "google/gemma-4-E4B-it")
      XCTAssertEqual(health["kv"] as? Int, 65_536)
      XCTAssertEqual(health["embeddings"] as? Bool, true)
      XCTAssertEqual(health["build"] as? String, "8931ed8d5a23")
      XCTAssertEqual(health["runtime_build"] as? String, "8931ed8d5a23")
    }

    func testTokenizeResponseEncodingAndValidationErrors() throws {
      let (status, payload) = ServeProtocol.tokenizeSuccessResponse(
        tokens: 1_428, allocatedPositions: 65_536)
      XCTAssertEqual(status, 200)
      let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
      XCTAssertEqual(decoded["tokens"] as? Int, 1_428)
      XCTAssertEqual(decoded["allocated_positions"] as? Int, 65_536)

      // Negative counts clamp safely to 0.
      let (_, zeroData) = ServeProtocol.tokenizeSuccessResponse(tokens: -5, allocatedPositions: 32_000)
      let zeroObj = try XCTUnwrap(JSONSerialization.jsonObject(with: zeroData) as? [String: Any])
      XCTAssertEqual(zeroObj["tokens"] as? Int, 0)
      XCTAssertEqual(zeroObj["allocated_positions"] as? Int, 32_000)
    }

    // MARK: - Prefix-KV extension matching vs invalidation

    private func makeSessionConfig(
      systemPrompt: String = "You are Agello.",
      enableThinking: Bool = false,
      toolsSignature: String = "",
      useMTP: Bool = true,
      seed: Int = 0
    ) -> ServeSessionConfig {
      ServeSessionConfig(
        systemPrompt: systemPrompt,
        toolsSignature: toolsSignature,
        enableThinking: enableThinking,
        useMTP: useMTP,
        hasResponseFormat: false,
        topK: 1,
        seed: seed,
        topP: 1.0,
        temperature: 0.0
      )
    }

    func testPrefixExtensionMatchesMultiTurnAndMultiToolBatches() {
      let cfg = makeSessionConfig()
      let turn1Raw: [[String: Any]] = [
        ["role": "system", "content": "You are Agello."],
        ["role": "user", "content": "Plan a weekend in Montreal."],
      ]
      let cachedAfterTurn1 =
        ServeMessages.canonicalize(turn1Raw)
        + [ServeMessages.assistantServeMessage(text: "Visit Old Montreal.", toolCalls: [], requestIndex: 1)]

      let turn2Raw: [[String: Any]] = [
        ["role": "system", "content": "You are Agello."],
        ["role": "user", "content": "Plan a weekend in Montreal."],
        ["role": "assistant", "content": "Visit Old Montreal."],
        ["role": "user", "content": "Where should I get coffee?"],
      ]
      let incomingTurn2 = ServeMessages.canonicalize(turn2Raw)
      let match = ServeMessages.matchPrefix(
        cachedMessages: cachedAfterTurn1, cachedConfig: cfg,
        incomingMessages: incomingTurn2, incomingConfig: cfg)
      XCTAssertEqual(
        match,
        .reuse(delta: [ServeMessage(role: .user, parts: [.text("Where should I get coffee?")])])
      )

      // Multi-call tool round with reordered JSON argument keys still matches canonically.
      let nativeCalls = [
        LiteRTLM.ToolCall(name: "get_weather", id: "", arguments: ["city": "Montreal", "units": "metric"]),
        LiteRTLM.ToolCall(name: "calculator", id: "c_2", arguments: ["expr": "18 * 9 / 5 + 32"]),
      ]
      let cachedAfterToolRequest =
        ServeMessages.canonicalize(turn1Raw)
        + [ServeMessages.assistantServeMessage(text: "", toolCalls: nativeCalls, requestIndex: 7)]

      let round2Raw: [[String: Any]] = [
        ["role": "system", "content": "You are Agello."],
        ["role": "user", "content": "Plan a weekend in Montreal."],
        [
          "role": "assistant",
          "content": NSNull(),
          "tool_calls": [
            [
              "id": "call_7_0",
              "type": "function",
              "function": [
                "name": "get_weather",
                "arguments": #"{"units":"metric","city":"Montreal"}"#,
              ],
            ],
            [
              "id": "c_2",
              "type": "function",
              "function": [
                "name": "calculator",
                "arguments": #"{"expr":"18 * 9 / 5 + 32"}"#,
              ],
            ],
          ],
        ],
        ["role": "tool", "tool_call_id": "call_7_0", "name": "get_weather", "content": #"{"temp":18}"#],
        ["role": "tool", "tool_call_id": "c_2", "name": "calculator", "content": #"{"value":64.4}"#],
      ]
      let toolMatch = ServeMessages.matchPrefix(
        cachedMessages: cachedAfterToolRequest, cachedConfig: cfg,
        incomingMessages: ServeMessages.canonicalize(round2Raw), incomingConfig: cfg)
      if case .reuse(let delta) = toolMatch {
        XCTAssertEqual(delta.count, 2)
        XCTAssertTrue(delta.allSatisfy { $0.role == .tool })
      } else {
        XCTFail("Expected tool-response delta reuse, got \(toolMatch)")
      }
    }

    func testPrefixExtensionInvalidatesOnNewChatBranchEditRegenerateAndConfigChange() {
      let cfg = makeSessionConfig()
      let cached = ServeMessages.canonicalize([
        ["role": "system", "content": "You are Agello."],
        ["role": "user", "content": "First question"],
        ["role": "assistant", "content": "First answer"],
        ["role": "user", "content": "Second question"],
        ["role": "assistant", "content": "Second answer"],
      ])

      // 1. New chat (shorter history).
      let newChat = ServeMessages.canonicalize([
        ["role": "system", "content": "You are Agello."],
        ["role": "user", "content": "Brand new topic"],
      ])
      XCTAssertEqual(
        ServeMessages.matchPrefix(
          cachedMessages: cached, cachedConfig: cfg, incomingMessages: newChat, incomingConfig: cfg),
        .rebuild(reason: "not_extension")
      )

      // 2. Regenerate last turn (same length minus assistant reply).
      let regenerate = Array(cached.dropLast())
      XCTAssertEqual(
        ServeMessages.matchPrefix(
          cachedMessages: cached, cachedConfig: cfg, incomingMessages: regenerate, incomingConfig: cfg),
        .rebuild(reason: "not_extension")
      )

      // 3. Edit an earlier user message while appending a new turn (same prefix length + 1, mutated turn).
      let editedPrefix = ServeMessages.canonicalize([
        ["role": "system", "content": "You are Agello."],
        ["role": "user", "content": "First question EDITED"],
        ["role": "assistant", "content": "First answer"],
        ["role": "user", "content": "Second question"],
        ["role": "assistant", "content": "Second answer"],
        ["role": "user", "content": "Third question"],
      ])
      XCTAssertEqual(
        ServeMessages.matchPrefix(
          cachedMessages: cached, cachedConfig: cfg, incomingMessages: editedPrefix, incomingConfig: cfg),
        .rebuild(reason: "prefix_mismatch")
      )

      // 4. System prompt / Think / tools / sampling seed config changes invalidate reuse.
      let validNext = cached + [ServeMessage(role: .user, parts: [.text("Third question")])]
      XCTAssertEqual(
        ServeMessages.matchPrefix(
          cachedMessages: cached, cachedConfig: cfg,
          incomingMessages: validNext, incomingConfig: makeSessionConfig(systemPrompt: "Changed")),
        .rebuild(reason: "config_changed")
      )
      XCTAssertEqual(
        ServeMessages.matchPrefix(
          cachedMessages: cached, cachedConfig: cfg,
          incomingMessages: validNext, incomingConfig: makeSessionConfig(enableThinking: true)),
        .rebuild(reason: "config_changed")
      )
      XCTAssertEqual(
        ServeMessages.matchPrefix(
          cachedMessages: cached, cachedConfig: cfg,
          incomingMessages: validNext, incomingConfig: makeSessionConfig(toolsSignature: #"[{"name":"x"}]"#)),
        .rebuild(reason: "config_changed")
      )
      XCTAssertEqual(
        ServeMessages.matchPrefix(
          cachedMessages: cached, cachedConfig: cfg,
          incomingMessages: validNext, incomingConfig: makeSessionConfig(useMTP: false, seed: 42)),
        .rebuild(reason: "config_changed")
      )

      // 5. Multi-turn jump (`[u3, a3, u4]`) cannot be sent in a single `sendMessage` -> rebuild.
      let multiTurnJump =
        cached
        + [
          ServeMessage(role: .user, parts: [.text("Q3")]),
          ServeMessage(role: .assistant, parts: [.text("A3")]),
          ServeMessage(role: .user, parts: [.text("Q4")]),
        ]
      XCTAssertEqual(
        ServeMessages.matchPrefix(
          cachedMessages: cached, cachedConfig: cfg,
          incomingMessages: multiTurnJump, incomingConfig: cfg),
        .rebuild(reason: "unsupported_delta")
      )
    }

    func testCanonicalToolsSignatureIsOrderIndependent() {
      let toolsA: [[String: Any]] = [
        ["type": "function", "function": ["name": "calc", "description": "Math"]],
      ]
      let toolsB: [[String: Any]] = [
        ["function": ["description": "Math", "name": "calc"], "type": "function"],
      ]
      let sigA = ServeMessages.canonicalToolsSignature(toolsA)
      let sigB = ServeMessages.canonicalToolsSignature(toolsB)
      XCTAssertFalse(sigA.isEmpty)
      XCTAssertEqual(sigA, sigB)
      XCTAssertEqual(ServeMessages.canonicalToolsSignature(nil), "")
      XCTAssertEqual(ServeMessages.canonicalToolsSignature([]), "")
    }

    // MARK: - ServeTurnQueue strict FIFO serialization

    func testServeTurnQueueSerializesConcurrentRequestsInFIFOOrder() async {
      let queue = ServeTurnQueue()
      let recorder = EventLog()

      let firstEntered = expectation(description: "first entered")
      let releaseFirst = AsyncGate()

      let t0 = Task {
        await queue.run {
          recorder.append("enter-0")
          firstEntered.fulfill()
          await releaseFirst.wait()
          recorder.append("exit-0")
        }
      }
      await fulfillment(of: [firstEntered], timeout: 2.0)

      // Enqueue 1, 2 (throws), and 3 in strict arrival order while 0 holds the turn slot.
      var tasks: [Task<Void, Never>] = []
      for idx in 1...3 {
        let enqueued = expectation(description: "enqueued-\(idx)")
        let task = Task {
          enqueued.fulfill()
          try? await queue.run {
            recorder.append("enter-\(idx)")
            try await Task.sleep(for: .milliseconds(10))
            if idx == 2 {
              recorder.append("throw-2")
              throw URLError(.cannotConnectToHost)
            }
            recorder.append("exit-\(idx)")
          }
        }
        tasks.append(task)
        await fulfillment(of: [enqueued], timeout: 2.0)
        try? await Task.sleep(for: .milliseconds(15))
      }

      await releaseFirst.open()
      await t0.value
      for task in tasks { await task.value }

      XCTAssertEqual(
        recorder.snapshot(),
        ["enter-0", "exit-0", "enter-1", "exit-1", "enter-2", "throw-2", "enter-3", "exit-3"]
      )
    }

    // MARK: - HTTP 413, chunked limits & OpenAI 64-bit integer clamping

    func testHTTPHeaderAndChunkedLimitsReturn413OnOverflow() throws {
      let exactLimitHeader = "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: \(Serve.maxRequestBodyBytes)"
      if case .success(let ok) = Serve.parseHeaders(exactLimitHeader) {
        XCTAssertEqual(ok.contentLength, Serve.maxRequestBodyBytes)
      } else {
        XCTFail("Exact 64 MiB boundary must be accepted")
      }

      let overByOne = "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: \(Serve.maxRequestBodyBytes + 1)"
      XCTAssertEqual(Serve.parseHeaders(overByOne), .failure(.payloadTooLarge))

      let huge128Bit = "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 99999999999999999999999999"
      XCTAssertEqual(Serve.parseHeaders(huge128Bit), .failure(.payloadTooLarge))

      let negativeLen = "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: -42"
      XCTAssertEqual(Serve.parseHeaders(negativeLen), .failure(.invalidContentLength))

      let conflictingLen = "POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 10\r\nContent-Length: 20"
      XCTAssertEqual(Serve.parseHeaders(conflictingLen), .failure(.invalidContentLength))

      // Chunked decoder enforces maxBytes strictly.
      let validChunked = Data("5\r\nhello\r\n0\r\n\r\n".utf8)
      XCTAssertEqual(Serve.decodeChunked(validChunked, maxBytes: 5), .success(Data("hello".utf8)))
      XCTAssertEqual(Serve.decodeChunked(validChunked, maxBytes: 4), .failure(.payloadTooLarge))

      // End-to-end socketpair verification of HTTP 413 Payload Too Large framing.
      var fds: [Int32] = [-1, -1]
      XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
      defer {
        if fds[0] >= 0 { close(fds[0]) }
        if fds[1] >= 0 { close(fds[1]) }
      }
      Serve.configureClientSocket(fds[0])
      Serve.configureClientSocket(fds[1])

      let oversizedWire = Data(
        "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(Serve.maxRequestBodyBytes + 4096)\r\n\r\n"
          .utf8)
      XCTAssertTrue(Serve.writeBytes(fds[0], oversizedWire))
      let outcome = Serve.readHTTPRequestSync(fds[1])
      XCTAssertEqual(outcome, .payloadTooLarge)

      Serve.writePayloadTooLarge(fds[1])
      close(fds[1])
      fds[1] = -1

      let rawResponse = readAllBytes(fds[0])
      let responseText = try XCTUnwrap(String(data: rawResponse, encoding: .utf8))
      XCTAssertTrue(responseText.hasPrefix("HTTP/1.1 413 Payload Too Large\r\n"))
      let bodyStart = try XCTUnwrap(responseText.range(of: "\r\n\r\n")).upperBound
      let errJSON = try XCTUnwrap(
        JSONSerialization.jsonObject(with: Data(responseText[bodyStart...].utf8)) as? [String: Any])
      let errObj = try XCTUnwrap(errJSON["error"] as? [String: Any])
      XCTAssertEqual(errObj["type"] as? String, "invalid_request_error")
    }

    func testOpenAI64BitIntegerClampingAndExplicitThinkingBudget() {
      let body: [String: Any] = [
        "model": "google/gemma-4-E4B-it",
        "max_tokens": Int.max,
        "top_k": Int.max,
        "seed": Int.max,
        "temperature": 0.5,
        "stop": ["</end>", ""],
        "chat_template_kwargs": [
          "enable_thinking": true,
          "thinking_budget": 1_536,
        ],
      ]
      let req = ServeProtocol.parseRequest(body: body, prefix: [], options: Serve.Options())
      XCTAssertEqual(req.requestedMax, ServeProtocol.maxClampedTokens)
      XCTAssertEqual(req.topK, ServeProtocol.maxClampedTopK)
      XCTAssertEqual(req.seed, Int(Int32.max))
      XCTAssertNotNil(Int32(exactly: req.requestedMax))
      XCTAssertNotNil(Int32(exactly: req.topK))
      XCTAssertNotNil(Int32(exactly: req.seed))
      XCTAssertTrue(req.enableThinking)
      XCTAssertEqual(req.thinkingBudget, 1_536)
      XCTAssertEqual(req.stopStrings, ["</end>"])

      // Booleans must never bridge as NSNumber integers (1 / 0).
      let boolBody: [String: Any] = [
        "max_tokens": true,
        "seed": true,
        "top_k": false,
      ]
      let boolReq = ServeProtocol.parseRequest(body: boolBody, prefix: [], options: Serve.Options())
      XCTAssertEqual(boolReq.requestedMax, 4_096)
      XCTAssertEqual(boolReq.seed, 0)
      XCTAssertEqual(boolReq.topK, 1)
    }

    // MARK: - SSE error halt, [DONE] EOF enforcement & streaming stop sequences

    func testSSEErrorHaltsWithoutDoneAndSSEConsumerEnforcesDoneMarker() throws {
      // 1. Mid-stream error frame over socketpair emits error JSON without trailing [DONE].
      var fds: [Int32] = [-1, -1]
      XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
      defer {
        if fds[0] >= 0 { close(fds[0]) }
        if fds[1] >= 0 { close(fds[1]) }
      }
      XCTAssertTrue(Serve.writeSSEHeaders(fds[1]))
      XCTAssertTrue(
        Serve.writeSSEObject(
          fds[1],
          [
            "id": "chatcmpl-1",
            "choices": [["index": 0, "delta": ["content": "Partial "], "finish_reason": NSNull()]],
          ]))
      XCTAssertTrue(ServeProtocol.writeSSEErrorAndHalt(fd: fds[1], message: "GPU decode aborted"))
      close(fds[1])
      fds[1] = -1

      let raw = try XCTUnwrap(String(data: readAllBytes(fds[0]), encoding: .utf8))
      XCTAssertFalse(raw.contains("[DONE]"), "SSE error path must halt immediately without [DONE]")
      let lines = raw.components(separatedBy: "\n")
      XCTAssertThrowsError(try consumeSSELines(lines)) { error in
        XCTAssertEqual(error as? ChatError, .underlying(message: "GPU decode aborted"))
      }

      // 2. Premature EOF (no error frame, no [DONE]) must throw rather than succeeding silently.
      let truncatedLines = [
        #"data: {"id":"1","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}"#,
        "",
      ]
      XCTAssertThrowsError(try consumeSSELines(truncatedLines)) { error in
        XCTAssertEqual(
          error as? ChatError,
          .underlying(message: "agello serve stream ended before [DONE].")
        )
      }

      // 3. Clean stream ending with `data: [DONE]` succeeds and surfaces `kv_reused` + `finishReason`.
      let completeLines = [
        #"data: {"id":"1","choices":[{"index":0,"delta":{"reasoning":"plan","content":"Hi "},"finish_reason":null}]}"#,
        #"data: {"id":"1","choices":[{"index":0,"delta":{"content":"there"},"finish_reason":null}]}"#,
        #"data: {"id":"1","choices":[{"index":0,"delta":{},"finish_reason":"length"}],"usage":{"prompt_tokens":12,"completion_tokens":20},"kv_reused":true}"#,
        "data: [DONE]",
      ]
      let parsed = try consumeSSELines(completeLines)
      XCTAssertEqual(parsed.text, "Hi there")
      XCTAssertEqual(parsed.thought, "plan")
      XCTAssertEqual(parsed.finishReason, "length")
      XCTAssertEqual(parsed.promptTokens, 12)
      XCTAssertEqual(parsed.completionTokens, 20)
      XCTAssertEqual(parsed.kvReused, true)
    }

    func testStreamingStopFilterCutsStopSequenceAcrossChunkBoundaries() {
      var filter = ServeProtocol.StreamingStopFilter(stopStrings: ["</answer>", "\nUser:"])
      var output = ""

      let r1 = filter.push(" Value is 42</")
      output += r1.emitted
      XCTAssertFalse(r1.stopped)
      XCTAssertEqual(output, " Value is 42")

      let r2 = filter.push("ans")
      output += r2.emitted
      XCTAssertFalse(r2.stopped)
      XCTAssertEqual(output, " Value is 42")

      let r3 = filter.push("wer>ignored trailing text")
      output += r3.emitted
      XCTAssertTrue(r3.stopped)
      XCTAssertEqual(output, " Value is 42")
      XCTAssertEqual(filter.matchedStop, "</answer>")
      XCTAssertEqual(filter.flush(), "")
    }

    // MARK: - /v1/embeddings index sorting & WAV audio duration estimation

    func testEmbeddingsDecoderSortsByIndexAndValidatesExpectedCount() throws {
      let outOfOrder: [String: Any] = [
        "object": "list",
        "data": [
          ["object": "embedding", "index": 2, "embedding": [0.2, 2.0]],
          ["object": "embedding", "index": 0, "embedding": [0.0, 0.5]],
          ["object": "embedding", "index": 1, "embedding": [0.1, 1.5]],
        ],
      ]
      let data = try JSONSerialization.data(withJSONObject: outOfOrder)
      let sorted = try decodeEmbeddingsPayload(data, expectedCount: 3)
      XCTAssertEqual(sorted.count, 3)
      XCTAssertEqual(sorted[0], [Float(0.0), Float(0.5)])
      XCTAssertEqual(sorted[1], [Float(0.1), Float(1.5)])
      XCTAssertEqual(sorted[2], [Float(0.2), Float(2.0)])

      XCTAssertThrowsError(try decodeEmbeddingsPayload(data, expectedCount: 4))
    }

    func testWAVAudioDurationEstimationUsesDecodedDuration() {
      // 4 seconds of 8 kHz 8-bit mono PCM (byteRate = 8,000, data = 32,000 bytes -> 100 tokens @ 25 tok/s).
      var wav = Data()
      let dataSize: UInt32 = 32_000
      let riffSize: UInt32 = 36 + dataSize
      wav.append(Data("RIFF".utf8))
      withUnsafeBytes(of: riffSize.littleEndian) { wav.append(contentsOf: $0) }
      wav.append(Data("WAVEfmt ".utf8))
      withUnsafeBytes(of: UInt32(16).littleEndian) { wav.append(contentsOf: $0) }
      withUnsafeBytes(of: UInt16(1).littleEndian) { wav.append(contentsOf: $0) }  // PCM
      withUnsafeBytes(of: UInt16(1).littleEndian) { wav.append(contentsOf: $0) }  // mono
      withUnsafeBytes(of: UInt32(8_000).littleEndian) { wav.append(contentsOf: $0) }  // 8 kHz
      withUnsafeBytes(of: UInt32(8_000).littleEndian) { wav.append(contentsOf: $0) }  // byteRate
      withUnsafeBytes(of: UInt16(1).littleEndian) { wav.append(contentsOf: $0) }  // blockAlign
      withUnsafeBytes(of: UInt16(8).littleEndian) { wav.append(contentsOf: $0) }  // bitsPerSample
      wav.append(Data("data".utf8))
      withUnsafeBytes(of: dataSize.littleEndian) { wav.append(contentsOf: $0) }
      wav.append(Data(repeating: 0x80, count: Int(dataSize)))

      XCTAssertEqual(ServeMessages.estimateAudioTokens(wav), 100)
    }

    // MARK: - Socket helpers

    private func readAllBytes(_ fd: Int32) -> Data {
      var out = Data()
      var buf = [UInt8](repeating: 0, count: 4096)
      while true {
        let n = Darwin.read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(buf, count: n)
      }
      return out
    }

    private struct ParsedSSE: Equatable {
      let text: String
      let thought: String
      let finishReason: String
      let promptTokens: Int?
      let completionTokens: Int?
      let kvReused: Bool?
    }

    private func consumeSSELines(_ lines: [String]) throws -> ParsedSSE {
      var text = "", thought = "", finishReason = "stop"
      var promptTokens: Int?, completionTokens: Int?, kvReused: Bool?
      var sawDone = false
      for line in lines {
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard trimmed.hasPrefix("data:") else { continue }
        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
          sawDone = true
          break
        }
        guard let data = payload.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { continue }
        if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
          throw ChatError.underlying(message: msg)
        }
        if let usage = obj["usage"] as? [String: Any] {
          promptTokens = usage["prompt_tokens"] as? Int
          completionTokens = usage["completion_tokens"] as? Int
        }
        if let flag = obj["kv_reused"] as? Bool { kvReused = flag }
        guard let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
        if let reason = choice["finish_reason"] as? String { finishReason = reason }
        guard let delta = choice["delta"] as? [String: Any] else { continue }
        let textDelta = (delta["content"] as? String) ?? ""
        let thoughtDelta = (delta["reasoning"] as? String) ?? (delta["reasoning_content"] as? String)
        if !textDelta.isEmpty || (thoughtDelta != nil && !(thoughtDelta?.isEmpty ?? true)) {
          text += textDelta
          if let thoughtDelta { thought += thoughtDelta }
        }
      }
      guard sawDone else {
        throw ChatError.underlying(message: "agello serve stream ended before [DONE].")
      }
      return ParsedSSE(
        text: text, thought: thought, finishReason: finishReason,
        promptTokens: promptTokens, completionTokens: completionTokens, kvReused: kvReused)
    }

    private func decodeEmbeddingsPayload(_ data: Data, expectedCount: Int) throws -> [[Float]] {
      guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let rows = json["data"] as? [[String: Any]]
      else { throw ChatError.underlying(message: "Malformed /v1/embeddings response.") }
      var indexed: [(index: Int, order: Int, vector: [Float])] = []
      for (order, row) in rows.enumerated() {
        let nums = try XCTUnwrap(row["embedding"] as? [NSNumber])
        let vec = nums.map(\.floatValue)
        let idx = ServeProtocol.clampedInt(row["index"], min: 0, max: 262_144) ?? order
        indexed.append((index: idx, order: order, vector: vec))
      }
      indexed.sort { $0.index != $1.index ? $0.index < $1.index : $0.order < $1.order }
      let vectors = indexed.map(\.vector)
      guard vectors.count == expectedCount else {
        throw ChatError.underlying(
          message: "Expected \(expectedCount) embeddings, received \(vectors.count).")
      }
      return vectors
    }
  #endif
}

#if os(macOS)
  private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func append(_ value: String) {
      lock.lock()
      items.append(value)
      lock.unlock()
    }

    func snapshot() -> [String] {
      lock.lock()
      defer { lock.unlock() }
      return items
    }
  }

  private actor AsyncGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
      if isOpen { return }
      await withCheckedContinuation { waiter = $0 }
    }

    func open() {
      isOpen = true
      waiter?.resume()
      waiter = nil
    }
  }
#endif
