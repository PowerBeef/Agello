/// How low memory is, as the system says it: iOS's memory warning, or a level of the Mac's
/// memory pressure.
enum MemoryPressureLevel: String, Sendable {
  case warning
  case critical
}

/// What the app gives back when memory runs low.
struct MemoryRelief: OptionSet, Sendable {
  let rawValue: Int

  /// Stop a running reply if available memory is nearly gone
  /// (``DeviceProfile/shouldStopForMemory(availableBytes:)``), keeping its text.
  static let stopReplyIfExhausted = MemoryRelief(rawValue: 1 << 0)
  /// Unload EmbeddingGemma unless it's indexing; it reloads on its next use.
  static let releaseEmbedder = MemoryRelief(rawValue: 1 << 1)
  /// Unload E4B; the next message reloads it from the engine cache (about 1.2 s on the Mac).
  static let unloadChatModel = MemoryRelief(rawValue: 1 << 2)
}

enum MemoryPolicy {
  /// A warning (iOS sends nothing stronger) stops a reply only when memory is nearly gone, as
  /// measured on the iPhone, and releases the embedder. Critical pressure, which only the Mac
  /// reports, also unloads E4B when nothing is using it.
  static func action(level: MemoryPressureLevel, isBusy: Bool) -> MemoryRelief {
    var relief: MemoryRelief = [.stopReplyIfExhausted, .releaseEmbedder]
    if level == .critical, !isBusy { relief.insert(.unloadChatModel) }
    return relief
  }
}
