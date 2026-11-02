import XCTest

@testable import Agello

extension ProbeScenarioTests {
  /// Probe 22: critical memory pressure, which only the Mac reports, never unloads E4B during a
  /// reply, unloads it once idle, and the next message loads it again from the engine cache
  /// (``MemoryPolicy``). It calls the app's handler directly instead of `memory_pressure -S`,
  /// which would signal every process on the machine.
  func test22_CriticalMemoryPressure() async throws {
    try await requireLoadedModel()
    let thread = harness.newThread()
    let replying = Task { await harness.ask("Count from 1 to 40, one number per line.", in: thread).accepted }
    try await harness.waitUntil("the reply starts", timeout: 120) { appState.isGenerating }
    await appState.relieveMemoryPressure(level: .critical)
    let loadedDuringReply = await appState.engine.isLoaded
    let firstAccepted = await replying.value

    await appState.relieveMemoryPressure(level: .critical)
    let loadedWhenIdle = await appState.engine.isLoaded
    let second = await harness.ask("Now count from 41 to 45.", in: thread)
    harness.record(
      "probe22_critical_memory_pressure",
      [
        "loadedDuringReply": loadedDuringReply, "firstAccepted": firstAccepted,
        "loadedWhenIdle": loadedWhenIdle, "secondAccepted": second.accepted,
        "secondSeconds": second.seconds, "secondReply": String(second.text.prefix(80)),
      ], in: self)
    XCTAssertTrue(loadedDuringReply, "critical pressure unloaded E4B mid-reply")
    XCTAssertTrue(firstAccepted, appState.generationError ?? "rejected")
    XCTAssertFalse(loadedWhenIdle, "critical pressure left an idle E4B loaded")
    XCTAssertTrue(second.accepted, appState.generationError ?? "rejected")
    XCTAssertEqual(appState.engineState, .ready)
  }
}
