import QuartzCore

/// Late frames while a reply is traced (``ReplyTrace``): a display link on the main run loop
/// notes every gap between frames. A gap of 50 ms or more is a hitch the user can see, whatever
/// held the main thread (a write to the chat, a markdown parse, layout).
@MainActor
enum FrameMonitor {
  private final class Target: NSObject {
    var last: CFTimeInterval = 0
    var frames = 0
    var hitches = 0
    var hitchSeconds = 0.0
    var longest = 0.0

    @objc func tick(_ link: CADisplayLink) {
      defer { last = link.timestamp }
      guard last > 0 else { return }
      let gap = link.timestamp - last
      frames += 1
      longest = max(longest, gap)
      if gap >= 0.05 {
        hitches += 1
        hitchSeconds += gap
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
