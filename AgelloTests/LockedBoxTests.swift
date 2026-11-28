import Dispatch
import Foundation
import XCTest

@testable import Agello

private enum LockedBoxTestError: Error, Equatable {
  case intentional(step: Int)
}

private final class LifetimeProbe: @unchecked Sendable {
  let label: String
  private let deinitCounter: LockedBox<Int>

  init(label: String, deinitCounter: LockedBox<Int>) {
    self.label = label
    self.deinitCounter = deinitCounter
  }

  deinit {
    deinitCounter.withLock { $0 += 1 }
  }
}

/// Static `LockedBox` fixtures exercising the exact `static let` reference-payload pattern
/// (`String`, `[String: Any]`, closures, custom `class`) that crashed `Synchronization.Mutex`
/// under Swift 6 `-O` Release codegen (`APP-14`).
private enum StaticLockedBoxFixtures {
  static let heapString = LockedBox(String(repeating: "agello-static-rope-", count: 4))
  static let metadata = LockedBox<[String: Any]>(["initial": "ready"])
  static let formatter = LockedBox<(@Sendable (Int) -> String)?>(nil)
  static let probe = LockedBox<LifetimeProbe?>(nil)
}

final class LockedBoxTests: XCTestCase {
  override func tearDown() {
    StaticLockedBoxFixtures.heapString.withLock { $0 = "" }
    StaticLockedBoxFixtures.metadata.withLock { $0.removeAll() }
    StaticLockedBoxFixtures.formatter.withLock { $0 = nil }
    StaticLockedBoxFixtures.probe.withLock { $0 = nil }
    GPUGate.set(true)
    TurnSecurityContext.reset()
    ToolConfirmationGate.setTestHandler(nil)
    TurnContactRoster.reset()
    ToolCardRecorder.reset()
    ToolBudget.reset()
    WebSourcesRecorder.reset()
    super.tearDown()
  }

  func testReadWriteAndDiscardableResult() {
    let box = LockedBox(10)
    box.withLock { value -> Int in
      value += 5
      return value
    }
    let doubled = box.withLock { value -> Int in
      value *= 2
      return value
    }
    XCTAssertEqual(doubled, 30)
    XCTAssertEqual(box.withLock { $0 }, 30)
  }

  func testConcurrentTaskAndThreadContention() async {
    struct CounterState: Sendable {
      var count = 0
      var history: [Int] = []
    }

    let box = LockedBox(CounterState())
    StaticLockedBoxFixtures.heapString.withLock {
      $0 = String(repeating: "seed-prefix-", count: 4)
    }

    let taskWorkers = 24
    let iterationsPerTask = 200
    await withTaskGroup(of: Void.self) { group in
      for worker in 0..<taskWorkers {
        group.addTask {
          for step in 0..<iterationsPerTask {
            box.withLock { state in
              state.count += 1
              if step.isMultiple(of: 50) {
                state.history.append(worker * 1_000 + step)
              }
            }
            if step.isMultiple(of: 40) {
              let utf8Count = StaticLockedBoxFixtures.heapString.withLock { text -> Int in
                text = "worker-\(worker)-step-\(step)-" + String(repeating: "x", count: 24)
                return text.utf8.count
              }
              XCTAssertGreaterThan(utf8Count, 30)
            }
          }
        }
      }
    }

    let threadWorkers = 16
    let iterationsPerThread = 200
    DispatchQueue.concurrentPerform(iterations: threadWorkers) { worker in
      for step in 0..<iterationsPerThread {
        box.withLock { state in
          state.count += 1
          if step == 0 {
            state.history.append(-1 - worker)
          }
        }
      }
    }

    let snapshot = box.withLock { $0 }
    let expectedTotal = taskWorkers * iterationsPerTask + threadWorkers * iterationsPerThread
    XCTAssertEqual(snapshot.count, expectedTotal)
    XCTAssertEqual(snapshot.history.count, taskWorkers * (iterationsPerTask / 50) + threadWorkers)
  }

  func testThrowingClosureRethrowsAndUnlocksImmediately() async {
    let box = LockedBox(["initial"])

    XCTAssertThrowsError(
      try box.withLock { items -> Int in
        items.append("before-throw")
        throw LockedBoxTestError.intentional(step: 1)
      }
    ) { error in
      XCTAssertEqual(error as? LockedBoxTestError, .intentional(step: 1))
    }

    // Re-acquiring on both the calling thread and a separate thread proves `NSLock` unlocked in
    // `defer` when `body` threw (a locked `NSLock` would deadlock both callers).
    box.withLock { $0.append("same-thread-after-throw") }
    let itemsFromDetachedTask = await Task.detached {
      box.withLock { items -> [String] in
        items.append("other-thread-after-throw")
        return items
      }
    }.value

    XCTAssertEqual(
      itemsFromDetachedTask,
      ["initial", "before-throw", "same-thread-after-throw", "other-thread-after-throw"]
    )
  }

  func testReferenceTypesAndDeallocationWithoutLeaks() {
    let deinitCount = LockedBox(0)
    weak var weakDirectProbe: LifetimeProbe?
    weak var weakDictionaryProbe: LifetimeProbe?
    weak var weakClosureProbe: LifetimeProbe?
    weak var weakStaticProbe: LifetimeProbe?

    do {
      // 1. Custom class stored in an instance LockedBox releases when the box deallocates.
      var scopedBox: LockedBox<LifetimeProbe>? = LockedBox(
        LifetimeProbe(label: "scoped-box", deinitCounter: deinitCount)
      )
      weakDirectProbe = scopedBox?.withLock { $0 }
      XCTAssertEqual(scopedBox?.withLock { $0.label }, "scoped-box")
      XCTAssertNotNil(weakDirectProbe)
      scopedBox = nil
      XCTAssertNil(weakDirectProbe)
      XCTAssertEqual(deinitCount.withLock { $0 }, 1)

      // 2. Heterogeneous `[String: Any]` + heap `String` in static LockedBox releases entries cleanly.
      let dictProbe = LifetimeProbe(label: "dict-entry", deinitCounter: deinitCount)
      weakDictionaryProbe = dictProbe
      let longText = String(repeating: "non-sso-heap-string-payload-", count: 6)
      StaticLockedBoxFixtures.metadata.withLock { dict in
        dict["probe"] = dictProbe
        dict["text"] = longText
        dict["numbers"] = [1, 2, 3, 4]
      }
    }

    XCTAssertNotNil(weakDictionaryProbe)
    let readBackText = StaticLockedBoxFixtures.metadata.withLock { $0["text"] as? String }
    XCTAssertEqual(readBackText, String(repeating: "non-sso-heap-string-payload-", count: 6))
    StaticLockedBoxFixtures.metadata.withLock { $0.removeAll() }
    XCTAssertNil(weakDictionaryProbe)
    XCTAssertEqual(deinitCount.withLock { $0 }, 2)

    // 3. Closure capturing a reference object releases its capture when replaced.
    do {
      let captured = LifetimeProbe(label: "captured", deinitCounter: deinitCount)
      weakClosureProbe = captured
      StaticLockedBoxFixtures.formatter.withLock { slot in
        slot = { value in "\(captured.label):\(value)" }
      }
    }
    let formatted = StaticLockedBoxFixtures.formatter.withLock { $0?(42) }
    XCTAssertEqual(formatted, "captured:42")
    XCTAssertNotNil(weakClosureProbe)
    StaticLockedBoxFixtures.formatter.withLock { $0 = nil }
    XCTAssertNil(weakClosureProbe)
    XCTAssertEqual(deinitCount.withLock { $0 }, 3)

    // 4. Custom class in static LockedBox releases when overwritten with nil.
    do {
      let staticItem = LifetimeProbe(label: "static-item", deinitCounter: deinitCount)
      weakStaticProbe = staticItem
      StaticLockedBoxFixtures.probe.withLock { $0 = staticItem }
    }
    XCTAssertEqual(StaticLockedBoxFixtures.probe.withLock { $0?.label }, "static-item")
    StaticLockedBoxFixtures.probe.withLock { $0 = nil }
    XCTAssertNil(weakStaticProbe)
    XCTAssertEqual(deinitCount.withLock { $0 }, 4)
  }

  func testMigratedStaticContainersRoundTrip() {
    GPUGate.set(false)
    XCTAssertFalse(GPUGate.isOpen)
    GPUGate.set(true)
    XCTAssertTrue(GPUGate.isOpen)

    TurnSecurityContext.reset()
    TurnSecurityContext.recordUntrusted(source: "file:notes.txt")
    XCTAssertTrue(TurnSecurityContext.isTainted)
    XCTAssertEqual(TurnSecurityContext.sources, ["file:notes.txt"])

    TurnContactRoster.reset()
    TurnContactRoster.registerUserText("Email alice@example.com about Friday")
    XCTAssertEqual(
      TurnContactRoster.unverifiedRecipients(from: ["alice@example.com", "intruder@evil.example"]),
      ["intruder@evil.example"]
    )

    let activityCursor = ToolActivity.cursor
    ToolActivity.record("unit_probe", summary: "checked LockedBox")
    XCTAssertEqual(ToolActivity.invocations(since: activityCursor), ["unit_probe"])

    WebSourcesRecorder.reset()
    WebSourcesRecorder.record([SourceRecord(index: 1, title: "Agello", url: "https://example.com")])
    XCTAssertEqual(WebSourcesRecorder.nextIndex, 2)
    XCTAssertEqual(WebSourcesRecorder.drain().count, 1)
    XCTAssertEqual(WebSourcesRecorder.nextIndex, 1)
  }
}
