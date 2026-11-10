/// The iPhone's haptics and VoiceOver announcements have nothing to do in a command line: these
/// are no-ops, so shared code calls them the same way.
@MainActor
enum Haptics {
  static func send() {}
  static func complete() {}
  static func selection() {}
  static func success() {}
  static func warning() {}
  static func error() {}
  static func replyFinished(spoken: Bool) {}
  static func announce(_ text: String) {}
}
