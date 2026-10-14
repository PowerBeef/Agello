import SwiftUI

/// Lightweight syntax highlighting for code blocks: comments, strings,
/// numbers and keywords for common languages. Token rules are shared;
/// keyword sets are per language family. Pure (unit-tested via `tokens`).
enum CodeHighlighter {
  enum Kind: Equatable { case plain, keyword, string, comment, number }

  struct Token: Equatable {
    var kind: Kind
    var text: String
  }

  static func highlight(_ code: String, language: String?) -> AttributedString {
    var result = AttributedString()
    for token in tokens(code, language: language) {
      var run = AttributedString(token.text)
      if let color = color(for: token.kind) { run.foregroundColor = color }
      result += run
    }
    return result
  }

  private static func color(for kind: Kind) -> Color? {
    switch kind {
    case .plain: return nil
    case .keyword: return Color(red: 0.78, green: 0.26, blue: 0.62)
    case .string: return Color(red: 0.84, green: 0.33, blue: 0.24)
    case .comment: return .secondary
    case .number: return Color(red: 0.20, green: 0.45, blue: 0.85)
    }
  }

  static func tokens(_ code: String, language: String?) -> [Token] {
    let family = Family(language)
    let keywords = family.keywords
    let characters = Array(code)
    var tokens: [Token] = []
    var plain = ""
    var index = 0

    func flushPlain() {
      guard !plain.isEmpty else { return }
      tokens.append(Token(kind: .plain, text: plain))
      plain = ""
    }
    func emit(_ kind: Kind, upTo end: Int) {
      flushPlain()
      tokens.append(Token(kind: kind, text: String(characters[index..<end])))
      index = end
    }
    func starts(_ prefix: String, at position: Int) -> Bool {
      let p = Array(prefix)
      guard position + p.count <= characters.count else { return false }
      return Array(characters[position..<(position + p.count)]) == p
    }

    while index < characters.count {
      let character = characters[index]
      // Comments
      if family.lineComments.contains(where: { starts($0, at: index) }) {
        let end = characters[index...].firstIndex(of: "\n") ?? characters.count
        emit(.comment, upTo: end)
        continue
      }
      if family.blockComments, starts("/*", at: index) {
        var end = index + 2
        while end < characters.count, !starts("*/", at: end) { end += 1 }
        emit(.comment, upTo: min(characters.count, end + 2))
        continue
      }
      // Strings
      if family.quotes.contains(character) {
        var end = index + 1
        while end < characters.count, characters[end] != character, characters[end] != "\n" {
          if characters[end] == "\\" { end += 1 }
          end += 1
        }
        emit(.string, upTo: min(characters.count, end + 1))
        continue
      }
      // Numbers (not inside identifiers)
      if character.isNumber, index == 0 || !isIdentifier(characters[index - 1]) {
        var end = index
        while end < characters.count, characters[end].isNumber || characters[end] == "." || characters[end] == "_"
          || characters[end].isHexDigit || characters[end] == "x"
        {
          end += 1
        }
        emit(.number, upTo: end)
        continue
      }
      // Identifiers / keywords
      if isIdentifierStart(character) {
        var end = index
        while end < characters.count, isIdentifier(characters[end]) { end += 1 }
        let word = String(characters[index..<end])
        if keywords.contains(word) {
          emit(.keyword, upTo: end)
        } else {
          plain += word
          index = end
        }
        continue
      }
      plain.append(character)
      index += 1
    }
    flushPlain()
    return tokens
  }

  private static func isIdentifierStart(_ c: Character) -> Bool { c.isLetter || c == "_" || c == "$" || c == "@" }
  private static func isIdentifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }

  private struct Family {
    var keywords: Set<String>
    var lineComments: [String]
    var blockComments: Bool
    var quotes: Set<Character>

    init(_ language: String?) {
      switch (language ?? "").lowercased() {
      case "python", "py":
        keywords = Self.python
        lineComments = ["#"]
        blockComments = false
        quotes = ["\"", "'"]
      case "bash", "sh", "shell", "zsh", "console":
        keywords = Self.shell
        lineComments = ["#"]
        blockComments = false
        quotes = ["\"", "'"]
      case "ruby", "rb":
        keywords = Self.ruby
        lineComments = ["#"]
        blockComments = false
        quotes = ["\"", "'"]
      case "json":
        keywords = ["true", "false", "null"]
        lineComments = []
        blockComments = false
        quotes = ["\""]
      case "sql":
        keywords = Self.sql
        lineComments = ["--"]
        blockComments = true
        quotes = ["'", "\""]
      case "php":
        keywords = Self.cFamily.union(Self.php)
        lineComments = ["//", "#"]
        blockComments = true
        quotes = ["\"", "'"]
      default:
        keywords = Self.cFamily
        lineComments = ["//"]
        blockComments = true
        quotes = ["\"", "'", "`"]
      }
    }

    static let cFamily: Set<String> = [
      // Swift, Kotlin, Java, C/C++, C#, JS/TS, Go, Rust, Dart
      "func", "let", "var", "if", "else", "for", "while", "repeat", "return", "struct", "class",
      "enum", "protocol", "extension", "import", "guard", "switch", "case", "default", "break",
      "continue", "in", "true", "false", "nil", "null", "self", "Self", "static", "private",
      "public", "internal", "fileprivate", "async", "await", "throws", "throw", "try", "catch",
      "do", "init", "some", "any", "where", "const", "function", "new", "this", "typeof", "export",
      "from", "interface", "type", "implements", "extends", "package", "void", "int", "float",
      "double", "char", "bool", "boolean", "long", "short", "unsigned", "include", "define",
      "namespace", "using", "template", "fn", "mut", "impl", "trait", "pub", "match", "loop",
      "go", "defer", "chan", "map", "range", "undefined", "yield", "final", "override", "abstract",
      "val", "fun", "when", "object", "is", "as", "string", "String",
    ]
    static let python: Set<String> = [
      "def", "class", "if", "elif", "else", "for", "while", "return", "import", "from", "as",
      "with", "try", "except", "finally", "raise", "lambda", "yield", "in", "is", "not", "and",
      "or", "pass", "break", "continue", "True", "False", "None", "self", "async", "await",
      "global", "nonlocal", "assert", "del", "print",
    ]
    static let shell: Set<String> = [
      "if", "then", "else", "elif", "fi", "for", "do", "done", "while", "case", "esac", "in",
      "function", "return", "export", "local", "echo", "cd", "sudo",
    ]
    static let ruby: Set<String> = [
      "def", "end", "class", "module", "if", "elsif", "else", "unless", "while", "do", "return",
      "yield", "nil", "true", "false", "self", "require", "puts", "each", "begin", "rescue",
    ]
    static let sql: Set<String> = [
      "SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "INNER", "ON", "GROUP", "BY", "ORDER",
      "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "AND", "OR",
      "NOT", "NULL", "AS", "LIMIT", "select", "from", "where", "join", "on", "group", "by",
      "order", "insert", "into", "values", "update", "set", "delete", "create", "table", "and",
      "or", "not", "null", "as", "limit",
    ]
    static let php: Set<String> = ["echo", "array", "foreach", "as", "fn", "use", "namespace", "elseif"]
  }
}
