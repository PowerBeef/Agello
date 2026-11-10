import XCTest

/// The bench driver of the autonomous harness (docs/HARNESS.md, H1): each case is sent through
/// the app's own screens as a user would send it, with the app tracing the reply (`--trace`).
/// The driver records what was on screen; the harness script pulls the traces from the phone and
/// joins the two (`scripts/bench-report.py`).
///
/// Run with `scripts/device-harness.sh bench` (a Release build). `BENCH_ONLY=id,id` runs some
/// cases. The app keeps the user's chats and settings: a case starts a new chat and sets only
/// what it names.
@MainActor
final class BenchUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUp() async throws {
    // Opt-in: the `ui` suite runs every other class of this target.
    guard ProcessInfo.processInfo.environment["HARNESS_BENCH"] == "1" else {
      throw XCTSkip("Run with scripts/device-harness.sh bench")
    }
    continueAfterFailure = true
  }

  func testBench() throws {
    let only = ProcessInfo.processInfo.environment["BENCH_ONLY"].map {
      Set($0.split(separator: ",").map(String.init))
    }
    var rows: [[String: Any]] = []
    for bench in BenchCase.all where only?.contains(bench.id) ?? true {
      let row = XCTContext.runActivity(named: "bench \(bench.id)") { _ in run(bench) }
      rows.append(row)
      attach(try JSONSerialization.data(withJSONObject: ["rows": rows], options: [.prettyPrinted, .sortedKeys]), named: "bench-surface.json")
    }
    XCTAssertFalse(rows.isEmpty, "No bench case matched BENCH_ONLY")
  }

  /// One case: launch, set the modes, send, wait, read the screen.
  private func run(_ bench: BenchCase) -> [String: Any] {
    var row: [String: Any] = ["id": bench.id, "think": bench.think, "search": bench.search]
    app = XCUIApplication()
    // BENCH_TRACE=off measures what tracing costs: the same case, the screen's timings only.
    if ProcessInfo.processInfo.environment["BENCH_TRACE"] != "off" { app.launchArguments = ["--trace"] }
    app.launchEnvironment["AGELLO_BENCH_DRAFT"] = bench.prompt
    app.launch()

    guard element("chat.input").waitForExistence(timeout: 20) else {
      XCTFail("\(bench.id): no composer")
      return row
    }
    let loading = element("chat.banner.loading")
    if loading.exists { _ = loading.waitForNonExistence(timeout: 180) }
    if element("chat.banner.download").exists || element("chat.banner.failed").exists {
      XCTFail("\(bench.id): the model isn't ready")
      return row
    }
    setToggle("composer.think", to: bench.think)
    setToggle("composer.search", to: bench.search)
    row["thinkShown"] = element("composer.think").value as? String ?? ""
    if bench.think, let budget = bench.thinkingBudget { row["thinkBudgetSet"] = setThinkBudget(budget) }

    let send = element("chat.send")
    guard send.waitForExistence(timeout: 10) else {
      XCTFail("\(bench.id): the draft didn't arrive, so there is no Send button")
      return row
    }
    attachScreenshot("bench-\(bench.id)-before-send")
    guard send.isHittable else {
      XCTFail("\(bench.id): Send isn't on screen")
      return row
    }
    let sent = Date()
    send.tap()
    row["sentAt"] = ISO8601DateFormatter().string(from: sent)

    // Started: Stop shows. First text: the reply's bubble exists with a label.
    let stop = element("chat.stop")
    if stop.waitForExistence(timeout: 30) { row["secondsToStop"] = Date().timeIntervalSince(sent) }
    let bubble = app.descendants(matching: .any).matching(identifier: "message.model").firstMatch
    if wait(upTo: bench.timeout, every: 2, until: { bubble.exists }) {
      row["secondsToFirstText"] = Date().timeIntervalSince(sent)
    }
    let finished = wait(upTo: bench.timeout, every: 5, until: { !stop.exists })
    row["finished"] = finished
    row["secondsToDone"] = Date().timeIntervalSince(sent)
    XCTAssertTrue(finished, "\(bench.id): still writing after \(Int(bench.timeout)) s")

    // What the screen holds: the reply as VoiceOver reads it, the banner if any, and proof
    // that both ends of the chat can be reached.
    let spoken = bubble.exists ? bubble.label : ""
    row["screenCharacters"] = spoken.count
    row["screenTail"] = String(spoken.suffix(200))
    row["codeBlocksOnScreen"] = app.descendants(matching: .any).matching(identifier: "message.code").count
    row["notice"] = element("chat.banner.notice").exists ? element("chat.banner.notice").label : ""
    row["error"] = element("chat.banner.error").exists ? element("chat.banner.error").label : ""
    attach(Data(spoken.utf8), named: "bench-\(bench.id)-screen.txt")
    attachScreenshot("bench-\(bench.id)-end")
    let chat = app.scrollViews.firstMatch
    if chat.exists {
      for _ in 0..<12 { chat.swipeDown(velocity: .fast) }
      attachScreenshot("bench-\(bench.id)-top")
      row["topReached"] = app.descendants(matching: .any).matching(identifier: "message.user").firstMatch.isHittable
    }
    app.terminate()
    return row
  }

  /// Waits for `condition`, looking every `interval` seconds. Each look has the app snapshot its
  /// whole screen: looking every second while a reply streamed cost it a sixth of its speed
  /// (40 tok/s against 49, 2026-11-10). The trace holds the exact times; these are the screen's.
  private func wait(upTo timeout: TimeInterval, every interval: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      Thread.sleep(forTimeInterval: interval)
    }
    return condition()
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// Taps a mode pill until it reads `on` (its value is "On" or "Off").
  private func setToggle(_ identifier: String, to on: Bool) {
    let toggle = element(identifier)
    guard toggle.waitForExistence(timeout: 5) else { return }
    if (toggle.value as? String == "On") != on { toggle.tap() }
    let wanted = NSPredicate(format: "value == %@", on ? "On" : "Off")
    _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: wanted, object: toggle)], timeout: 5)
  }

  /// Settings → Advanced → Reasoning: steps the budget to `tokens` (128 a tap) and comes back to
  /// the chat. Returns the budget the stepper shows at the end.
  private func setThinkBudget(_ tokens: Int) -> Int {
    element("chat.drawer").tap()
    guard element("drawer.settings").waitForExistence(timeout: 5) else { return -1 }
    element("drawer.settings").tap()
    let advanced = element("settings.advanced")
    for _ in 0..<6 where !advanced.exists || !advanced.isHittable { app.swipeUp() }
    guard advanced.waitForExistence(timeout: 5) else { return -1 }
    advanced.tap()
    // The stepper's two buttons carry its identifier with a suffix; the row's text shows the value.
    let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Budget:'")).firstMatch
    guard title.waitForExistence(timeout: 5) else { return -1 }
    func shown() -> Int { Int(title.label.filter(\.isNumber)) ?? -1 }
    func button(_ name: String) -> XCUIElement {
      let own = NSPredicate(
        format: "identifier BEGINSWITH 'advanced.thinkBudget' AND (identifier ENDSWITH %@ OR label == %@)", name, name)
      let match = app.buttons.matching(own).firstMatch
      return match.exists ? match : app.buttons[name].firstMatch
    }
    for _ in 0..<40 {
      let now = shown()
      guard now > 0, now != tokens else { break }
      let step = button(now < tokens ? "Increment" : "Decrement")
      guard step.exists else { break }
      step.tap()
    }
    let result = shown()
    app.navigationBars["Advanced"].buttons.element(boundBy: 0).tap()
    let done = element("settings.done")
    if done.waitForExistence(timeout: 5) {
      done.tap()
      _ = done.waitForNonExistence(timeout: 5)
    }
    // Settings opened from the drawer, which is still open under the sheet: close it once the
    // sheet is gone, and again if the first tap landed while it was still sliding away.
    let close = element("drawer.close")
    for _ in 0..<3 where close.waitForExistence(timeout: 2) {
      let hittable = NSPredicate(format: "isHittable == true")
      _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hittable, object: close)], timeout: 3)
      close.tap()
      if close.waitForNonExistence(timeout: 3) { break }
    }
    _ = element("chat.input").waitForExistence(timeout: 5)
    return result
  }

  private func attach(_ data: Data, named name: String) {
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: name.hasSuffix(".json") ? "public.json" : "public.plain-text")
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func attachScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
