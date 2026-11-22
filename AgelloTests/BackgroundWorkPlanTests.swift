import XCTest

@testable import Agello

final class BackgroundWorkPlanTests: XCTestCase {
  func testContinuedTaskEligibilityKeepsPlainChatForegroundOnly() {
    XCTAssertFalse(
      BackgroundWorkPlan.shouldUseContinuedTask(
        documentCount: 0, wantsSummary: false, webSearch: false, multiStepTool: false))
    XCTAssertFalse(
      BackgroundWorkPlan.shouldUseContinuedTask(
        documentCount: 1, wantsSummary: false, webSearch: false, multiStepTool: false))
    XCTAssertTrue(
      BackgroundWorkPlan.shouldUseContinuedTask(
        documentCount: 1, wantsSummary: true, webSearch: false, multiStepTool: false))
    XCTAssertTrue(
      BackgroundWorkPlan.shouldUseContinuedTask(
        documentCount: 2, wantsSummary: false, webSearch: false, multiStepTool: false))
    XCTAssertTrue(
      BackgroundWorkPlan.shouldUseContinuedTask(
        documentCount: 0, wantsSummary: false, webSearch: true, multiStepTool: false))
    XCTAssertTrue(
      BackgroundWorkPlan.shouldUseContinuedTask(
        documentCount: 0, wantsSummary: false, webSearch: false, multiStepTool: true))
  }

  func testMultiDocumentSectionProgressSpansZeroToEightyMonotonically() {
    var previous: Int64 = 0
    for doc in 0..<3 {
      for section in 0...4 {
        let units = BackgroundWorkPlan.documentSectionUnits(
          documentIndex: doc, documentCount: 3, sectionCompleted: section, sectionTotal: 4)
        XCTAssertGreaterThanOrEqual(units, previous)
        XCTAssertLessThanOrEqual(units, 80)
        previous = units
      }
    }
    XCTAssertEqual(previous, 80)
  }

  func testStepAndReplyProgressNeverMoveBackward() {
    let s1 = BackgroundWorkPlan.stepUnits(completed: 1, total: 4)
    let s2 = BackgroundWorkPlan.stepUnits(completed: 2, total: 4)
    let s4 = BackgroundWorkPlan.stepUnits(completed: 4, total: 4)
    XCTAssertEqual(s1, 20)
    XCTAssertEqual(s2, 40)
    XCTAssertEqual(s4, 80)

    // Streaming after an 80% preparation phase advances smoothly from 80 to 95.
    let r0 = BackgroundWorkPlan.replyUnits(characters: 0, currentUnits: 80)
    let rMid = BackgroundWorkPlan.replyUnits(characters: 750, currentUnits: r0)
    let rEnd = BackgroundWorkPlan.replyUnits(characters: 3_000, currentUnits: rMid)
    XCTAssertEqual(r0, 80)
    XCTAssertGreaterThan(rMid, r0)
    XCTAssertLessThan(rMid, 95)
    XCTAssertEqual(rEnd, 95)
  }

  func testDocumentSubtitlesDistinguishSingleAndMultiDocumentRuns() {
    XCTAssertEqual(
      BackgroundWorkPlan.documentSubtitle(
        name: "report.pdf", documentIndex: 0, documentCount: 1, section: 2, totalSections: 5),
      "Reading report.pdf · part 2 of 5")
    XCTAssertEqual(
      BackgroundWorkPlan.documentSubtitle(
        name: "q4.pdf", documentIndex: 1, documentCount: 3, section: 3, totalSections: 6),
      "Document 2 of 3 · q4.pdf · part 3 of 6")
  }
}
