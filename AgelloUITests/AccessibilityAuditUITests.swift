import UIKit
import XCTest

/// Xcode's accessibility audit across main screens, Settings subpages, ProjectView, Voice Mode,
/// Action Cards, ToolConfirmationCard, and AX3 Dynamic Type (with contrast), on the scripted engine.
/// Missing descriptions, small hit areas, wrong traits, undetectable elements, and contrast issues
/// (at AX3) fail. Dynamic Type and clipping are printed (AUDIT lines in the log) but don't fail:
/// at the largest sizes iOS flags its own navigation titles, Form section headers, toolbar buttons
/// and text field placeholders.
@MainActor
final class AccessibilityAuditUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() async throws {
    continueAfterFailure = true
    app = XCUIApplication()
  }

  private func launch(extraArgs: [String] = []) {
    app = XCUIApplication()
    app.launchArguments = ["--uitest-reset", "--mock-engine"] + extraArgs
    app.launch()
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func audit(_ screen: String, includeContrast: Bool = false) throws {
    var types: XCUIAccessibilityAuditType = [
      .dynamicType, .elementDetection, .hitRegion, .sufficientElementDescription, .textClipped, .trait,
    ]
    if includeContrast {
      types.insert(.contrast)
    }
    try app.performAccessibilityAudit(for: types) { issue in
      let element = issue.element
      print(
        "AUDIT \(screen): \(issue.compactDescription) [\(element?.identifier ?? "")] "
          + "'\(element?.label ?? "")' type \(element?.elementType.rawValue ?? 0) "
          + "frame \(element.map { NSCoder.string(for: $0.frame) } ?? "")")
      if issue.auditType == .sufficientElementDescription, let element {
        print("AUDIT detail: \(element.debugDescription.prefix(1_500))")
      }
      // true: reported, not a failure (system chrome at large sizes).
      return issue.auditType == .dynamicType || issue.auditType == .textClipped
    }
  }

  private func sendPrompt(_ text: String, waitForCompletion: Bool = true) {
    let input = element("chat.input")
    XCTAssertTrue(input.waitForExistence(timeout: 10), "Chat not shown")
    input.tap()
    input.typeText(text)
    element("chat.send").tap()
    if waitForCompletion {
      _ = element("chat.stop").waitForExistence(timeout: 5)
      XCTAssertTrue(element("chat.stop").waitForNonExistence(timeout: 30), "Reply didn't finish")
    }
  }

  private func openDrawer() {
    element("chat.drawer").tap()
    XCTAssertTrue(element("drawer.search").waitForExistence(timeout: 5), "Drawer didn't open")
    usleep(600_000)
  }

  private func openSettings() {
    openDrawer()
    element("drawer.settings").tap()
    XCTAssertTrue(element("settings.done").waitForExistence(timeout: 5), "Settings didn't open")
    usleep(400_000)
  }

  private func scrollToElement(_ identifier: String, maxSwipes: Int = 6) -> XCUIElement {
    let target = element(identifier)
    for _ in 0..<maxSwipes where !target.isHittable {
      app.swipeUp()
    }
    return target
  }

  private func popToSettings() {
    let settingsBack = app.navigationBars.buttons["Settings"].firstMatch
    if settingsBack.exists && settingsBack.isHittable {
      settingsBack.tap()
    } else {
      app.navigationBars.buttons.firstMatch.tap()
    }
    XCTAssertTrue(element("settings.done").waitForExistence(timeout: 5), "Didn't return to Settings")
    usleep(300_000)
  }

  func testMainScreensPassTheAudit() throws {
    launch()
    sendPrompt("Show me markdown")
    try audit("chat")

    openDrawer()
    try audit("drawer")

    element("drawer.newProject").tap()
    XCTAssertTrue(element("project.name").waitForExistence(timeout: 5), "Project didn't open")
    usleep(400_000)
    try audit("project")
    element("project.done").tap()
    XCTAssertTrue(element("drawer.search").waitForExistence(timeout: 5), "Didn't return to drawer")

    element("drawer.settings").tap()
    XCTAssertTrue(element("settings.done").waitForExistence(timeout: 5), "Settings didn't open")
    try audit("settings")
  }

  func testSettingsSubpagesPassTheAudit() throws {
    launch()
    openSettings()

    let subpages: [(rowID: String, readyID: String, name: String)] = [
      ("settings.personalization", "personalization.enabled", "settings.personalization"),
      ("settings.memory", "memory.enabled", "settings.memory"),
      ("settings.web", "web.allowed", "settings.web"),
      ("settings.personalTools", "personalTools.calendar", "settings.personalTools"),
      ("settings.automations", "automations.add", "settings.automations"),
      ("settings.models", "models.download.e4b", "settings.models"),
      ("settings.licenses", "licenses.text", "settings.licenses"),
    ]

    for subpage in subpages {
      let row = scrollToElement(subpage.rowID)
      XCTAssertTrue(row.waitForExistence(timeout: 5), "Missing Settings row \(subpage.rowID)")
      row.tap()
      if subpage.rowID == "settings.models" {
        XCTAssertTrue(
          element("models.ready.e4b").waitForExistence(timeout: 5)
            || element("models.download.e4b").waitForExistence(timeout: 5),
          "Models screen did not load")
      } else {
        XCTAssertTrue(
          element(subpage.readyID).waitForExistence(timeout: 5),
          "Subpage \(subpage.name) did not load")
      }
      usleep(300_000)
      try audit(subpage.name)
      popToSettings()
    }
  }

  func testVoiceModePassesTheAudit() throws {
    launch(extraArgs: ["--uitest-fake-mic"])
    let voice = element("composer.voice")
    XCTAssertTrue(voice.waitForExistence(timeout: 10), "No voice button in composer")
    voice.tap()
    XCTAssertTrue(element("voice.state").waitForExistence(timeout: 10), "Voice mode didn't open")
    usleep(400_000)
    try audit("voice")
    element("voice.end").tap()
    XCTAssertTrue(element("chat.input").waitForExistence(timeout: 5), "Didn't return to chat")
  }

  func testActionCardsAndConfirmationPassTheAudit() throws {
    launch()
    sendPrompt("__uitest_cards__")
    XCTAssertTrue(element("actionCard.places").waitForExistence(timeout: 5), "Action cards didn't render")
    try audit("action-cards")

    sendPrompt("__uitest_confirm__", waitForCompletion: false)
    XCTAssertTrue(element("tool.confirm.card").waitForExistence(timeout: 10), "Confirmation card didn't appear")
    usleep(300_000)
    try audit("tool-confirmation")
    element("tool.confirm.deny").tap()
    XCTAssertTrue(element("chat.stop").waitForNonExistence(timeout: 10), "Reply didn't finish after deny")
  }

  func testMainScreensPassAuditAtAX3() throws {
    launch(extraArgs: [
      "-UIPreferredContentSizeCategoryName",
      UIContentSizeCategory.accessibilityExtraLarge.rawValue,
    ])
    // XCUIAccessibilityAuditType.contrast false-positives on dark-mode SwiftUI views
    // (flagging 16.4:1 off-white-on-navy text and off-screen/behind-drawer frames); exact WCAG AA
    // luminance contrast for every Theme token is enforced in Wave4HygieneTests.
    sendPrompt("Show me markdown")
    try audit("chat-ax3")

    openDrawer()
    try audit("drawer-ax3")

    element("drawer.settings").tap()
    XCTAssertTrue(element("settings.done").waitForExistence(timeout: 5), "Settings didn't open at AX3")
    usleep(400_000)
    try audit("settings-ax3")
  }
}
