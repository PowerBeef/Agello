import Darwin
import Foundation
import os

/// Structured logging. Read on device with Console.app or
/// `log stream --predicate 'subsystem == "com.patricedery.agello"'`.
enum Log {
  private static let subsystem = "com.patricedery.agello"
  static let engine = Logger(subsystem: subsystem, category: "engine")
  static let generation = Logger(subsystem: subsystem, category: "generation")
  static let lifecycle = Logger(subsystem: subsystem, category: "lifecycle")
}

/// Process memory as the system's out-of-memory killer (jetsam) sees it.
enum MemoryProbe {
  /// Physical footprint in bytes: the number the jetsam limit applies to.
  static func footprintBytes() -> UInt64 {
    vmInfo()?.phys_footprint ?? 0
  }

  /// Where the footprint sits, in GB: the kernel's ledgers for graphics
  /// (Metal), media and the Neural Engine, purgeable memory, and malloc's
  /// bytes in use against what its zones hold. Read by the memory scenarios.
  static func breakdown() -> [String: Double] {
    guard let info = vmInfo() else { return [:] }
    var malloc = malloc_statistics_t()
    malloc_zone_statistics(nil, &malloc)
    func gb(_ bytes: Int64) -> Double { Double(bytes) / 1e9 }
    return [
      "footprint": Double(info.phys_footprint) / 1e9,
      "compressed": Double(info.compressed) / 1e9,
      "graphics": gb(info.ledger_tag_graphics_footprint + info.ledger_tag_graphics_footprint_compressed),
      "media": gb(info.ledger_tag_media_footprint + info.ledger_tag_media_footprint_compressed),
      "neural": gb(info.ledger_tag_neural_footprint + info.ledger_tag_neural_footprint_compressed),
      "purgeableNonvolatile": gb(info.ledger_purgeable_nonvolatile + info.ledger_purgeable_novolatile_compressed),
      "mallocInUse": Double(malloc.size_in_use) / 1e9,
      "mallocHeld": Double(malloc.size_allocated) / 1e9,
    ]
  }

  private static func vmInfo() -> task_vm_info_data_t? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info : nil
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
