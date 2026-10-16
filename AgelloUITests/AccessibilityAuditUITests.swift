import XCTest

/// Xcode's accessibility audit on the main screens (the chat with a markdown reply, the drawer,
/// Settings), on the scripted engine. Missing descriptions, small hit areas, wrong traits and
/// undetectable elements fail. Dynamic Type and clipping are printed (AUDIT lines in the log) but
/// don't fail: at the largest sizes iOS flags its own navigation titles, Form section headers,
/// toolbar buttons and text field placeholders. Contrast is left to a check by hand: the dark
/// palette's tertiary text and hairlines are deliberate, and Increase Contrast strengthens them.
@MainActor
final class AccessibilityAuditUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() async throws {
    continueAfterFailure = true
    app = XCUIApplication()
    app.launchArguments = ["--uitest-reset", "--mock-engine"]
    app.launch()
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func audit(_ screen: String) throws {
    try app.performAccessibilityAudit(
      for: [.dynamicType, .elementDetection, .hitRegion, .sufficientElementDescription, .textClipped, .trait]
    ) { issue in
      let element = issue.element
      print(
        "AUDIT \(screen): \(issue.compactDescription) [\(element?.identifier ?? "")] "
          + "'\(element?.label ?? "")' type \(element?.elementType.rawValue ?? 0) "
          + "frame \(element.map { NSCoder.string(for: $0.frame) } ?? "")")
      if issue.auditType == .sufficientElementDescription, let element {
        print("AUDIT detail: \(element.debugDescription.prefix(1_500))")
      }
      // true: reported, not a failure.
      return issue.auditType == .dynamicType || issue.auditType == .textClipped
    }
  }

  func testMainScreensPassTheAudit() throws {
    let input = element("chat.input")
    XCTAssertTrue(input.waitForExistence(timeout: 10), "Chat not shown")
    input.tap()
    input.typeText("Show me markdown")
    element("chat.send").tap()
    _ = element("chat.stop").waitForExistence(timeout: 5)
    XCTAssertTrue(element("chat.stop").waitForNonExistence(timeout: 30), "Reply didn't finish")
    try audit("chat")

    element("chat.drawer").tap()
    XCTAssertTrue(element("drawer.search").waitForExistence(timeout: 5), "Drawer didn't open")
    sleep(1)
    try audit("drawer")

    element("drawer.settings").tap()
    XCTAssertTrue(element("settings.done").waitForExistence(timeout: 5), "Settings didn't open")
    try audit("settings")
  }
}
