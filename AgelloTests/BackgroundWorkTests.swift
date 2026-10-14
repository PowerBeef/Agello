import BackgroundTasks
import XCTest

@testable import Agello

/// The continued processing task that long summaries run under. The test
/// host is in the foreground, so iOS can start it right away.
@MainActor
final class BackgroundWorkTests: XCTestCase {
  func testContinuedTaskStarts() async throws {
    // The iPhone 17 Pro on iOS 27 reports no resources.
    try XCTSkipUnless(
      BackgroundWork.supportsBackgroundGPU,
      "No background GPU for continued tasks (resources \(BGTaskScheduler.supportedResources.rawValue))")
    let work = BackgroundWork.shared
    work.begin(title: "Background test", subtitle: "Starting")
    defer { work.end(success: true) }
    for _ in 0..<50 where !work.isActive {
      try await Task.sleep(for: .milliseconds(100))
    }
    XCTAssertTrue(work.isActive, "iOS didn't start the continued task: \(work.lastFailure ?? "no error")")
  }
}
