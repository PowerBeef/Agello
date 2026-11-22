import Foundation

/// macOS CLI no-op twin of `AgelloiOS/Platform/MetricKitStream.swift`: iOS 27 `.memoryException`
/// and `.peakMemory` MetricKit reports are iOS-only.
final class MetricKitStream: Sendable {
  static let shared = MetricKitStream()
  func start() {}
}
