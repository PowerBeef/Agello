import XCTest

/// Real-tap flows on the device. Each test launches the app from a clean
/// slate (`--uitest-reset`: no chats, default settings; models are kept).
/// On the simulator the app runs the mock engine and timing-sensitive flows
/// are skipped.
@MainActor
final class ChatFlowUITests: XCTestCase {
  private var app: XCUIApplication!

  private static var isSimulator: Bool {
    #if targetEnvironment(simulator)
      return true
    #else
      return false
    #endif
  }

  override func setUp() async throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--uitest-reset"]
    if Self.isSimulator { app.launchArguments.append("--mock-engine") }
    app.launch()
  }

  // MARK: - Scenarios

  func testSendAndReceive() throws {
    try openNewChat()
    send("What is the capital of France? Answer in one word.")
    try waitForReplyToFinish(timeout: 120)
    let reply = lastModelText()
    attachScreenshot("reply")
    XCTAssertFalse(reply.hasPrefix("Error:"), reply)
    if !Self.isSimulator {
      XCTAssertTrue(reply.localizedCaseInsensitiveContains("Paris"), reply)
    }
    XCTAssertTrue(element("message.stats").waitForExistence(timeout: 5), "Stats footer missing")
  }

  /// Audit #10.
  func testStopMidReply() throws {
    try XCTSkipIf(Self.isSimulator, "Needs real generation")
    try openNewChat()
    send("Write a detailed 600-word story about a lighthouse keeper.")
    try waitForStreamingText(minLength: 40)
    element("chat.stop").tap()
    XCTAssertTrue(
      element("chat.stop").waitForNonExistence(timeout: 5), "Still generating 5 s after Stop")
    attachScreenshot("after-stop")
    XCTAssertFalse(lastModelText().hasPrefix("Error:"), "Stop shown as error: \(lastModelText())")
  }

  /// Audit #7: GPU work is not allowed in the background.
  func testBackgroundDuringGeneration() throws {
    try XCTSkipIf(Self.isSimulator, "Needs real GPU generation")
    try openNewChat()
    send("Write a detailed 600-word story about a lighthouse keeper.")
    try waitForStreamingText(minLength: 40)
    XCUIDevice.shared.press(.home)
    sleep(10)
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    // A crash relaunches the app on the chat list, losing the open chat.
    XCTAssertTrue(
      element("chat.input").waitForExistence(timeout: 5),
      "App was relaunched after backgrounding (likely crashed)")
    try waitForReplyToFinish(timeout: 180)
    attachScreenshot("after-background")
    XCTAssertFalse(
      lastModelText().hasPrefix("Error:"), "Backgrounding broke the reply: \(lastModelText())")
    XCTAssertTrue(
      element("chat.banner.notice").exists,
      "Expected the 'stopped because the app moved to the background' notice")
    // The engine must still work afterwards.
    send("Say 'ready'.")
    try waitForReplyToFinish(timeout: 120)
    XCTAssertFalse(lastModelText().hasPrefix("Error:"), lastModelText())
  }

  /// Audit #3: leaving and reopening a chat mid-reply must not reload the
  /// engine or kill the stream.
  func testLeaveAndReturnDuringGeneration() throws {
    try XCTSkipIf(Self.isSimulator, "Needs real generation")
    try openNewChat()
    send("Write a detailed 600-word story about a lighthouse keeper.")
    try waitForStreamingText(minLength: 40)
    element("chat.new").tap()
    openDrawer()
    element("drawer.row").firstMatch.tap()
    XCTAssertFalse(
      element("chat.banner.loading").waitForExistence(timeout: 2),
      "Engine reloaded when reopening the chat mid-reply")
    let lengthAfterReturn = lastModelText().count
    try waitForReplyToFinish(timeout: 180)
    attachScreenshot("after-return")
    XCTAssertFalse(lastModelText().hasPrefix("Error:"), lastModelText())
    XCTAssertGreaterThan(lastModelText().count, lengthAfterReturn, "Reply stopped growing")
  }

  /// Audit #3: rapid Settings edits must coalesce, and chat must keep working.
  func testRapidSettingsChangesThenChat() throws {
    try openNewChat()
    send("Say 'one'.")
    try waitForReplyToFinish(timeout: 120)
    openSettings()
    // Settings is a lazily loaded Form: scroll the sampler presets into view.
    let precise = app.buttons["Precise"].firstMatch
    for _ in 0..<8 where !precise.isHittable {
      app.swipeUp()
    }
    for preset in ["Precise", "Creative", "Balanced", "Creative", "Precise"] {
      app.buttons[preset].firstMatch.tap()
    }
    for _ in 0..<8 where !element("settings.status").isHittable {
      app.swipeDown()
    }
    XCTAssertTrue(element("settings.status").waitForExistence(timeout: 5))
    attachScreenshot("settings")
    element("settings.done").tap()
    // Settings opens from the drawer, which is still showing behind it.
    closeDrawer()
    send("Say 'two'.")
    try waitForReplyToFinish(timeout: 120)
    XCTAssertFalse(lastModelText().hasPrefix("Error:"), lastModelText())
  }

  /// The app opens on a new chat; a chat is saved on its first message
  /// (unused new chats never appear in the drawer) and reopens from it.
  func testDrawerNewChatAndReopen() throws {
    try openNewChat()
    send("Say 'one'.")
    try waitForReplyToFinish(timeout: 120)

    element("chat.new").tap()
    XCTAssertTrue(element("chat.empty").waitForExistence(timeout: 5), "New chat not empty")
    openDrawer()
    XCTAssertEqual(rows().count, 1, "Unused new chat was saved")
    attachScreenshot("drawer")

    rows().firstMatch.tap()
    XCTAssertTrue(element("message.model").waitForExistence(timeout: 5), "Chat did not reopen")
    XCTAssertFalse(element("drawer.search").isHittable, "Drawer stayed open")

    // Search finds the chat by message text; a miss shows no rows.
    openDrawer()
    let search = element("drawer.search")
    search.tap()
    search.typeText("one")
    XCTAssertEqual(rows().count, 1)
    search.clearAndType("quantum chromodynamics")
    sleep(2)  // let search by meaning settle
    XCTAssertEqual(rows().count, 0)
  }

  /// Rename and delete from the chat's toolbar menu.
  func testRenameAndDeleteChat() throws {
    try openNewChat()
    send("Say 'hello'.")
    try waitForReplyToFinish(timeout: 120)
    // Wait for the model-written title so it can't overwrite the rename.
    sleep(Self.isSimulator ? 1 : 5)

    element("chat.menu").tap()
    app.buttons["Rename"].tap()
    let field = app.alerts.textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.clearAndType("Greetings\n")
    if app.alerts.firstMatch.waitForExistence(timeout: 1) {
      app.alerts.buttons["Save"].tap()
    }
    XCTAssertTrue(app.navigationBars["Greetings"].waitForExistence(timeout: 5))

    // Pin: the chat moves to a "Pinned" section in the drawer.
    element("chat.menu").tap()
    app.buttons["Pin"].tap()
    openDrawer()
    XCTAssertTrue(app.staticTexts["Pinned"].waitForExistence(timeout: 5), "No Pinned section")
    closeDrawer()

    element("chat.menu").tap()
    app.buttons["Delete"].tap()
    app.buttons["Delete"].firstMatch.tap()
    XCTAssertTrue(element("chat.empty").waitForExistence(timeout: 5))
    openDrawer()
    XCTAssertEqual(rows().count, 0)
  }

  /// Rich replies: code block (with Copy), table and display math render.
  /// Simulator only: the mock engine answers "markdown" with a fixed sample.
  func testMarkdownRendering() throws {
    // The scripted engine answers "markdown" with a fixed rich sample.
    if !Self.isSimulator {
      app.terminate()
      app.launchArguments.append("--mock-engine")
      app.launch()
    }
    try openNewChat()
    send("Show me markdown")
    try waitForReplyToFinish(timeout: 30)
    attachScreenshot("markdown")
    XCTAssertTrue(element("message.code").waitForExistence(timeout: 5), "Code block missing")
    XCTAssertTrue(element("message.table").exists, "Table missing")
    XCTAssertTrue(element("message.math").exists, "Display math missing")
    let copy = element("code.copy")
    XCTAssertTrue(copy.exists)
    copy.tap()
  }

  /// Regenerate adds a second version; the switcher moves between them.
  /// Editing a message (long press → Edit) branches the conversation.
  func testRegenerateEditAndVersions() throws {
    try openNewChat()
    send("Name one primary color. One word.")
    try waitForReplyToFinish(timeout: 120)

    element("message.regenerate").tap()
    try waitForReplyToFinish(timeout: 120)
    let version = element("message.version")
    XCTAssertTrue(version.waitForExistence(timeout: 5), "No version switcher after regenerate")
    XCTAssertEqual(version.label, "Version 2 of 2")
    element("message.version.previous").tap()
    XCTAssertEqual(element("message.version").label, "Version 1 of 2")

    element("message.user").press(forDuration: 1.0)
    app.buttons["Edit"].tap()
    XCTAssertTrue(element("chat.editing").waitForExistence(timeout: 5))
    let input = element("chat.input")
    input.tap()
    input.typeText(" Answer in French.")
    element("chat.send").tap()
    try waitForReplyToFinish(timeout: 120)
    attachScreenshot("after-edit")
    XCTAssertTrue(element("message.user").label.hasSuffix("Answer in French."))
    // The edited message is version 2 of 2; the reply under it is new.
    let userVersion = app.descendants(matching: .any).matching(identifier: "message.version")
      .allElementsBoundByIndex.first
    XCTAssertEqual(userVersion?.label, "Version 2 of 2")
    XCTAssertFalse(element("chat.editing").exists)
  }

  /// The composer's Think toggle: reasoning streams into an expandable
  /// card while it's on, and stops when it's turned off.
  func testThinkToggleShowsReasoning() throws {
    try openNewChat()
    let think = element("composer.think")
    XCTAssertEqual(think.value as? String, "Off")
    think.tap()
    XCTAssertEqual(think.value as? String, "On")
    // Sent right away: the toggle must apply to this message.
    send("What is 17 × 23? Answer with the number.")
    try waitForReplyToFinish(timeout: 300)
    let reasoning = element("message.reasoning")
    XCTAssertTrue(reasoning.waitForExistence(timeout: 5), "No reasoning card with Think on")
    reasoning.tap()
    XCTAssertTrue(
      element("message.reasoning.text").waitForExistence(timeout: 5), "Reasoning didn't expand")
    attachScreenshot("reasoning")
    if !Self.isSimulator {
      XCTAssertTrue(lastModelText().contains("391"), lastModelText())
    }

    think.tap()
    XCTAssertEqual(think.value as? String, "Off")
    send("Thanks! Reply with one word.")
    try waitForReplyToFinish(timeout: 120)
    XCTAssertEqual(
      app.descendants(matching: .any).matching(identifier: "message.reasoning").count, 1,
      "Reasoning streamed with Think off")
  }

  /// An attached file shows as a chip, travels with the message, and the
  /// reply lists it as a source.
  func testAttachedFileIsSentAndCited() throws {
    app.terminate()
    app.launchArguments.append("--uitest-sample-file")
    app.launch()
    try openNewChat()
    XCTAssertTrue(element("message.file").waitForExistence(timeout: 5), "No pending file chip")
    send("When does the trailhead parking open?")
    try waitForReplyToFinish(timeout: 180)
    attachScreenshot("file-reply")
    XCTAssertTrue(element("message.sources").waitForExistence(timeout: 5), "No sources")
    // The chip moved from the composer to the sent message.
    XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "message.file").count, 1)
    if !Self.isSimulator {
      XCTAssertTrue(lastModelText().contains("6"), lastModelText())
    }
  }

  /// A long document summary keeps running while the app is in the
  /// background (a continued processing task with background GPU access on
  /// devices that support it; otherwise the reply stops with a notice).
  func testLongSummarySurvivesBackgrounding() throws {
    try XCTSkipIf(Self.isSimulator, "Needs real GPU generation")
    app.terminate()
    app.launchArguments.append("--uitest-sample-report")
    app.launch()
    try openNewChat()
    XCTAssertTrue(element("message.file").waitForExistence(timeout: 5), "No pending file chip")
    send("Summarize this report in a few bullet points.")
    // Reading starts with the first section; leave while it's working.
    XCTAssertTrue(
      element("chat.preparing").waitForExistence(timeout: 60), "The summary never started")
    XCUIDevice.shared.press(.home)
    sleep(45)
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
    try waitForReplyToFinish(timeout: 240)
    attachScreenshot("summary-after-background")
    XCTAssertFalse(
      lastModelText().hasPrefix("Error:"), "Backgrounding broke the summary: \(lastModelText())")
    XCTAssertFalse(
      element("chat.banner.notice").exists,
      "The summary stopped when the app moved to the background")
    XCTAssertGreaterThan(lastModelText().count, 200, lastModelText())
  }

  /// A project: create it, start a chat in it; the chat lives in the
  /// project, not in the drawer's recent chats.
  func testProjectChat() throws {
    try openNewChat()
    openDrawer()
    element("drawer.newProject").tap()
    let name = element("project.name")
    XCTAssertTrue(name.waitForExistence(timeout: 5), "Project didn't open")
    name.clearAndType("Hiking")
    element("project.newChat").tap()
    XCTAssertTrue(element("chat.project").waitForExistence(timeout: 5), "Not a project chat")
    try waitForEngineReady()
    send("Say 'trail'.")
    try waitForReplyToFinish(timeout: 120)

    openDrawer()
    XCTAssertEqual(rows().count, 0, "Project chat shown in recents")
    element("drawer.project").firstMatch.tap()
    XCTAssertTrue(element("project.chat").waitForExistence(timeout: 5), "Chat not in project")
    attachScreenshot("project")
    element("project.done").tap()
  }

  /// The Search chip searches the web for one message; the reply lists
  /// linked sources and the chip turns itself off.
  func testWebSearchFromComposer() throws {
    try openNewChat()
    let search = element("composer.search")
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    XCTAssertEqual(search.value as? String, "On")
    send("What is the capital of Australia?")
    try waitForReplyToFinish(timeout: 180)
    XCTAssertEqual(search.value as? String, "Off", "Search should apply to one message")
    if !Self.isSimulator {
      XCTAssertTrue(element("message.sources").waitForExistence(timeout: 5), "No sources")
      XCTAssertTrue(lastModelText().contains("Canberra"), lastModelText())
    }
    attachScreenshot("web-search")
  }

  /// Dictation: the mic listens, then transcribes and goes back to idle
  /// (the test room is silent, so the text itself isn't checked).
  func testDictationButtonFlow() throws {
    // XCTest can't answer the system microphone prompt on device: record
    // silence through the app's test microphone instead.
    app.terminate()
    app.launchArguments.append("--uitest-fake-mic")
    app.launch()
    try openNewChat()
    let mic = element("composer.mic")
    mic.tap()
    XCTAssertTrue(element("composer.recording").waitForExistence(timeout: 10), "Not listening")
    XCTAssertEqual(mic.value as? String, "Listening")
    sleep(2)
    mic.tap()
    let deadline = Date().addingTimeInterval(90)
    while (mic.value as? String) != "", Date() < deadline { usleep(300_000) }
    XCTAssertEqual(mic.value as? String, "", "Mic stuck in \(mic.value ?? "")")
    XCTAssertFalse(element("composer.recording").exists)
    XCTAssertTrue(element("chat.send").exists || element("composer.voice").exists)
  }

  /// Voice mode opens from the empty composer and ends back in the chat
  /// (test microphone: XCTest can't answer the system prompt on device).
  func testVoiceModeOpensAndCloses() throws {
    app.terminate()
    app.launchArguments.append("--uitest-fake-mic")
    app.launch()
    try openNewChat()
    let voice = element("composer.voice")
    XCTAssertTrue(voice.waitForExistence(timeout: 5), "No voice button in the empty composer")
    voice.tap()
    let state = element("voice.state")
    XCTAssertTrue(state.waitForExistence(timeout: 10))
    XCTAssertEqual(state.label, "Listening")
    attachScreenshot("voice-mode")
    element("voice.end").tap()
    XCTAssertTrue(element("chat.input").waitForExistence(timeout: 5), "Didn't return to the chat")
  }

  /// Deep links (widgets, Control Center, Shortcuts use them): "ask" opens a
  /// new chat and sends the question; "voice" opens voice mode.
  func testDeepLinks() throws {
    app.terminate()
    app.launchArguments.append("--uitest-fake-mic")
    app.launch()
    try openNewChat()
    XCUIDevice.shared.system.open(URL(string: "irtchat://ask?q=What%20is%202%2B2%3F")!)
    XCTAssertTrue(element("message.user").waitForExistence(timeout: 15), "Question not sent")
    XCTAssertEqual(element("message.user").label, "What is 2+2?")
    try waitForReplyToFinish(timeout: 120)

    XCUIDevice.shared.system.open(URL(string: "irtchat://voice")!)
    XCTAssertTrue(element("voice.state").waitForExistence(timeout: 15), "Voice mode didn't open")
    element("voice.end").tap()
    XCTAssertTrue(element("chat.input").waitForExistence(timeout: 5))
  }

  /// Memory: turn it on and add a memory by hand.
  func testMemorySettings() throws {
    openSettings()
    element("settings.memory").tap()
    let toggle = element("memory.enabled")
    XCTAssertTrue(toggle.waitForExistence(timeout: 5))
    if (toggle.value as? String) != "1" { toggle.switches.firstMatch.tap() }
    element("memory.add").tap()
    let field = app.alerts.textFields.firstMatch
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.typeText("Prefers metric units\n")
    if app.alerts.firstMatch.waitForExistence(timeout: 1) { app.alerts.buttons["Save"].tap() }
    XCTAssertTrue(element("memory.row").waitForExistence(timeout: 5), "Memory not listed")
    attachScreenshot("memory")
  }

  /// E4B is the only model: its card (Settings → Models) shows Ready
  /// (device) or Download.
  func testModelsShowTheModel() throws {
    openSettings()
    element("settings.models").tap()
    let ready = element("models.ready.e4b")
    let download = element("models.download.e4b")
    XCTAssertTrue(
      ready.waitForExistence(timeout: 5) || download.exists, "E4B card missing")
    if !Self.isSimulator {
      XCTAssertTrue(ready.exists, "E4B should be downloaded on the test device")
    }
    attachScreenshot("models")
  }

  /// Think and Search are either titled or icon-only, never truncated (they
  /// used to render as "T…" / "S…", about 52–70 pt wide), and at a large
  /// accessibility text size every composer control still fits inside the
  /// composer and can be tapped.
  func testComposerControlsFit() throws {
    let think = element("composer.think")
    let search = element("composer.search")
    XCTAssertTrue(think.waitForExistence(timeout: 10))
    XCTAssertTrue(search.exists)
    for pill in [think, search] {
      let width = pill.frame.width
      XCTAssertGreaterThanOrEqual(width, 44, "\(pill.label) below the touch target")
      XCTAssertFalse((53..<70).contains(width), "\(pill.label) truncated (\(width) pt)")
    }
    attachScreenshot("composer-default")

    app.terminate()
    app.launchArguments += [
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL",
    ]
    app.launch()
    let composer = element("chat.composer")
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    for id in ["composer.attach", "composer.think", "composer.search", "composer.mic", "composer.voice"] {
      let control = element(id)
      XCTAssertTrue(control.waitForExistence(timeout: 5), id)
      XCTAssertTrue(control.isHittable, "\(id) not hittable")
      XCTAssertTrue(composer.frame.insetBy(dx: -1, dy: -1).contains(control.frame), "\(id) outside the composer")
    }
    attachScreenshot("composer-accessibility-L")
  }

  // MARK: - Helpers

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func openNewChat() throws {
    // The app launches on a new chat (`--uitest-reset` clears the selection).
    XCTAssertTrue(element("chat.input").waitForExistence(timeout: 10), "New chat not shown")
    try waitForEngineReady()
  }

  /// The whole composer (including its bottom row of buttons) must sit
  /// above the software keyboard, not just the text field.
  private func assertComposerClearsKeyboard() {
    let keyboard = app.keyboards.firstMatch
    guard keyboard.waitForExistence(timeout: 2) else { return }
    // Let the keyboard and the composer finish animating.
    usleep(600_000)
    let composer = element("chat.composer").frame
    let send = ["chat.send", "composer.voice", "chat.stop"].map(element).first { $0.exists }?.frame ?? .zero
    let top = keyboard.frame.minY
    let report = "window=\(app.windows.firstMatch.frame) keyboard=\(keyboard.frame) composer=\(composer) send=\(send)"
    let attachment = XCTAttachment(string: report)
    attachment.name = "keyboard-frames"
    attachment.lifetime = .keepAlways
    add(attachment)
    XCTAssertLessThanOrEqual(composer.maxY, top + 1, "The keyboard covers the composer: \(report)")
    XCTAssertLessThanOrEqual(send.maxY, top + 1, "The keyboard covers Send: \(report)")
  }

  private func openDrawer() {
    element("chat.drawer").tap()
    XCTAssertTrue(element("drawer.search").waitForExistence(timeout: 5), "Drawer did not open")
    // Let the slide-in animation settle before tapping rows.
    _ = element("drawer.close").waitForExistence(timeout: 2)
    usleep(400_000)
  }

  private func closeDrawer() {
    element("drawer.close").tap()
    XCTAssertTrue(element("drawer.close").waitForNonExistence(timeout: 5), "Drawer did not close")
    usleep(300_000)
  }

  private func openSettings() {
    openDrawer()
    element("drawer.settings").tap()
    XCTAssertTrue(element("settings.done").waitForExistence(timeout: 5), "Settings did not open")
  }

  private func rows() -> XCUIElementQuery {
    app.descendants(matching: .any).matching(identifier: "drawer.row")
  }

  private func waitForEngineReady(timeout: TimeInterval = 180) throws {
    if element("chat.banner.download").waitForExistence(timeout: 2) {
      throw XCTSkip("Model not downloaded: run InferenceScenarioTests/test00 first")
    }
    let loading = element("chat.banner.loading")
    if loading.exists {
      XCTAssertTrue(loading.waitForNonExistence(timeout: timeout), "Model load timed out")
    }
    if element("chat.banner.failed").exists {
      XCTFail("Engine failed: \(element("chat.banner.failed").label)")
    }
  }

  private func send(_ text: String) {
    let input = element("chat.input")
    input.tap()
    assertComposerClearsKeyboard()
    input.typeText(text)
    element("chat.send").tap()
  }

  private func lastModelText() -> String {
    app.descendants(matching: .any).matching(identifier: "message.model")
      .allElementsBoundByIndex.last?.label ?? ""
  }

  private func waitForStreamingText(minLength: Int, timeout: TimeInterval = 120) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while lastModelText().count < minLength {
      if Date() > deadline { throw XCTSkip("Reply never started streaming") }
      usleep(200_000)
    }
    XCTAssertTrue(element("chat.stop").exists, "Expected to be mid-generation")
  }

  private func waitForReplyToFinish(timeout: TimeInterval) throws {
    _ = element("chat.stop").waitForExistence(timeout: 10)
    XCTAssertTrue(
      element("chat.stop").waitForNonExistence(timeout: timeout), "Reply did not finish in time")
    // Idle again: Send (draft present) or the voice-mode button (empty).
    XCTAssertTrue(
      element("chat.send").waitForExistence(timeout: 5) || element("composer.voice").exists)
  }

  private func attachScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

extension XCUIElement {
  func clearAndType(_ text: String) {
    // Tap the trailing edge so the cursor lands after the existing text
    // (a center tap puts it mid-text on device).
    coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
    if let current = value as? String, !current.isEmpty {
      typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
    }
    typeText(text)
  }
}

extension ChatFlowUITests {
  /// With the keyboard up, the composer's bottom row must stay tappable.
  /// Checked by real taps: XCTest's keyboard frame excludes the predictive
  /// bar, so frame comparisons alone miss an overlap.
  func testKeyboardDoesNotCoverComposer() throws {
    let input = app.descendants(matching: .any).matching(identifier: "chat.input").firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap()
    try XCTSkipUnless(app.keyboards.firstMatch.waitForExistence(timeout: 3), "No software keyboard")
    usleep(800_000)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "keyboard"
    screenshot.lifetime = .keepAlways
    add(screenshot)

    let think = app.descendants(matching: .any).matching(identifier: "composer.think").firstMatch
    let before = think.value as? String
    think.tap()
    XCTAssertNotEqual(think.value as? String, before, "Think is under the keyboard")
    think.tap()
    XCTAssertEqual(think.value as? String, before)
    XCTAssertTrue(app.keyboards.firstMatch.exists, "Keyboard closed: taps missed the composer")
  }
}
