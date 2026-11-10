import Foundation

/// The command line's arguments: `--name`, `--name value`, `--name=value`, and what's left.
struct Arguments {
  private var items: [String]
  /// Options that take no value; every other `--name` takes the next argument.
  private static let flags: Set<String> = [
    "mock", "search", "no-think", "no-tools", "no-mtp", "helpers", "json", "show-thought", "help",
    "verbose", "warmup", "no-helpers",
  ]

  init(_ items: [String]) { self.items = items }

  /// Removes and returns the first argument that isn't an option.
  mutating func next() -> String? {
    var index = 0
    while index < items.count {
      let item = items[index]
      guard item.hasPrefix("--") else { return items.remove(at: index) }
      let name = String(item.dropFirst(2))
      index += name.contains("=") || Self.flags.contains(name) || name == "think" ? 1 : 2
    }
    return nil
  }

  /// Whether `--name` was given (removing it).
  mutating func flag(_ name: String) -> Bool {
    guard let index = items.firstIndex(of: "--\(name)") else { return false }
    items.remove(at: index)
    return true
  }

  /// The value of `--name value` or `--name=value` (removing both).
  mutating func value(_ name: String) -> String? {
    if let index = items.firstIndex(where: { $0.hasPrefix("--\(name)=") }) {
      return String(items.remove(at: index).dropFirst(name.count + 3))
    }
    guard let index = items.firstIndex(of: "--\(name)"), index + 1 < items.count else { return nil }
    items.remove(at: index)
    return items.remove(at: index)
  }

  /// The value of `--name` without removing it.
  func peek(_ name: String) -> String? {
    var copy = self
    return copy.value(name)
  }

  /// Puts `--name value` back for a later reader.
  mutating func restore(_ name: String, _ value: String) {
    items += ["--\(name)", value]
  }

  /// Every value of an option that can be given more than once.
  mutating func values(_ name: String) -> [String] {
    var found: [String] = []
    while let value = value(name) { found.append(value) }
    return found
  }

  /// `--think` or `--think=N`: whether it was given, and the budget if any.
  mutating func think() -> (given: Bool, budget: Int?) {
    if let index = items.firstIndex(where: { $0.hasPrefix("--think=") }) {
      return (true, Int(items.remove(at: index).dropFirst(8)))
    }
    return (flag("think"), nil)
  }

  /// What nothing claimed.
  var rest: [String] { items }
}

/// An option the command couldn't read.
struct UsageError: Error {
  let message: String
  init(_ message: String) { self.message = message }
}

/// Where the command's own notes go: the terminal's stderr, kept when the runtime's log lines
/// are sent to a file (``Console/quietRuntime(logPath:)``).
enum Console {
  private static let notes = FileHandle(fileDescriptor: dup(STDERR_FILENO))

  static func write(_ text: String) {
    notes.write(Data(text.utf8))
  }

  /// LiteRT-LM writes a few hundred lines to stderr at every load. They go to `logPath`
  /// (appended) unless the user asked to see them.
  static func quietRuntime(logPath: String) {
    _ = notes
    let folder = (logPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    freopen(logPath, "a", stderr)
  }
}

/// Prints a note or an error: never on stdout, where the reply goes.
func note(_ text: String) {
  Console.write(text + "\n")
}

/// `value` as sorted, indented JSON.
func jsonText(_ value: Any) -> String {
  guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
    let text = String(data: data, encoding: .utf8)
  else { return "{}" }
  return text
}
