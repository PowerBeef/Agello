import Foundation

/// Heap-allocated, `NSLock`-backed container for mutable state shared across isolation domains.
///
/// Replaces `static let … = Mutex(…)` in Swift 6, where `-O` static value-addressing codegen
/// corrupted reference-counted payloads in Release builds (`ExperimentalFlags`, `BatchConfirmStore`).
final class LockedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ initialValue: Value) {
    self.value = initialValue
  }

  @discardableResult
  func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
    lock.lock()
    defer { lock.unlock() }
    return try body(&value)
  }
}
