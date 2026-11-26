import QuartzCore

/// Late frames while a reply is traced (``ReplyTrace``): a display link on the main run loop
/// compares each frame gap against ProMotion's active refresh interval (`targetTimestamp - timestamp`),
/// catching multi-frame drops at 120 Hz without false positives when ProMotion idles at 10–20 Hz.
@MainActor
enum FrameMonitor {
  private final class Target: NSObject {
    var lastTimestamp: CFTimeInterval = 0
    var lastExpectedDuration: CFTimeInterval = 0
    var frames = 0
    var hitches = 0
    var hitchSeconds = 0.0
    var longest = 0.0

    @objc func tick(_ link: CADisplayLink) {
      let currentExpected = link.targetTimestamp - link.timestamp
      defer {
        lastTimestamp = link.timestamp
        lastExpectedDuration = currentExpected
      }
      guard lastTimestamp > 0 else { return }
      let gap = link.timestamp - lastTimestamp
      frames += 1
      longest = max(longest, gap)
      // Use the larger of the previous and current expected frame durations so intentional
      // ProMotion ramp-downs (e.g. 120 Hz -> 60 Hz -> 10 Hz) never count as hitches.
      let rawExpected = max(lastExpectedDuration, currentExpected)
      let expected = (rawExpected > 0 && rawExpected.isFinite) ? rawExpected : (1.0 / 60.0)
      let overrun = gap - expected
      if overrun >= max(expected * 0.5, 0.005) {
        hitches += 1
        hitchSeconds += overrun
      }
    }
  }

  private static var link: CADisplayLink?
  private static var target: Target?

  static func start() {
    link?.invalidate()
    let target = Target()
    let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
    link.add(to: .main, forMode: .common)
    self.target = target
    self.link = link
  }

  /// Stops and returns what it saw (empty when it wasn't running).
  static func stop() -> [String: Double] {
    link?.invalidate()
    link = nil
    guard let target else { return [:] }
    self.target = nil
    return [
      "frames": Double(target.frames), "hitches": Double(target.hitches),
      "hitchSeconds": target.hitchSeconds, "longestGapSeconds": target.longest,
    ]
  }
}
