import XCTest

/// The hardware floor (12 GB of memory, 2026-11-10): an iPhone below it sees one screen and no
/// chat. `AGELLO_SIMULATE_MEMORY_GB` stands in for an 8 GB iPhone.
@MainActor
final class DeviceFloorUITests: XCTestCase {
  func testAnEightGigabyteIPhoneSeesTheFloorScreen() {
    let app = XCUIApplication()
    app.launchEnvironment["AGELLO_SIMULATE_MEMORY_GB"] = "8"
    app.launch()
    let title = app.descendants(matching: .any).matching(identifier: "unsupported.title").firstMatch
    XCTAssertTrue(title.waitForExistence(timeout: 15), "No floor screen with 8 GB")
    let detail = app.descendants(matching: .any).matching(identifier: "unsupported.detail").firstMatch
    XCTAssertTrue(detail.label.contains("8 GB"), detail.label)
    XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "chat.input").firstMatch.exists)
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "device-floor"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testThisIPhoneRunsTheApp() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(
      app.descendants(matching: .any).matching(identifier: "chat.input").firstMatch.waitForExistence(timeout: 20),
      "The app didn't open on a supported iPhone")
  }
}
