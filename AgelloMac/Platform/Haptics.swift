/// The iPhone's haptics have no Mac counterpart outside a trackpad gesture: these are no-ops,
/// so shared code calls them the same way.
@MainActor
enum Haptics {
  static func send() {}
  static func complete() {}
  static func selection() {}
  static func success() {}
  static func warning() {}
  static func error() {}
}
