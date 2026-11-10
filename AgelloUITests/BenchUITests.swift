import UIKit
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
    UIDevice.current.isBatteryMonitoringEnabled = true
    for bench in BenchCase.all where only?.contains(bench.id) ?? true {
      // An interrupted case (a call, a lock, the app sent to the background) runs once more
      // and isn't a failure unless it's interrupted again.
      var row = XCTContext.runActivity(named: "bench \(bench.id)") { _ in run(bench, isLastAttempt: false) }
      if row["interrupted"] as? Bool == true {
        let first = row["interruption"] as? String ?? "interrupted"
        row = XCTContext.runActivity(named: "bench \(bench.id), again") { _ in run(bench, isLastAttempt: true) }
        row["attempts"] = 2
        row["firstAttempt"] = first
      }
      rows.append(row)
      attach(try JSONSerialization.data(withJSONObject: ["rows": rows], options: [.prettyPrinted, .sortedKeys]), named: "bench-surface.json")
    }
    XCTAssertFalse(rows.isEmpty, "No bench case matched BENCH_ONLY")
  }

  /// One case: launch, set the modes, send, wait, read the screen.
  private func run(_ bench: BenchCase, isLastAttempt: Bool) -> [String: Any] {
    var row: [String: Any] = ["id": bench.id, "think": bench.think, "search": bench.search]
    // Heat slows decoding by up to a fifth: BENCH_COOL=1 waits for the phone to cool first.
    if ProcessInfo.processInfo.environment["BENCH_COOL"] == "1" {
      let started = Date()
      _ = wait(upTo: 600, every: 10, until: { ProcessInfo.processInfo.thermalState == .nominal })
      row["secondsCooling"] = Date().timeIntervalSince(started)
    }
    row["thermalStateAtStart"] = ProcessInfo.processInfo.thermalState.rawValue
    row["battery"] = Double(UIDevice.current.batteryLevel)
    row["charging"] = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
    app = XCUIApplication()
    // BENCH_TRACE=off measures what tracing costs: the same case, the screen's timings only.
    app.launchArguments = bench.launchArguments
    if ProcessInfo.processInfo.environment["BENCH_TRACE"] != "off" { app.launchArguments.append("--trace") }
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

    // One turn per message: the prompt (already the composer's draft), then each follow-up typed.
    var turns: [[String: Any]] = []
    for (index, message) in ([bench.prompt] + bench.followUps).enumerated() {
      if index > 0 {
        let input = element("chat.input")
        input.tap()
        input.typeText(message)
      }
      let turn = sendAndWait(bench, turn: index + 1, isLastAttempt: isLastAttempt)
      turns.append(turn)
      if turn["finished"] as? Bool != true || turn["foreground"] as? Bool != true {
        row["interrupted"] = true
        row["interruption"] =
          turn["foreground"] as? Bool == true
          ? "turn \(index + 1) didn't finish" : "the app left the foreground in turn \(index + 1)"
        break
      }
    }
    row["turns"] = turns
    let chat = app.scrollViews.firstMatch
    if chat.exists {
      for _ in 0..<12 { chat.swipeDown(velocity: .fast) }
      attachScreenshot("bench-\(bench.id)-top")
      row["topReached"] = app.descendants(matching: .any).matching(identifier: "message.user").firstMatch.isHittable
    }
    // The title and memory helpers start once the chat has been idle for a few seconds: leave
    // them the time, so the last reply's trace holds them.
    Thread.sleep(forTimeInterval: 8)
    app.terminate()
    return row
  }

  /// Taps Send, waits for the reply, and reads the screen: one turn's row.
  private func sendAndWait(_ bench: BenchCase, turn number: Int, isLastAttempt: Bool) -> [String: Any] {
    var turn: [String: Any] = ["turn": number]
    let name = "bench-\(bench.id)-\(number)"
    let send = element("chat.send")
    guard send.waitForExistence(timeout: 10), send.isHittable else {
      attachScreenshot("\(name)-no-send")
      XCTFail("\(bench.id) turn \(number): no Send button (the draft didn't arrive, or it's off screen)")
      return turn
    }
    let bubbles = app.descendants(matching: .any).matching(identifier: "message.model")
    let before = bubbles.count
    let sent = Date()
    send.tap()
    turn["sentAt"] = ISO8601DateFormatter().string(from: sent)

    // Started: Stop shows. First text: a new reply bubble. Search and file reading come first.
    let stop = element("chat.stop")
    if wait(upTo: 120, every: 1, until: { stop.exists }) { turn["secondsToStop"] = Date().timeIntervalSince(sent) }
    if wait(upTo: bench.timeout, every: 2, until: { bubbles.count > before }) {
      turn["secondsToFirstText"] = Date().timeIntervalSince(sent)
    }
    // Done when Stop goes, or interrupted when the app is no longer in front.
    let finished = wait(
      upTo: bench.timeout, every: 5, until: { !stop.exists || app.state != .runningForeground })
    turn["foreground"] = app.state == .runningForeground
    turn["finished"] = finished && !stop.exists
    turn["secondsToDone"] = Date().timeIntervalSince(sent)
    if isLastAttempt {
      XCTAssertTrue(
        turn["finished"] as? Bool == true && turn["foreground"] as? Bool == true,
        "\(bench.id) turn \(number): interrupted or still writing after \(Int(bench.timeout)) s")
    }

    // What the screen holds: the reply as VoiceOver reads it, and any banner.
    let bubble = bubbles.element(boundBy: max(0, bubbles.count - 1))
    let spoken = bubble.exists ? bubble.label : ""
    turn["screenCharacters"] = spoken.count
    turn["notice"] = element("chat.banner.notice").exists ? element("chat.banner.notice").label : ""
    turn["error"] = element("chat.banner.error").exists ? element("chat.banner.error").label : ""
    attach(Data(spoken.utf8), named: "\(name)-screen.txt")
    attachScreenshot("\(name)-end")
    return turn
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
