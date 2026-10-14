import Darwin
import Foundation
import os

/// Structured logging. Read on device with Console.app or
/// `log stream --predicate 'subsystem == "com.patricedery.irtchat"'`.
enum Log {
  private static let subsystem = "com.patricedery.irtchat"
  static let engine = Logger(subsystem: subsystem, category: "engine")
  static let generation = Logger(subsystem: subsystem, category: "generation")
  static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}

/// Process memory as the system's out-of-memory killer (jetsam) sees it.
enum MemoryProbe {
  /// Physical footprint in bytes: the number the jetsam limit applies to.
  static func footprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
  }

  /// Bytes the app can still allocate before hitting its jetsam limit.
  static func availableBytes() -> UInt64 {
    UInt64(os_proc_available_memory())
  }

  static var summary: String {
    String(
      format: "footprint %.2f GB, available %.2f GB",
      Double(footprintBytes()) / 1e9, Double(availableBytes()) / 1e9)
  }
}
