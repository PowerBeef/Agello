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
  /// The CPU figures are totals since boot (every core's busy seconds, and this process's), so
  /// two states give what the rest of the Mac used in between.
  static func state() -> [String: Any] {
    var load = [Double](repeating: 0, count: 3)
    getloadavg(&load, 3)
    let process = ProcessInfo.processInfo
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let own = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
      + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    return [
      "loadAverage": load[0],
      "cores": process.activeProcessorCount,
      "thermal": process.thermalState.label,
      "lowPowerMode": process.isLowPowerModeEnabled,
      "memoryPressureEvents": MemoryPressureMonitor.events.withLock { $0.warnings },
      "busyCoreSeconds": busyCoreSeconds(),
      "ownCPUSeconds": own,
      "uptimeSeconds": Double(DispatchTime.now().uptimeNanoseconds) / 1e9,
      "gpuUtilization": gpuUtilization() ?? NSNull(),
      "swapUsedMB": swapUsedMB(),
    ]
  }

  /// Why a number measured between two states shouldn't be trusted, if anything says so. The
  /// thresholds are loose on purpose: they flag a Mac that was clearly doing something else.
  static func suspicions(before: [String: Any], after: [String: Any]) -> [String] {
    func number(_ state: [String: Any], _ key: String) -> Double { (state[key] as? NSNumber)?.doubleValue ?? 0 }
    var reasons: [String] = []
    let seconds = max(0.001, number(after, "uptimeSeconds") - number(before, "uptimeSeconds"))
    let others =
      (number(after, "busyCoreSeconds") - number(before, "busyCoreSeconds")
        - (number(after, "ownCPUSeconds") - number(before, "ownCPUSeconds"))) / seconds
    if others > 2 { reasons.append(String(format: "other processes used %.1f cores", others)) }
    if let gpu = before["gpuUtilization"] as? NSNumber, gpu.doubleValue > 30 {
      reasons.append("the GPU was \(gpu.intValue) % busy before the case")
    }
    for state in [before, after] where state["thermal"] as? String != "nominal" {
      reasons.append("thermal state \(state["thermal"] as? String ?? "?")")
      break
    }
    if after["lowPowerMode"] as? Bool == true { reasons.append("Low Power Mode") }
    if number(after, "memoryPressureEvents") > number(before, "memoryPressureEvents") {
      reasons.append("memory pressure on this Mac")
    }
    if number(after, "swapUsedMB") - number(before, "swapUsedMB") > 200 { reasons.append("the Mac swapped") }
    return reasons
  }

  /// Seconds every core has spent busy (user, system, nice) since boot.
  private static func busyCoreSeconds() -> Double {
    var info = host_cpu_load_info()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    let ticks = Double(info.cpu_ticks.0) + Double(info.cpu_ticks.1) + Double(info.cpu_ticks.3)
    return ticks / Double(sysconf(_SC_CLK_TCK))
  }

  /// The GPU's "Device Utilization %" as IOKit's accelerator reports it (what Activity Monitor
  /// shows), from `ioreg`: readable without privileges.
  private static func gpuUtilization() -> Int? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    process.arguments = ["-r", "-c", "IOAccelerator", "-d", "1"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard let range = text.range(of: #""Device Utilization %"=(\d+)"#, options: .regularExpression) else { return nil }
    return Int(text[range].split(separator: "=").last ?? "")
  }

  private static func swapUsedMB() -> Double {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
    return Double(usage.xsu_used) / 1e6
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
