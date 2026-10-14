import XCTest

@testable import Agello

final class StreamAccumulatorTests: XCTestCase {
  func testAppendsTextDeltas() {
    var acc = StreamAccumulator()
    acc.append(ChatChunk(textDelta: "Hello", thoughtDelta: nil))
    acc.append(ChatChunk(textDelta: " world", thoughtDelta: nil))
    XCTAssertEqual(acc.text, "Hello world")
    XCTAssertFalse(acc.hasThought)
  }

  func testThoughtOnlyChunks() {
    var acc = StreamAccumulator()
    acc.append(ChatChunk(textDelta: "", thoughtDelta: "Drafting"))
    acc.append(ChatChunk(textDelta: "Hi", thoughtDelta: " a reply"))
    XCTAssertEqual(acc.text, "Hi")
    XCTAssertEqual(acc.thought, "Drafting a reply")
    XCTAssertTrue(acc.hasThought)
  }

  func testToolNamesDeduplicated() {
    var acc = StreamAccumulator()
    acc.append(ChatChunk(textDelta: "", thoughtDelta: nil, toolNames: ["calculate"]))
    acc.append(ChatChunk(textDelta: "done", thoughtDelta: nil, toolNames: ["calculate"]))
    XCTAssertEqual(acc.toolNames, ["calculate"])
  }

  func testEmptyChunkIsNoOp() {
    var acc = StreamAccumulator()
    acc.append(.empty)
    XCTAssertEqual(acc, StreamAccumulator())
  }
}
