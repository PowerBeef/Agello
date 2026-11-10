import CryptoKit
import Foundation
import Metal

/// This Mac and the runtime in use, for `agello env` and every record: enough to tell which
/// build produced a number. The keys are `agello-bench`'s (the fork's `BenchKit.Machine`), so
/// its scripts read a record of either tool.
@MainActor
enum Machine {
  /// Captured once: the runtime's hash reads a 100 MB file.
  static let record: [String: Any] = {
    let gpu = MTLCreateSystemDefaultDevice()
    let process = ProcessInfo.processInfo
    let runtime = runtimePath() ?? ""
    return [
      "hardware": sysctl("hw.model"),
      "machine": sysctl("hw.machine"),
      "chip": sysctl("machdep.cpu.brand_string"),
      "os": "macOS \(process.operatingSystemVersionString)",
      "memoryGB": Double(process.physicalMemory) / 1e9,
      "isiOSAppOnMac": false,
      "lowPowerMode": process.isLowPowerModeEnabled,
      "gpu": gpu?.name ?? "none",
      "gpuAppleFamily": gpu.map { appleFamily($0) } ?? 0,
      "gpuWorkingSetGB": Double(gpu?.recommendedMaxWorkingSetSize ?? 0) / 1e9,
      "runtime": runtime,
      "runtimeSHA256": runtime.isEmpty ? "" : (try? sha256(of: URL(fileURLWithPath: runtime))) ?? "",
      "runtimeBuild": EngineCache.runtimeBuildInfo() ?? NSNull(),
    ]
  }()

  /// `agello env`: the machine, the folders in use, the models found, the limit simulated.
  static func environment(paths: [String: String]) -> [String: Any] {
    var models: [String: Any] = [:]
    for spec in ModelCatalog.all {
      let path = (paths["models"] ?? "") + "/" + spec.fileName
      let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
      models[spec.fileName] = size == spec.sizeBytes ? "ready" : (size == nil ? "missing" : "wrong size")
    }
    return [
      "machine": record, "paths": paths, "models": models,
      "simulatedMemoryLimitGB": MemoryProbe.appMemoryLimitBytes().map { Double($0) / 1e9 } ?? NSNull(),
      "supportedDevice": DeviceProfile.isSupportedDevice,
      "state": state(),
    ]
  }

  /// What this Mac is doing now: a number measured while it's busy, hot or swapping is suspect.
  static func state() -> [String: Any] {
    var load = [Double](repeating: 0, count: 3)
    getloadavg(&load, 3)
    let process = ProcessInfo.processInfo
    return [
      "loadAverage": load[0],
      "cores": process.activeProcessorCount,
      "thermal": process.thermalState.label,
      "lowPowerMode": process.isLowPowerModeEnabled,
      "memoryPressureEvents": MemoryPressureMonitor.events.withLock { $0.warnings },
    ]
  }

  static func sysctl(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
    return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
  }

  /// The newest Apple GPU family supported: 7 for A14 and M1, 9 for A17 Pro and M3, and so on.
  private static func appleFamily(_ device: any MTLDevice) -> Int {
    let family = (1001...1020).last { MTLGPUFamily(rawValue: $0).map(device.supportsFamily) ?? false }
    return family.map { $0 - 1000 } ?? 0
  }

  /// The image that defines LiteRT-LM's C API: the build being measured.
  private static func runtimePath() -> String? {
    guard let handle = dlopen(nil, RTLD_NOW), let symbol = dlsym(handle, "litert_lm_engine_settings_create")
    else { return nil }
    var info = Dl_info()
    guard dladdr(symbol, &info) != 0, let name = info.dli_fname else { return nil }
    return URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath().path
  }

  private static func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  /// The process's memory as the system accounts it (GPU buffers included), and its peak.
  static func footprint() -> (bytes: UInt64, peakBytes: UInt64) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return (0, 0) }
    return (info.phys_footprint, UInt64(info.ledger_phys_footprint_peak))
  }
}

extension ProcessInfo.ThermalState {
  var label: String {
    switch self {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
  }
}
