import XCTest

@_spi(Testing) import LiteRTLM

/// The LiteRT-LM wrapper's stream state, driven the way LiteRT-LM drives it: a rejected tool
/// call reports up to three final errors for one send, text can follow an error, and a late
/// chunk can arrive for a send that already ended. Before the registry, the second final
/// released freed memory (use-after-free in what shipped).
final class StreamRegistryTests: XCTestCase {
  private func text(_ value: String) -> StreamChunk {
    StreamChunk(text: #"{"role":"assistant","content":[{"type":"text","text":"\#(value)"}]}"#)
  }

  private let toolCall = StreamChunk(
    text: #"{"role":"assistant","tool_calls":[{"type":"function","function":{"name":"calculator","arguments":{"expression":"2+2"}}}]}"#
  )

  private struct Outcome {
    var texts: [String] = []
    var error: Error?
  }

  private func drain(_ stream: AsyncThrowingStream<Message, Error>) async -> Outcome {
    var outcome = Outcome()
    do {
      for try await message in stream { outcome.texts.append(message.toString) }
    } catch {
      outcome.error = error
    }
    return outcome
  }

  private func waitUntil(
    timeout: Duration = .seconds(2), _ condition: @escaping @Sendable () -> Bool
  ) async {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
  }

  func testTextThenFinalFinishesOnceAndRetiresTheSend() async {
    let harness = StreamTestHarness()
    let id = harness.currentID
    harness.deliver(text("Hello"))
    harness.deliver(text(" there"))
    harness.deliver(StreamChunk(isFinal: true))
    let outcome = await drain(harness.stream)
    XCTAssertEqual(outcome.texts, ["Hello", " there"])
    XCTAssertNil(outcome.error)
    XCTAssertFalse(harness.isRegistered(id))
  }

  func testRepeatedErrorFinalsEndTheStreamOnce() async {
    let harness = StreamTestHarness()
    let id = harness.currentID
    harness.deliver(text("Partial"))
    // Mid-stream parse error, the flush, then the final parse: three finals for one send.
    harness.deliver(StreamChunk(isFinal: true, error: "INVALID_ARGUMENT: tool call"))
    harness.deliver(StreamChunk(isFinal: true, error: "INVALID_ARGUMENT: tool call"))
    harness.deliver(StreamChunk(isFinal: true, error: "INVALID_ARGUMENT: tool call"))
    let outcome = await drain(harness.stream)
    XCTAssertEqual(outcome.texts, ["Partial"])
    XCTAssertNotNil(outcome.error)
    XCTAssertTrue(harness.isFinished)
    XCTAssertFalse(harness.isRegistered(id))
  }

  func testTextAfterAnErrorIsDropped() async {
    let harness = StreamTestHarness()
    harness.deliver(StreamChunk(isFinal: true, error: "INVALID_ARGUMENT"))
    harness.deliver(text("decoding went on"))
    harness.deliver(StreamChunk(isFinal: true))
    let outcome = await drain(harness.stream)
    XCTAssertEqual(outcome.texts, [])
    XCTAssertNotNil(outcome.error)
  }

  func testAChunkForAnUnknownSendIsIgnored() {
    let harness = StreamTestHarness()
    harness.deliver(StreamChunk(isFinal: true, error: "late"), to: UInt.max - 1)
    XCTAssertFalse(harness.isFinished)
    harness.deliver(StreamChunk(isFinal: true))
    XCTAssertTrue(harness.isFinished)
  }

  func testAnUnreadableChunkEndsTheStreamAndStopsTheNativeWork() async {
    let harness = StreamTestHarness()
    harness.deliver(StreamChunk(text: "not json"))
    harness.deliver(text("still decoding"))
    harness.deliver(StreamChunk(isFinal: true))
    let outcome = await drain(harness.stream)
    XCTAssertEqual(outcome.texts, [])
    XCTAssertNotNil(outcome.error)
    await waitUntil { harness.cancelNativeCount == 1 }
    XCTAssertEqual(harness.cancelNativeCount, 1)
  }

  func testAToolRoundRunsUnderANewSendAndIgnoresTheOldOne() async {
    let harness = StreamTestHarness()
    let firstID = harness.currentID
    harness.deliver(toolCall)
    harness.deliver(StreamChunk(isFinal: true))
    await waitUntil { harness.toolRoundsStarted == 1 && harness.currentID != firstID }
    XCTAssertEqual(harness.toolRoundsStarted, 1)
    let secondID = harness.currentID
    XCTAssertNotEqual(secondID, firstID)
    // A late final of round 1 must not end round 2.
    harness.deliver(StreamChunk(isFinal: true, error: "late"), to: firstID)
    XCTAssertFalse(harness.isFinished)
    harness.deliver(text("4"))
    harness.deliver(StreamChunk(isFinal: true))
    let outcome = await drain(harness.stream)
    XCTAssertEqual(outcome.texts, ["4"])
    XCTAssertNil(outcome.error)
    XCTAssertFalse(harness.isRegistered(secondID))
  }

  func testToolRoundsStopAtTheLimit() async {
    let harness = StreamTestHarness(maxToolRounds: 1)
    let firstID = harness.currentID
    harness.deliver(toolCall)
    harness.deliver(StreamChunk(isFinal: true))
    // The round is counted before its send registers: wait for both, or the next chunk can
    // reach the retired send.
    await waitUntil { harness.toolRoundsStarted == 1 && harness.currentID != firstID }
    harness.deliver(toolCall)
    harness.deliver(StreamChunk(isFinal: true))
    let outcome = await drain(harness.stream)
    guard case .conversation(.recurringToolCallLimitExceeded(let limit))? = outcome.error as? LiteRTLMError
    else {
      return XCTFail("expected the tool-round limit, got \(String(describing: outcome.error))")
    }
    XCTAssertEqual(limit, 1)
    XCTAssertEqual(harness.toolRoundsStarted, 1)
  }

  func testACancelledStreamStartsNoToolRound() async {
    let harness = StreamTestHarness()
    harness.deliver(toolCall)
    harness.cancel()
    harness.deliver(StreamChunk(isFinal: true))
    let outcome = await drain(harness.stream)
    XCTAssertTrue(outcome.error is CancellationError)
    XCTAssertEqual(harness.toolRoundsStarted, 0)
  }

  /// Cancelling while async app tool code executes (after round 1 retired, before round 2
  /// registers) must cancel the tool task and prevent round 2 from starting native GPU work.
  func testCancelDuringAsyncToolRoundStopsBeforeNextSend() async {
    final class Flag: @unchecked Sendable {
      private let lock = NSLock()
      private var _entered = false
      private var _taskCancelled = false
      var entered: Bool { lock.withLock { _entered } }
      var taskCancelled: Bool { lock.withLock { _taskCancelled } }
      func markEntered() { lock.withLock { _entered = true } }
      func markTaskCancelled() { lock.withLock { _taskCancelled = true } }
    }
    let flag = Flag()
    let harness = StreamTestHarness(onToolRound: {
      flag.markEntered()
      do {
        try await Task.sleep(for: .seconds(5))
      } catch {
        flag.markTaskCancelled()
        throw error
      }
    })
    let firstID = harness.currentID
    harness.deliver(toolCall)
    harness.deliver(StreamChunk(isFinal: true))
    await waitUntil { flag.entered && !harness.isRegistered(firstID) }
    XCTAssertTrue(flag.entered)
    XCTAssertFalse(harness.isRegistered(firstID))
    harness.cancel()
    let outcome = await drain(harness.stream)
    XCTAssertTrue(outcome.error is CancellationError)
    XCTAssertTrue(flag.taskCancelled)
    XCTAssertEqual(harness.toolRoundsStarted, 0)
  }

  func testAbandoningTheStreamStopsTheNativeWork() async {
    let harness = StreamTestHarness()
    let reader = Task {
      for try await _ in harness.stream {}
    }
    harness.deliver(text("Hello"))
    reader.cancel()
    await waitUntil { harness.cancelNativeCount == 1 }
    XCTAssertEqual(harness.cancelNativeCount, 1)
    // LiteRT-LM then reports the cancelled send; that final must not crash or yield.
    harness.deliver(StreamChunk(isFinal: true, error: "CANCELLED"))
    XCTAssertTrue(harness.isFinished)
  }

  /// Regression for R-10: round 1's `defer { endToolRound }` running after round 2 entered
  /// `beginToolRound` must not remove round 2 from `activeToolRounds` or defeat cancellation.
  func testEarlierToolRoundFinishDoesNotClearNewerToolRound() async {
    final class State: @unchecked Sendable {
      private let lock = NSLock()
      private var _roundCount = 0
      private var _round2Entered = false
      private var _round1Exited = false
      private var _round2Cancelled = false
      var harness: StreamTestHarness?
      func nextRound() -> Int {
        lock.withLock {
          _roundCount += 1
          return _roundCount
        }
      }
      var round2Entered: Bool { lock.withLock { _round2Entered } }
      var round1Exited: Bool { lock.withLock { _round1Exited } }
      var round2Cancelled: Bool { lock.withLock { _round2Cancelled } }
      func markRound2Entered() { lock.withLock { _round2Entered = true } }
      func markRound1Exited() { lock.withLock { _round1Exited = true } }
      func markRound2Cancelled() { lock.withLock { _round2Cancelled = true } }
    }
    let state = State()
    let toolChunk = toolCall
    let harness = StreamTestHarness(
      onToolRound: {
        let round = state.nextRound()
        if round == 2 {
          state.markRound2Entered()
          do {
            try await Task.sleep(for: .seconds(5))
          } catch {
            state.markRound2Cancelled()
            throw error
          }
        }
      },
      onAfterRegisterRound: {
        // While round 1's Task is still before its defer, deliver round 2's tool calls so
        // round 2 registers a newer generation in StreamTable.activeToolRounds first.
        guard !state.round2Entered, let h = state.harness else { return }
        h.deliver(toolChunk)
        h.deliver(StreamChunk(isFinal: true))
        let deadline = ContinuousClock().now + .seconds(2)
        while !state.round2Entered, ContinuousClock().now < deadline {
          try? await Task.sleep(for: .milliseconds(5))
        }
        state.markRound1Exited()
      }
    )
    state.harness = harness

    harness.deliver(toolChunk)
    harness.deliver(StreamChunk(isFinal: true))
    await waitUntil { state.round1Exited && state.round2Entered }
    // Give round 1's defer a moment to run; round 2 must remain tracked.
    try? await Task.sleep(for: .milliseconds(30))
    XCTAssertTrue(harness.hasActiveToolRound)
    harness.cancel()
    let outcome = await drain(harness.stream)
    XCTAssertTrue(outcome.error is CancellationError)
    XCTAssertTrue(state.round2Cancelled)
  }

  /// Regression for R-02: non-finite Double/Float/NSNumber values in tool output must be
  /// stringified before JSONSerialization so they never raise an ObjC NSInvalidArgumentException.
  func testToolManagerNormalizesNonFiniteFloatsToValidJSON() throws {
    let raw: [String: Any] = [
      "nan": Double.nan,
      "inf": Double.infinity,
      "negInf": -Double.infinity,
      "fnan": Float.nan,
      "finf": Float.infinity,
      "nsNan": NSNumber(value: Double.nan),
      "okBool": true,
      "okInt": 42,
      "okDouble": 3.5,
      "okNull": NSNull(),
      "nested": [Double.nan, 1.25, "text"] as [Any],
    ]
    let normalized = ToolManager.normalizeResult(raw)
    XCTAssertTrue(JSONSerialization.isValidJSONObject(normalized))
    let data = try JSONSerialization.data(withJSONObject: normalized)
    let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(decoded["nan"] as? String, "nan")
    XCTAssertEqual(decoded["inf"] as? String, "inf")
    XCTAssertEqual(decoded["negInf"] as? String, "-inf")
    XCTAssertEqual(decoded["fnan"] as? String, "nan")
    XCTAssertEqual(decoded["finf"] as? String, "inf")
    XCTAssertEqual(decoded["nsNan"] as? String, "nan")
    XCTAssertEqual(decoded["okBool"] as? Bool, true)
    XCTAssertEqual(decoded["okInt"] as? Int, 42)
    XCTAssertEqual(decoded["okDouble"] as? Double, 3.5)
    XCTAssertTrue(decoded["okNull"] is NSNull)
    let nested = try XCTUnwrap(decoded["nested"] as? [Any])
    XCTAssertEqual(nested.first as? String, "nan")
  }
}
