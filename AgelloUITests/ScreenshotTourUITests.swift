import XCTest

/// Opt-in (`scripts/device-harness.sh screenshots`): a guided tour of the
/// app with the real model and realistic prompts, attaching one screenshot
/// per screen for the README and the App Store. Not a correctness test.
@MainActor
final class ScreenshotTourUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() async throws {
    continueAfterFailure = true
    guard ProcessInfo.processInfo.environment["HARNESS_SCREENSHOTS"] == "1" else {
      throw XCTSkip("Set TEST_RUNNER_HARNESS_SCREENSHOTS=1 (the screenshots suite) to run the tour")
    }
    app = XCUIApplication()
  }

  func testTour() throws {
    // 1. A fresh start: chats, a reasoning answer, a web answer, the drawer,
    //    Settings and Models. From the Home Screen, so the status bar has no
    //    back link to the app that was open.
    XCUIDevice.shared.press(.home)
    launch(["--uitest-reset"])
    try waitForEngineReady()
    capture("01-new-chat")

    ask("Explain how a Bloom filter works, with a short Swift example and a comparison table.")
    try waitForReplyToFinish(timeout: 300)
    scrollToTop()
    capture("02-rich-answer")

    newChat()
    element("composer.think").tap()
    ask("Dinner was $86.40. What's an 18% tip, and what does each of us pay if we split it three ways?")
    try waitForReplyToFinish(timeout: 400)
    capture("03-think-and-tools")
    element("composer.think").tap()

    newChat()
    if element("composer.search").exists {
      element("composer.search").tap()
      ask("Who won the 2026 Tour de France?")
      try waitForReplyToFinish(timeout: 300)
      scrollToTop()
      capture("04-web-search")
    }

    newChat()
    openDrawer()
    capture("05-drawer")
    element("drawer.settings").tap()
    XCTAssertTrue(element("settings.done").waitForExistence(timeout: 5))
    usleep(600_000)
    capture("06-settings")
    element("settings.models").tap()
    XCTAssertTrue(element("models.ready.e4b").waitForExistence(timeout: 5))
    capture("07-models")

    // 2. A long document, summarized with its sources.
    app.terminate()
    launch(["--uitest-sample-report"])
    try waitForEngineReady()
    XCTAssertTrue(element("message.file").waitForExistence(timeout: 10), "Sample report not attached")
    ask("Summarize this report in three short bullet points.")
    try waitForReplyToFinish(timeout: 400)
    scrollToTop()
    capture("08-document")

    // 3. Voice mode.
    app.terminate()
    launch(["--uitest-fake-mic"])
    newChat()
    let voice = element("composer.voice")
    XCTAssertTrue(voice.waitForExistence(timeout: 10))
    voice.tap()
    XCTAssertTrue(element("voice.state").waitForExistence(timeout: 10))
    sleep(2)
    capture("09-voice")
    element("voice.end").tap()
  }

  // MARK: - Helpers

  private func launch(_ arguments: [String]) {
    app.launchArguments = arguments
    app.launch()
    XCTAssertTrue(element("chat.input").waitForExistence(timeout: 15), "Chat not shown")
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func waitForEngineReady(timeout: TimeInterval = 180) throws {
    if element("chat.banner.download").waitForExistence(timeout: 2) {
      throw XCTSkip("Model not downloaded")
    }
    let loading = element("chat.banner.loading")
    if loading.exists {
      XCTAssertTrue(loading.waitForNonExistence(timeout: timeout), "Model load timed out")
    }
  }

  private func ask(_ text: String) {
    let input = element("chat.input")
    input.tap()
    input.typeText(text)
    element("chat.send").tap()
  }

  private func waitForReplyToFinish(timeout: TimeInterval) throws {
    _ = element("chat.stop").waitForExistence(timeout: 15)
    XCTAssertTrue(element("chat.stop").waitForNonExistence(timeout: timeout), "Reply did not finish")
    // Let the title, sources and action row settle.
    sleep(2)
  }

  private func newChat() {
    element("chat.new").tap()
    XCTAssertTrue(element("chat.empty").waitForExistence(timeout: 5))
  }

  private func openDrawer() {
    element("chat.drawer").tap()
    XCTAssertTrue(element("drawer.search").waitForExistence(timeout: 5))
    usleep(700_000)
  }

  /// Show the question as well as the answer.
  private func scrollToTop() {
    for _ in 0..<8 { app.swipeDown(velocity: .fast) }
    usleep(800_000)
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "tour-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
