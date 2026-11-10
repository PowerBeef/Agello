import Dispatch
import Foundation

/// The iPhone counts late frames while a reply is traced (``ReplyTrace``). A command line draws
/// none, but what makes a frame late is the same: the main thread held up. A 60 Hz timer on the
/// main queue stands in for the display, and a tick 50 ms or more late is a hitch.
@MainActor
enum FrameMonitor {
  private static var timer: (any DispatchSourceTimer)?
  private static var last: UInt64 = 0
  private static var frames = 0
  private static var hitches = 0
  private static var hitchSeconds = 0.0
  private static var longest = 0.0

  static func start() {
    timer?.cancel()
    (last, frames, hitches, hitchSeconds, longest) = (0, 0, 0, 0, 0)
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(1))
    timer.setEventHandler { MainActor.assumeIsolated { tick() } }
    timer.resume()
    self.timer = timer
  }

  private static func tick() {
    let now = DispatchTime.now().uptimeNanoseconds
    defer { last = now }
    guard last > 0 else { return }
    let gap = Double(now - last) / 1e9
    frames += 1
    longest = max(longest, gap)
    if gap >= 0.05 {
      hitches += 1
      hitchSeconds += gap
    }
  }

  /// Stops and returns what it saw (empty when it wasn't running).
  static func stop() -> [String: Double] {
    guard let timer else { return [:] }
    timer.cancel()
    self.timer = nil
    return [
      "frames": Double(frames), "hitches": Double(hitches), "hitchSeconds": hitchSeconds,
      "longestGapSeconds": longest,
    ]
  }
}
