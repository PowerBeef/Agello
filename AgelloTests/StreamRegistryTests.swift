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
    harness.deliver(toolCall)
    harness.deliver(StreamChunk(isFinal: true))
    await waitUntil { harness.toolRoundsStarted == 1 }
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
}
