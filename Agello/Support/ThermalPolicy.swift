import Foundation

/// Lightweight adaptive thermal & Low Power Mode policy for Apple Silicon iPhones:
/// keeps E4B foreground decode responsive while avoiding unnecessary UI re-renders, background
/// ANE batching, and post-reply GPU helper launches when the device warms up.
enum ThermalPolicy {
  struct Snapshot: Equatable, Sendable {
    var thermalState: ProcessInfo.ThermalState
    var lowPowerMode: Bool

    static var current: Snapshot {
      Snapshot(
        thermalState: ProcessInfo.processInfo.thermalState,
        lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }
  }

  struct Guidance: Equatable, Sendable {
    /// Minimum interval between SwiftData / SwiftUI stream flushes during generation.
    var streamFlushInterval: Duration
    /// Delay before running post-reply title & memory helpers (`nil` pauses discretionary helpers).
    var helperIdleDelay: Duration?
    /// Defer non-urgent background chat-list indexing (explicit user attachments still index unless paused).
    var deferBackgroundChatIndexing: Bool
    /// Pause background ANE indexing completely until thermal state drops below `.critical`.
    var pauseBackgroundANE: Bool
  }

  /// Pure decision table (unit-tested).
  static func guidance(for snapshot: Snapshot) -> Guidance {
    switch snapshot.thermalState {
    case .critical:
      return Guidance(
        streamFlushInterval: .milliseconds(250),
        helperIdleDelay: nil,
        deferBackgroundChatIndexing: true,
        pauseBackgroundANE: true)
    case .serious:
      return Guidance(
        streamFlushInterval: .milliseconds(200),
        helperIdleDelay: .seconds(30),
        deferBackgroundChatIndexing: true,
        pauseBackgroundANE: false)
    case .fair:
      return Guidance(
        streamFlushInterval: snapshot.lowPowerMode ? .milliseconds(200) : .milliseconds(100),
        helperIdleDelay: snapshot.lowPowerMode ? .seconds(25) : .seconds(15),
        deferBackgroundChatIndexing: true,
        pauseBackgroundANE: false)
    case .nominal:
      return Guidance(
        streamFlushInterval: snapshot.lowPowerMode ? .milliseconds(200) : .milliseconds(100),
        helperIdleDelay: snapshot.lowPowerMode ? .seconds(15) : HelperTasks.idleDelay,
        deferBackgroundChatIndexing: snapshot.lowPowerMode,
        pauseBackgroundANE: false)
    @unknown default:
      return Guidance(
        streamFlushInterval: .milliseconds(100),
        helperIdleDelay: HelperTasks.idleDelay,
        deferBackgroundChatIndexing: false,
        pauseBackgroundANE: false)
    }
  }

  static var current: Guidance {
    guidance(for: .current)
  }
}
