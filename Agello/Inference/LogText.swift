import Foundation

/// What a log line may say about an error: its kind, never its text. Logs at error level are kept
/// on the device and travel with a sysdiagnose, and an error's text can hold the conversation:
/// LiteRT-LM's `.conversation(.invalidResponse(…))` carries the model's whole response, which
/// for a helper is a title, a memory or a summary of what the user wrote (2026-11-16).
enum LogText {
  /// `ChatError.contextFull`, `LiteRTLMError.conversation`, `NSURLErrorDomain -1001`.
  static func errorKind(_ error: any Error) -> String {
    let typeName = String(describing: type(of: error))
    if error is ChatError || !(typeName == "NSError" || typeName.hasPrefix("__")) {
      // An enum case without its associated values; a struct's name alone.
      let description = String(describing: error)
      let caseName = description.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
      return caseName.isEmpty || caseName == typeName ? typeName : "\(typeName).\(caseName)"
    }
    let nsError = error as NSError
    return "\(nsError.domain) \(nsError.code)"
  }
}
