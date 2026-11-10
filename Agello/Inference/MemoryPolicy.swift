/// How low memory is, as the system says it: iOS's memory warning, the only level it sends.
enum MemoryPressureLevel: String, Sendable {
  case warning
}

/// What the app gives back when memory runs low.
struct MemoryRelief: OptionSet, Sendable {
  let rawValue: Int

  /// Stop a running reply if available memory is nearly gone
  /// (``DeviceProfile/shouldStopForMemory(availableBytes:)``), keeping its text.
  static let stopReplyIfExhausted = MemoryRelief(rawValue: 1 << 0)
  /// Unload EmbeddingGemma unless it's indexing; it reloads on its next use.
  static let releaseEmbedder = MemoryRelief(rawValue: 1 << 1)
}

enum MemoryPolicy {
  /// A warning stops a reply only when memory is nearly gone, as measured on the iPhone, and
  /// releases the embedder. The chat model stays loaded.
  static func action(level: MemoryPressureLevel) -> MemoryRelief {
    [.stopReplyIfExhausted, .releaseEmbedder]
  }
}
