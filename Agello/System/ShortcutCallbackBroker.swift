import Foundation
import Security
import Synchronization

/// Cryptographic callback broker for outbound `shortcuts://x-callback-url/run-shortcut` launches.
///
/// Enforces four invariants:
/// 1. Every launch binds a fresh `UUID` request ID and a 256-bit CSPRNG hex `nonce` (120 s TTL).
/// 2. Incoming `agello://shortcut-result` URLs are validated with constant-time nonce comparison
///    and immediately invalidated after one match (replay and forgery proof).
/// 3. Because `onOpenURL` often fires in `.inactive` *before* `scenePhase == .active` reopens
///    `GPUGate`, verified callbacks are buffered until `flushBufferedForForeground()` confirms the
///    app is back in the foreground with `GPUGate.isOpen`.
/// 4. Returning manually without completing the Shortcut resolves cleanly via `cancelPending`.
final class ShortcutCallbackBroker: @unchecked Sendable {
  static let shared = ShortcutCallbackBroker()
  static let defaultTTLSeconds: TimeInterval = 120
  static let callbackHost = "shortcut-result"

  enum Status: String, Equatable, Sendable {
    case ok
    case error
    case cancel
    case timedOut
  }

  struct CallbackResult: Equatable, Sendable {
    let requestID: UUID
    let shortcutName: String
    let status: Status
    let output: String?
    let errorMessage: String?
  }

  enum DeliveryOutcome: Equatable, Sendable {
    case delivered(CallbackResult)
    case bufferedUntilForeground(CallbackResult)
    case rejected(reason: String)
  }

  struct PendingSummary: Equatable, Sendable {
    let requestID: UUID
    let shortcutName: String
    let startedAt: Date
  }

  private struct PendingEntry {
    let requestID: UUID
    let nonce: String
    let shortcutName: String
    let startedAt: Date
    let expiresAt: Date
    var continuation: CheckedContinuation<CallbackResult, Never>?
  }

  private struct BufferedDelivery {
    let result: CallbackResult
    var continuation: CheckedContinuation<CallbackResult, Never>?
  }

  private struct State {
    var pending: PendingEntry?
    var buffered: BufferedDelivery?
    var appInForeground: Bool = true
    var isForegroundReady: @Sendable () -> Bool = { true }
    var launcher: (@Sendable (URL) async -> Bool)?

    var canDeliverNow: Bool { appInForeground && isForegroundReady() }
  }

  private let state = Mutex(State())

  /// Thread-safe mirror of `AppState.isInForeground` so callbacks arriving on any isolation domain
  /// never call `MainActor.assumeIsolated` or re-enter `state`.
  var isAppInForeground: Bool {
    state.withLock { $0.appInForeground }
  }

  func setAppInForeground(_ inForeground: Bool) {
    state.withLock { $0.appInForeground = inForeground }
  }

  /// Resets broker state to clean foreground defaults (for unit test isolation).
  func resetForTesting() {
    cancelPending(reason: "Test reset")
    state.withLock { s in
      s.appInForeground = true
      s.isForegroundReady = { true }
      s.launcher = nil
    }
  }

  /// Configures the external readiness check (e.g. `{ GPUGate.isOpen }`), combined with
  /// `appInForeground` without re-entering `state`.
  func setForegroundReadyCheck(_ check: @escaping @Sendable () -> Bool) {
    state.withLock { $0.isForegroundReady = check }
  }

  /// Configures the platform URL launcher (wired by `AppBootstrap` / `NativeActions`, or test spy).
  func setLauncher(_ launcher: (@Sendable (URL) async -> Bool)?) {
    state.withLock { $0.launcher = launcher }
  }

  /// Whether an approved external Shortcut launch is currently awaiting its callback.
  var hasPendingCallback: Bool {
    state.withLock { $0.pending != nil || $0.buffered != nil }
  }

  var pendingSummary: PendingSummary? {
    state.withLock { s in
      guard let p = s.pending else { return nil }
      return PendingSummary(
        requestID: p.requestID, shortcutName: p.shortcutName, startedAt: p.startedAt)
    }
  }

  /// Generates 32 cryptographically random bytes encoded as 64 lowercase hex characters (256 bits).
  static func generateNonce() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status != errSecSuccess {
      for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// Constant-time string comparison over UTF-8 bytes so forged nonces cannot leak timing.
  static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
    let a = Array(lhs.utf8)
    let b = Array(rhs.utf8)
    guard a.count == b.count, !a.isEmpty else { return false }
    var diff: UInt8 = 0
    for i in 0..<a.count { diff |= a[i] ^ b[i] }
    return diff == 0
  }

  /// Strict query-value character set that percent-encodes `&`, `=`, `+`, `?`, `#`, and `%`
  /// so nested `x-success` / `x-error` / `x-cancel` URLs never split across outer query params.
  private static let strictQueryValueAllowed: CharacterSet = {
    var set = CharacterSet.alphanumerics
    set.insert(charactersIn: "-._~")
    return set
  }()

  private static func encodedQueryValue(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: strictQueryValueAllowed) ?? value
  }

  /// Builds the exact `shortcuts://x-callback-url/run-shortcut` URL with single-use `req` + `nonce`.
  static func buildLaunchURL(
    shortcutName: String, input: String?, requestID: UUID, nonce: String
  ) -> URL? {
    func callbackURL(status: String) -> String? {
      var comps = URLComponents()
      comps.scheme = AppRouter.scheme
      comps.host = callbackHost
      comps.queryItems = [
        URLQueryItem(name: "req", value: requestID.uuidString),
        URLQueryItem(name: "nonce", value: nonce),
        URLQueryItem(name: "status", value: status),
      ]
      return comps.url?.absoluteString
    }
    guard
      let successURL = callbackURL(status: "ok"),
      let errorURL = callbackURL(status: "error"),
      let cancelURL = callbackURL(status: "cancel")
    else { return nil }

    var pairs: [(String, String)] = [
      ("name", shortcutName)
    ]
    if let input, !input.isEmpty {
      pairs.append(("input", "text"))
      pairs.append(("text", input))
    }
    pairs.append(("x-source", "Agello"))
    pairs.append(("x-success", successURL))
    pairs.append(("x-error", errorURL))
    pairs.append(("x-cancel", cancelURL))

    var components = URLComponents()
    components.scheme = "shortcuts"
    components.host = "x-callback-url"
    components.path = "/run-shortcut"
    components.percentEncodedQuery = pairs.map { key, val in
      "\(encodedQueryValue(key))=\(encodedQueryValue(val))"
    }.joined(separator: "&")
    return components.url
  }

  /// Registers a pending request, launches the Shortcuts URL, and suspends until a verified
  /// callback arrives in the foreground (or the TTL expires / user cancels).
  func runShortcut(
    name: String, input: String?, ttlSeconds: TimeInterval = defaultTTLSeconds
  ) async -> CallbackResult {
    let requestID = UUID()
    let nonce = Self.generateNonce()
    let now = Date()
    guard
      let launchURL = Self.buildLaunchURL(
        shortcutName: name, input: input, requestID: requestID, nonce: nonce)
    else {
      return CallbackResult(
        requestID: requestID, shortcutName: name, status: .error, output: nil,
        errorMessage: "Could not construct Shortcuts launch URL.")
    }

    let launcher = state.withLock { $0.launcher }
    guard let launcher else {
      return CallbackResult(
        requestID: requestID, shortcutName: name, status: .error, output: nil,
        errorMessage: "Shortcuts launch is unavailable on this platform.")
    }

    // Fail-close any previous stale request before registering the new one.
    cancelPending(reason: "Superseded by a new shortcut run.")

    state.withLock { s in
      s.pending = PendingEntry(
        requestID: requestID, nonce: nonce, shortcutName: name,
        startedAt: now, expiresAt: now.addingTimeInterval(ttlSeconds), continuation: nil)
    }

    let opened = await launcher(launchURL)
    if !opened {
      state.withLock { s in
        if s.pending?.requestID == requestID { s.pending = nil }
      }
      return CallbackResult(
        requestID: requestID, shortcutName: name, status: .error, output: nil,
        errorMessage: "Could not open Apple Shortcuts. Make sure the Shortcuts app is installed.")
    }

    // Watchdog enforcing the 120 s TTL so a suspended turn can never hang forever.
    let timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(ttlSeconds))
      guard !Task.isCancelled else { return }
      self?.timeoutPending(requestID: requestID)
    }
    defer { timeoutTask.cancel() }

    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let immediate: CallbackResult? = state.withLock { s in
          if var buf = s.buffered, buf.result.requestID == requestID {
            if s.canDeliverNow {
              s.buffered = nil
              return buf.result
            }
            buf.continuation = continuation
            s.buffered = buf
            return nil
          }
          if var p = s.pending, p.requestID == requestID {
            p.continuation = continuation
            s.pending = p
            return nil
          }
          return CallbackResult(
            requestID: requestID, shortcutName: name, status: .cancel, output: nil,
            errorMessage: "Shortcut was cancelled.")
        }
        if let immediate {
          continuation.resume(returning: immediate)
        }
      }
    } onCancel: { [weak self] in
      self?.cancelPending(requestID: requestID, reason: "Cancelled by the user.")
    }
  }

  /// Verifies an incoming `agello://shortcut-result?...` URL against the active pending request.
  /// Rejects unknown IDs, expired requests, replays, and forged nonces without touching active state.
  @discardableResult
  func deliver(url: URL, now: Date = Date()) -> DeliveryOutcome {
    guard
      url.scheme?.lowercased() == AppRouter.scheme,
      url.host()?.lowercased() == Self.callbackHost,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
      return .rejected(reason: "Invalid shortcut callback URL.")
    }
    let queryMap = Dictionary(
      (components.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") },
      uniquingKeysWith: { first, _ in first })
    guard let reqRaw = queryMap["req"], let reqID = UUID(uuidString: reqRaw) else {
      return .rejected(reason: "Missing or malformed request ID.")
    }
    guard let providedNonce = queryMap["nonce"], !providedNonce.isEmpty else {
      return .rejected(reason: "Missing callback nonce.")
    }

    let statusRaw = (queryMap["status"] ?? "ok").lowercased()
    let status: Status = switch statusRaw {
    case "ok", "success": .ok
    case "cancel", "cancelled": .cancel
    default: .error
    }
    let rawOutput = queryMap["result"] ?? queryMap["output"]
    let output = rawOutput.map { String($0.prefix(8_000)) }
    let errorMsg = (queryMap["errormessage"] ?? queryMap["error"]).map { String($0.prefix(500)) }

    enum Action {
      case reject(String)
      case deliver(CallbackResult, CheckedContinuation<CallbackResult, Never>?)
      case buffer(CallbackResult)
    }

    let action: Action = state.withLock { s in
      guard let entry = s.pending else {
        return .reject("No pending shortcut request (or already consumed).")
      }
      guard entry.requestID == reqID else {
        return .reject("Callback request ID does not match active request.")
      }
      guard now <= entry.expiresAt else {
        return .reject("Shortcut callback expired past TTL.")
      }
      guard Self.constantTimeEqual(entry.nonce, providedNonce) else {
        return .reject("Invalid callback nonce.")
      }

      // Valid match: single-use invalidation immediately!
      s.pending = nil
      let result = CallbackResult(
        requestID: reqID, shortcutName: entry.shortcutName,
        status: status, output: output, errorMessage: errorMsg)
      if s.canDeliverNow, let continuation = entry.continuation {
        return .deliver(result, continuation)
      }
      s.buffered = BufferedDelivery(result: result, continuation: entry.continuation)
      return .buffer(result)
    }

    switch action {
    case .reject(let reason):
      return .rejected(reason: reason)
    case .deliver(let result, let continuation):
      continuation?.resume(returning: result)
      return .delivered(result)
    case .buffer(let result):
      return .bufferedUntilForeground(result)
    }
  }

  /// Flushes any verified callback buffered while the app was still `.inactive` once `AppState`
  /// enters the foreground and reopens `GPUGate`.
  func flushBufferedForForeground() {
    let toResume: (CallbackResult, CheckedContinuation<CallbackResult, Never>?)? = state.withLock { s in
      guard s.canDeliverNow, let buf = s.buffered else { return nil }
      s.buffered = nil
      return (buf.result, buf.continuation)
    }
    if let (result, continuation) = toResume {
      continuation?.resume(returning: result)
    }
  }

  /// Cancels the pending shortcut (user tapped "Continue without result" or stopped the reply).
  func cancelPending(requestID: UUID? = nil, reason: String) {
    let toResume: (CallbackResult, CheckedContinuation<CallbackResult, Never>?)? = state.withLock { s in
      if let p = s.pending, requestID == nil || p.requestID == requestID {
        s.pending = nil
        let res = CallbackResult(
          requestID: p.requestID, shortcutName: p.shortcutName,
          status: .cancel, output: nil, errorMessage: reason)
        return (res, p.continuation)
      }
      if let b = s.buffered, requestID == nil || b.result.requestID == requestID {
        s.buffered = nil
        let res = CallbackResult(
          requestID: b.result.requestID, shortcutName: b.result.shortcutName,
          status: .cancel, output: nil, errorMessage: reason)
        return (res, b.continuation)
      }
      return nil
    }
    if let (result, continuation) = toResume {
      continuation?.resume(returning: result)
    }
  }

  /// Helper for tests verifying pending registration without launching external URLs.
  func registerTestPending(
    requestID: UUID = UUID(), nonce: String = ShortcutCallbackBroker.generateNonce(),
    shortcutName: String, ttlSeconds: TimeInterval = defaultTTLSeconds, now: Date = Date()
  ) -> (requestID: UUID, nonce: String) {
    state.withLock { s in
      s.pending = PendingEntry(
        requestID: requestID, nonce: nonce, shortcutName: shortcutName,
        startedAt: now, expiresAt: now.addingTimeInterval(ttlSeconds), continuation: nil)
      s.buffered = nil
    }
    return (requestID, nonce)
  }

  private func timeoutPending(requestID: UUID) {
    let toResume: (CallbackResult, CheckedContinuation<CallbackResult, Never>?)? = state.withLock { s in
      if let p = s.pending, p.requestID == requestID {
        s.pending = nil
        let res = CallbackResult(
          requestID: p.requestID, shortcutName: p.shortcutName,
          status: .timedOut, output: nil,
          errorMessage: "Shortcut timed out without returning a result.")
        return (res, p.continuation)
      }
      if let b = s.buffered, b.result.requestID == requestID {
        s.buffered = nil
        let res = CallbackResult(
          requestID: b.result.requestID, shortcutName: b.result.shortcutName,
          status: .timedOut, output: nil,
          errorMessage: "Shortcut timed out before returning to the foreground.")
        return (res, b.continuation)
      }
      return nil
    }
    if let (result, continuation) = toResume {
      continuation?.resume(returning: result)
    }
  }
}
