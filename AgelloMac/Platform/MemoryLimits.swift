import Darwin
import Metal

/// What the Mac lets the app allocate (``MemoryProbe``'s per-platform half). No jetsam limit
/// here: the model lives in GPU memory, which Metal bounds by its working set.
extension MemoryProbe {
  /// Memory the system could hand out without swapping: free, inactive, speculative and
  /// purgeable pages.
  static func availableBytes() -> UInt64 {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    let pages =
      UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.speculative_count)
      + UInt64(stats.purgeable_count)
    return pages * UInt64(getpagesize())
  }

  /// The most the app should use: Metal's recommended working set, within physical memory.
  static func appMemoryLimitBytes() -> UInt64? {
    guard let workingSet = metalWorkingSet else { return nil }
    return min(workingSet, ProcessInfo.processInfo.physicalMemory)
  }

  private static let metalWorkingSet: UInt64? = MTLCreateSystemDefaultDevice()?.recommendedMaxWorkingSetSize
}
