import Foundation
import Metal

/// What the command line lets the engine count on (``MemoryProbe``'s per-platform half).
///
/// On the iPhone the limit is jetsam's. Here it's simulated, the iPhone 17 Pro's 8 GiB by
/// default, so the engine's decisions (the window at load, keeping the chat across helpers,
/// stopping a reply) are the phone's and don't move with what else this Mac is running. Nothing
/// is enforced: a run over the limit isn't killed, it only reads as out of room.
extension MemoryProbe {
  /// The simulated limit less the footprint, at least 1 (0 reads as "not reported").
  static func availableBytes() -> UInt64 {
    guard let limit = CommandLineMemory.limitBytes else { return 0 }
    let footprint = footprintBytes()
    return max(limit > footprint ? limit - footprint : 0, 1)
  }

  static func appMemoryLimitBytes() -> UInt64? { CommandLineMemory.limitBytes }
}

enum CommandLineMemory {
  /// The iPhone 17 Pro's app limit with the memory entitlements (8 GiB, read as 8.59 GB).
  static let iPhoneLimitBytes: UInt64 = 8_589_934_592
  static let variable = "AGELLO_CLI_MEMORY_LIMIT"

  /// From `AGELLO_CLI_MEMORY_LIMIT`, which the command sets from `--memory-limit` before the
  /// engine first asks: a number of GB, `metal` (this Mac's Metal working set, capped at its
  /// memory) or `none` (no limit reported, as in the simulator).
  static let limitBytes: UInt64? = limit(from: ProcessInfo.processInfo.environment[variable])

  static func limit(from value: String?) -> UInt64? {
    switch value {
    case nil, "": return iPhoneLimitBytes
    case "none": return nil
    case "metal":
      guard let workingSet = MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize else { return nil }
      return min(workingSet, ProcessInfo.processInfo.physicalMemory)
    case let text?:
      guard let gigabytes = Double(text), gigabytes > 0 else { return iPhoneLimitBytes }
      return UInt64(gigabytes * 1_000_000_000)
    }
  }
}
