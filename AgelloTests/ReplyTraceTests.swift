import XCTest

@testable import Agello

final class ReplyTraceTests: XCTestCase {
  /// Why a reply ended, for the harness's reports: a finished reply carries stats; the others
  /// are told apart by the message the app shows (none for Stop).
  func testEndReason() {
    var stats = GenerationStats(totalTime: 1, backend: "GPU", modelID: .e4b)
    XCTAssertEqual(ReplyTrace.endReason(stats: stats, error: nil), .model)
    stats.reachedLimit = true
    XCTAssertEqual(ReplyTrace.endReason(stats: stats, error: nil), .outputCap)
    XCTAssertEqual(ReplyTrace.endReason(stats: nil, error: nil), .stopped)
    XCTAssertEqual(
      ReplyTrace.endReason(stats: nil, error: "Reply stopped to free memory. Closing other apps can help."), .memory)
    XCTAssertEqual(
      ReplyTrace.endReason(stats: nil, error: "Agello moved to the background; it will continue when you return."),
      .background)
    XCTAssertEqual(
      ReplyTrace.endReason(stats: nil, error: ChatError.replyTruncated.displayMessage), .truncated)
    XCTAssertEqual(ReplyTrace.endReason(stats: nil, error: "The model failed."), .error)
  }

  /// Off without `--trace`: the unit tests' host never writes a trace.
  func testOffByDefault() {
    XCTAssertFalse(ReplyTrace.isEnabled)
    ReplyTrace.mark("nothing")
    ReplyTrace.end(text: "", thought: "", stats: nil, error: nil, notice: nil)
  }
}
