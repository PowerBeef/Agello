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

/// Process memory as the system's out-of-memory killer (jetsam) sees it, including the kernel's
/// `ledger_phys_footprint_peak` high-water mark and GPU/ANE ledger splits.
enum MemoryProbe {
  /// Point-in-time snapshot of process memory ledgers and thermal state.
  struct Snapshot: Equatable, Sendable {
    var footprintBytes: UInt64
    var peakFootprintBytes: UInt64
    var availableBytes: UInt64
    var graphicsBytes: UInt64
    var neuralBytes: UInt64
    var compressedBytes: UInt64
    var thermalState: Int
    var capturedAt: Date

    func delta(from baseline: Snapshot) -> Delta {
      Delta(
        footprintDeltaBytes: Int64(footprintBytes) - Int64(baseline.footprintBytes),
        peakDeltaBytes: Int64(peakFootprintBytes) - Int64(baseline.peakFootprintBytes),
        graphicsDeltaBytes: Int64(graphicsBytes) - Int64(baseline.graphicsBytes),
        neuralDeltaBytes: Int64(neuralBytes) - Int64(baseline.neuralBytes))
    }
  }

  /// Signed ledger changes between two snapshots (bytes).
  struct Delta: Equatable, Sendable {
    var footprintDeltaBytes: Int64
    var peakDeltaBytes: Int64
    var graphicsDeltaBytes: Int64
    var neuralDeltaBytes: Int64

    var peakDeltaMB: Double { Double(peakDeltaBytes) / 1e6 }
    var graphicsDeltaMB: Double { Double(graphicsDeltaBytes) / 1e6 }
    var neuralDeltaMB: Double { Double(neuralDeltaBytes) / 1e6 }
  }

  /// Physical footprint in bytes: the number the jetsam limit applies to.
  static func footprintBytes() -> UInt64 {
    vmInfo()?.phys_footprint ?? 0
  }

  /// Kernel peak physical footprint since launch (`ledger_phys_footprint_peak`).
  static func peakFootprintBytes() -> UInt64 {
    guard let info = vmInfo() else { return 0 }
    let peak = info.ledger_phys_footprint_peak
    return peak > 0 ? UInt64(peak) : UInt64(info.phys_footprint)
  }

  /// Captures physical footprint, peak footprint, Metal graphics ledger, ANE neural ledger,
  /// available jetsam headroom, and current thermal state.
  static func capture(now: Date = .now) -> Snapshot {
    let info = vmInfo()
    let footprint = info.map { UInt64($0.phys_footprint) } ?? 0
    let peakRaw = info?.ledger_phys_footprint_peak ?? 0
    let peak = peakRaw > 0 ? UInt64(peakRaw) : footprint
    let graphics = info.map {
      UInt64(max(0, $0.ledger_tag_graphics_footprint + $0.ledger_tag_graphics_footprint_compressed))
    } ?? 0
    let neural = info.map {
      UInt64(max(0, $0.ledger_tag_neural_footprint + $0.ledger_tag_neural_footprint_compressed))
    } ?? 0
    let compressed = info.map { UInt64($0.compressed) } ?? 0
    return Snapshot(
      footprintBytes: footprint,
      peakFootprintBytes: peak,
      availableBytes: availableBytes(),
      graphicsBytes: graphics,
      neuralBytes: neural,
      compressedBytes: compressed,
      thermalState: ProcessInfo.processInfo.thermalState.rawValue,
      capturedAt: now)
  }

  static func thermalStateLabel(_ raw: Int) -> String {
    switch raw {
    case ProcessInfo.ThermalState.nominal.rawValue: "nominal"
    case ProcessInfo.ThermalState.fair.rawValue: "fair"
    case ProcessInfo.ThermalState.serious.rawValue: "serious"
    case ProcessInfo.ThermalState.critical.rawValue: "critical"
    default: "unknown(\(raw))"
    }
  }

  /// Hands the system the free pages malloc's zones still hold, and returns how many bytes that
  /// was: on a memory warning, before anything else. It doesn't empty macOS's cache of freed large
  /// blocks, which held 1.4 GB after a 200-turn session with images and reloads on the Mac (probe
  /// 38, 2026-11-17; `vmmap`'s "Malloc Large (empty)"); only `MallocLargeCache=0` at launch does.
  @discardableResult
  static func returnFreedMemory() -> UInt64 {
    UInt64(malloc_zone_pressure_relief(nil, 0))
  }

  /// Where the footprint sits, in GB: the kernel's ledgers for graphics (Metal), media and the
  /// Neural Engine, peak physical footprint, purgeable memory, and malloc's bytes in use against
  /// what its zones hold. Read by the memory scenarios and diagnostics export.
  static func breakdown() -> [String: Double] {
    guard let info = vmInfo() else { return [:] }
    var malloc = malloc_statistics_t()
    malloc_zone_statistics(nil, &malloc)
    func gb(_ bytes: Int64) -> Double { Double(bytes) / 1e9 }
    let peak = info.ledger_phys_footprint_peak > 0
      ? Double(info.ledger_phys_footprint_peak) / 1e9
      : Double(info.phys_footprint) / 1e9
    return [
      "footprint": Double(info.phys_footprint) / 1e9,
      "peak": peak,
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

  /// What the app may still allocate before its limit (jetsam's), or nil where no limit is
  /// reported.
  static func roomBytes() -> UInt64? {
    guard let limit = appMemoryLimitBytes() else { return nil }
    let footprint = footprintBytes()
    return limit > footprint ? limit - footprint : 0
  }

  static var summary: String {
    String(
      format: "footprint %.2f GB, peak %.2f GB, available %.2f GB",
      Double(footprintBytes()) / 1e9, Double(peakFootprintBytes()) / 1e9,
      Double(availableBytes()) / 1e9)
  }
}

extension UserDefaults {
  /// A saved Codable value, or nil when there is none or it no longer decodes.
  func decoded<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
    data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
  }
}
