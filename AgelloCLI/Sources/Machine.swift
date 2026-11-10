import Foundation
import Metal

/// This Mac and the runtime in use, for `agello env` and every record: enough to tell which
/// build produced a number and whether the machine was in a state to trust it.
enum Machine {
  static func record(paths: [String: String]) -> [String: Any] {
    let gpu = MTLCreateSystemDefaultDevice()
    let process = ProcessInfo.processInfo
    var record: [String: Any] = [
      "hardware": sysctl("hw.model") ?? "?",
      "chip": sysctl("machdep.cpu.brand_string") ?? "?",
      "memoryGB": Double(process.physicalMemory) / 1e9,
      "os": process.operatingSystemVersionString,
      "lowPower": process.isLowPowerModeEnabled,
      "thermalState": process.thermalState.rawValue,
      "gpu": gpu?.name ?? "?",
      "gpuWorkingSetGB": Double(gpu?.recommendedMaxWorkingSetSize ?? 0) / 1e9,
      "paths": paths,
      "simulatedMemoryLimitGB": MemoryProbe.appMemoryLimitBytes().map { Double($0) / 1e9 } ?? NSNull(),
      "supportedDevice": DeviceProfile.isSupportedDevice,
    ]
    record["runtimeBuild"] = EngineCache.runtimeBuildInfo() ?? NSNull()
    var models: [String: Any] = [:]
    for spec in ModelCatalog.all {
      let path = (paths["models"] ?? "") + "/" + spec.fileName
      let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
      models[spec.fileName] = size == spec.sizeBytes ? "ready" : (size == nil ? "missing" : "wrong size")
    }
    record["models"] = models
    return record
  }

  private static func sysctl(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(cString: buffer)
  }
}
