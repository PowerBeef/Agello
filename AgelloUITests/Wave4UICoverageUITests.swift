import XCTest

/// Deterministic `--mock-engine` UI tests covering Settings subpages, Project lifecycle,
/// scroll-to-bottom pill, all 9 Phases A–C Action Cards, and single/multi-step Tool Confirmation
/// cards (`ToolConfirmationCard` / `PlanConfirmationCard`).
@MainActor
final class Wave4UICoverageUITests: XCTestCase {
  private var app: XCUIApplication!

  nonisolated override func record(_ issue: XCTIssue) {
    nonisolated(unsafe) var issue = issue
    nonisolated(unsafe) let test = self
    MainActor.assumeIsolated {
      if let app = test.app, app.state == .runningForeground {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "failure"
        attachment.lifetime = .keepAlways
        issue.add(attachment)
      }
    }
    super.record(issue)
  }

  override func setUp() async throws {
    continueAfterFailure = false
    app = XCUIApplication()
  }

  private func launchMockApp(extraArgs: [String] = []) {
    app = XCUIApplication()
    app.launchArguments = ["--uitest-reset", "--mock-engine"] + extraArgs
    app.launch()
    XCTAssertTrue(element("chat.input").waitForExistence(timeout: 10), "Chat did not appear")
  }

  // MARK: - Settings subpages

  func testSettingsSubpagesWalkthrough() throws {
    launchMockApp()
    openSettings()

    // 1. Personalization
    scrollTo("settings.personalization").tap()
    XCTAssertTrue(element("personalization.enabled").waitForExistence(timeout: 5))
    setSwitch("personalization.enabled", to: true)
    let nameField = element("personalization.name")
    XCTAssertTrue(nameField.waitForExistence(timeout: 5))
    nameField.tap()
    nameField.typeText("Patrice")
    XCTAssertTrue(element("personalization.about").exists)
    XCTAssertTrue(element("personalization.instructions").exists)
    if app.toolbars.buttons["Done"].exists { app.toolbars.buttons["Done"].tap() }
    popToSettings()

    // 2. Web search (SearXNG URL reveal & validation)
    scrollTo("settings.web").tap()
    XCTAssertTrue(element("web.allowed").waitForExistence(timeout: 5))
    XCTAssertTrue(element("web.automatic").exists)
    let provider = element("web.provider")
    XCTAssertTrue(provider.waitForExistence(timeout: 5))
    provider.tap()
    let searxngOption = app.buttons["SearXNG"].firstMatch
    if searxngOption.waitForExistence(timeout: 3) {
      searxngOption.tap()
    } else {
      app.staticTexts["SearXNG"].firstMatch.tap()
    }
    let urlField = app.textFields["SearXNG server URL"].firstMatch
    XCTAssertTrue(urlField.waitForExistence(timeout: 5), "SearXNG URL field did not reveal")
    urlField.tap()
    urlField.typeText("not-a-url")
    let schemeError = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "https://")
    ).firstMatch
    XCTAssertTrue(schemeError.waitForExistence(timeout: 5), "Expected https:// validation error")
    urlField.clearAndType("http://127.0.0.1:8888")
    let hostError = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] %@", "domain name")
    ).firstMatch
    XCTAssertTrue(hostError.waitForExistence(timeout: 5), "Expected private-host validation error")
    urlField.clearAndType("https://searx.example.org")
    XCTAssertTrue(hostError.waitForNonExistence(timeout: 5), "Valid SearXNG URL should clear error")
    popToSettings()

    // 3. Personal tools (verify all 7 opt-in toggles and toggle one)
    scrollTo("settings.personalTools").tap()
    XCTAssertTrue(element("personalTools.calendar").waitForExistence(timeout: 5))
    for id in [
      "personalTools.calendar", "personalTools.reminders", "personalTools.contacts",
      "personalTools.maps", "personalTools.weather", "personalTools.alarms", "personalTools.photos",
    ] {
      XCTAssertTrue(scrollTo(id).waitForExistence(timeout: 5), "Missing toggle \(id)")
    }
    let calendarToggle = scrollTo("personalTools.calendar", directionDown: false)
    XCTAssertTrue(calendarToggle.waitForExistence(timeout: 5))
    setSwitch("personalTools.calendar", to: true)
    setSwitch("personalTools.calendar", to: false)
    popToSettings()

    // 4. Automations & Shortcuts (register starter template -> appears in allowlist -> delete)
    scrollTo("settings.automations").tap()
    XCTAssertTrue(element("automations.add").waitForExistence(timeout: 5))
    let starter = scrollTo("automations.starter.save_to_apple_notes")
    XCTAssertTrue(starter.waitForExistence(timeout: 5), "Starter template missing")
    starter.tap()
    let registered = scrollTo("automations.shortcut.save_to_apple_notes", directionDown: false)
    XCTAssertTrue(registered.waitForExistence(timeout: 5), "Registered starter did not appear in Allowed Shortcuts")
    registered.swipeLeft()
    let deleteButton = app.buttons["Delete"].firstMatch
    XCTAssertTrue(deleteButton.waitForExistence(timeout: 5), "Swipe Delete action did not appear")
    deleteButton.tap()
    XCTAssertTrue(
      element("automations.shortcut.save_to_apple_notes").waitForNonExistence(timeout: 5),
      "Deleted Shortcut remained in Allowed Shortcuts")
    popToSettings()

    // 5. Licenses
    scrollTo("settings.licenses").tap()
    XCTAssertTrue(element("licenses.text").waitForExistence(timeout: 5), "Licenses notice did not load")
    popToSettings()

    // 6. Developer Settings (5-tap unlock via settings.version)
    let version = scrollTo("settings.version")
    XCTAssertTrue(version.waitForExistence(timeout: 5), "Settings version footer missing")
    for _ in 0..<5 {
      version.tap()
    }
    XCTAssertTrue(element("settings.showStats").waitForExistence(timeout: 5), "Developer Settings did not unlock")
    XCTAssertTrue(element("settings.benchmark").waitForExistence(timeout: 5), "Benchmark button missing")
    popToSettings()
    element("settings.done").tap()
    XCTAssertTrue(element("settings.done").waitForNonExistence(timeout: 5))
  }

  // MARK: - Project lifecycle

  func testProjectCreateRenameAndDeleteLifecycle() throws {
    launchMockApp()
    openDrawer()

    element("drawer.newProject").tap()
    let name = element("project.name")
    XCTAssertTrue(name.waitForExistence(timeout: 5), "Project sheet did not open")
    name.clearAndType("Travel Plans")
    XCTAssertTrue(element("project.instructions").exists)
    XCTAssertTrue(element("project.addFiles").exists)
    XCTAssertTrue(element("project.linkFolder").exists)
    element("project.done").tap()

    let projectRow = element("drawer.project")
    XCTAssertTrue(projectRow.waitForExistence(timeout: 5), "Created project missing in drawer")
    XCTAssertTrue(projectRow.label.contains("Travel Plans"), "Unexpected project label: \(projectRow.label)")

    // Rename
    projectRow.tap()
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    name.clearAndType("Winter Trip")
    element("project.done").tap()
    XCTAssertTrue(projectRow.waitForExistence(timeout: 5))
    XCTAssertTrue(projectRow.label.contains("Winter Trip"), "Renamed project label did not update: \(projectRow.label)")

    // Delete
    projectRow.tap()
    let deleteRow = scrollTo("project.delete")
    XCTAssertTrue(deleteRow.waitForExistence(timeout: 5), "Delete project button missing")
    deleteRow.tap()
    let confirmSheetButton = app.sheets.buttons["Delete project"].firstMatch
    if confirmSheetButton.waitForExistence(timeout: 3) {
      confirmSheetButton.tap()
    } else {
      let matching = app.buttons.matching(
        NSPredicate(format: "label BEGINSWITH %@", "Delete project")
      ).allElementsBoundByIndex
      XCTAssertGreaterThanOrEqual(matching.count, 1, "Delete confirmation button missing")
      matching.last?.tap()
    }
    XCTAssertTrue(projectRow.waitForNonExistence(timeout: 5), "Deleted project remained in drawer")
  }

  // MARK: - Scroll-to-bottom pill

  func testScrollToBottomPillShowsOnScrollUpAndDismissesOnTap() throws {
    launchMockApp()
    send("__uitest_long__")
    waitForReplyToFinish()

    let pill = element("chat.scrollToBottom")
    XCTAssertFalse(pill.exists, "Scroll-to-bottom pill should stay hidden at bottom")

    let scrollView = app.scrollViews.firstMatch
    XCTAssertTrue(scrollView.waitForExistence(timeout: 5))
    for _ in 0..<5 where !pill.exists {
      scrollView.swipeDown(velocity: .fast)
      usleep(250_000)
    }
    XCTAssertTrue(pill.waitForExistence(timeout: 5), "Scroll-to-bottom pill did not appear after scrolling up")
    XCTAssertTrue(pill.isHittable, "Scroll-to-bottom pill not hittable")
    XCTAssertGreaterThanOrEqual(pill.frame.width, 44, "Scroll-to-bottom pill width < 44 pt")
    XCTAssertGreaterThanOrEqual(pill.frame.height, 44, "Scroll-to-bottom pill height < 44 pt")

    pill.tap()
    XCTAssertTrue(pill.waitForNonExistence(timeout: 5), "Scroll-to-bottom pill did not dismiss after tap")
  }

  // MARK: - Action Cards (all 9 types)

  func testActionCardsRenderAllNineTypes() throws {
    launchMockApp()
    send("__uitest_cards__")
    waitForReplyToFinish()

    let scrollView = app.scrollViews.firstMatch
    XCTAssertTrue(scrollView.waitForExistence(timeout: 5))

    let coreCardIDs = [
      "actionCard.route",
      "actionCard.places",
      "actionCard.calendar",
      "actionCard.reminder",
      "actionCard.contact",
      "actionCard.draft",
      "actionCard.draft.unverifiedWarning",
    ]
    for cardID in coreCardIDs {
      XCTAssertTrue(
        findInScrollView(cardID, scrollView: scrollView).exists,
        "Expected \(cardID) to render")
    }

    let stepsToggle = findInScrollView("actionCard.route.stepsToggle", scrollView: scrollView)
    XCTAssertTrue(stepsToggle.exists, "Route steps disclosure missing")
    stepsToggle.tap()

    // Live cards: Weather (+ alert & legal attribution), Alarm, Automation Handoff
    send("__uitest_live_cards__")
    waitForReplyToFinish()

    let liveCardIDs = [
      "actionCard.weather",
      "actionCard.weather.alertLink",
      "message.weatherAttribution",
      "actionCard.alarm",
      "actionCard.automation",
      "actionCard.automation.retry",
      "actionCard.automation.open",
    ]
    for cardID in liveCardIDs {
      XCTAssertTrue(
        findInScrollView(cardID, scrollView: scrollView).exists,
        "Expected \(cardID) to render")
    }
  }

  // MARK: - ToolConfirmationCard & PlanConfirmationCard

  func testToolConfirmationCardApproveAndDeny() throws {
    launchMockApp()

    // 1. Deny flow
    send("__uitest_confirm__")
    let card = element("tool.confirm.card")
    XCTAssertTrue(card.waitForExistence(timeout: 10), "ToolConfirmationCard did not appear")
    XCTAssertTrue(element("tool.confirm.taintBanner").exists, "Untrusted taint banner missing")
    XCTAssertTrue(element("tool.confirm.name").exists, "Tool name missing")
    let deny = element("tool.confirm.deny")
    let approve = element("tool.confirm.approve")
    XCTAssertTrue(deny.exists && approve.exists)

    deny.tap()
    XCTAssertTrue(card.waitForNonExistence(timeout: 5), "ToolConfirmationCard did not dismiss on Deny")
    waitForReplyToFinish()
    XCTAssertTrue(lastModelText().contains("Cancelled"), "Unexpected deny reply: \(lastModelText())")

    // 2. Approve flow
    send("__uitest_confirm__")
    XCTAssertTrue(card.waitForExistence(timeout: 10), "Second ToolConfirmationCard did not appear")
    approve.tap()
    XCTAssertTrue(card.waitForNonExistence(timeout: 5), "ToolConfirmationCard did not dismiss on Approve")
    waitForReplyToFinish()
    XCTAssertTrue(lastModelText().contains("Confirmed"), "Unexpected approve reply: \(lastModelText())")
  }

  func testPlanConfirmationCardPartialStepSelection() throws {
    launchMockApp()
    send("__uitest_plan__")

    let planCard = element("tool.plan.card")
    XCTAssertTrue(planCard.waitForExistence(timeout: 10), "PlanConfirmationCard did not appear")
    XCTAssertTrue(element("tool.confirm.taintBanner").exists, "Plan taint banner missing")
    let step0 = element("tool.plan.step.0")
    let step1 = element("tool.plan.step.1")
    let approve = element("tool.confirm.approve")
    XCTAssertTrue(step0.exists && step1.exists && approve.exists)
    XCTAssertEqual(approve.label, "Run 2 Actions")

    // Uncheck step 1 -> 1 action selected
    step1.tap()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Run 1 Action"), object: approve)],
        timeout: 5),
      .completed, "Approve label did not update to Run 1 Action")

    // Uncheck step 0 -> 0 actions selected, Approve disabled
    step0.tap()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == NO"), object: approve)
        ],
        timeout: 5),
      .completed, "Approve should disable when 0 plan steps are selected")

    // Re-check step 0 and approve only step 0
    step0.tap()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == YES"), object: approve)
        ],
        timeout: 5),
      .completed, "Approve should re-enable when step 0 is checked")
    approve.tap()
    XCTAssertTrue(planCard.waitForNonExistence(timeout: 5))
    waitForReplyToFinish()
    XCTAssertTrue(
      lastModelText().contains("Approved plan steps: 0"),
      "Unexpected plan reply: \(lastModelText())")
  }

  // MARK: - Helpers

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func send(_ text: String) {
    let input = element("chat.input")
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap()
    input.typeText(text)
    element("chat.send").tap()
  }

  private func waitForReplyToFinish(timeout: TimeInterval = 30) {
    _ = element("chat.stop").waitForExistence(timeout: 1)
    XCTAssertTrue(element("chat.stop").waitForNonExistence(timeout: timeout), "Reply did not finish")
  }

  private func lastModelText() -> String {
    app.descendants(matching: .any).matching(identifier: "message.model")
      .allElementsBoundByIndex.last?.label ?? ""
  }

  private func openDrawer() {
    element("chat.drawer").tap()
    XCTAssertTrue(element("drawer.search").waitForExistence(timeout: 5), "Drawer did not open")
    usleep(400_000)
  }

  private func openSettings() {
    openDrawer()
    element("drawer.settings").tap()
    XCTAssertTrue(element("settings.done").waitForExistence(timeout: 5), "Settings did not open")
    usleep(300_000)
  }

  private func popToSettings() {
    let back = app.navigationBars.buttons["Settings"].firstMatch
    if back.exists && back.isHittable {
      back.tap()
    } else {
      app.navigationBars.buttons.firstMatch.tap()
    }
    XCTAssertTrue(element("settings.done").waitForExistence(timeout: 5), "Did not return to Settings")
    usleep(250_000)
  }

  @discardableResult
  private func scrollTo(_ identifier: String, directionDown: Bool = true, maxSwipes: Int = 6) -> XCUIElement {
    let target = element(identifier)
    for _ in 0..<maxSwipes where !target.isHittable {
      if directionDown { app.swipeUp() } else { app.swipeDown() }
    }
    return target
  }

  private func findInScrollView(_ identifier: String, scrollView: XCUIElement) -> XCUIElement {
    let target = element(identifier)
    if target.exists { return target }
    for _ in 0..<6 where !target.exists {
      scrollView.swipeDown(velocity: .default)
    }
    if target.exists { return target }
    for _ in 0..<8 where !target.exists {
      scrollView.swipeUp(velocity: .default)
    }
    return target
  }

  private func setSwitch(_ identifier: String, to on: Bool) {
    let target = element(identifier)
    XCTAssertTrue(target.waitForExistence(timeout: 5), "Missing toggle \(identifier)")
    let expected = on ? "1" : "0"
    let control = target.switches.firstMatch.exists ? target.switches.firstMatch : target
    if (control.value as? String) != expected {
      if target.switches.firstMatch.exists {
        target.switches.firstMatch.tap()
      } else {
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
      }
    }
    let predicate = NSPredicate(format: "value == %@", expected)
    XCTAssertEqual(
      XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: control)], timeout: 5),
      .completed, "Toggle \(identifier) did not switch to \(expected)")
  }
}
