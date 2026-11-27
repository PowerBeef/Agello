import Foundation

/// Text from outside the app's own prompts can't open or close a chat turn: files, web pages,
/// tool results, shared items, memories, the user's messages and the model's earlier replies all
/// reach the model as plain text. Gemma 4's control tokens (`<|turn>`, `<turn|>`,
/// `<|tool_response>`, `<|channel>`, `<|"|>`, `<|think|>`…) all start with `<|` or end with `|>`;
/// a zero-width joiner between those two characters keeps the tokenizer from reading them as a
/// control token (probe 19), and the text reads the same. Applied at the engine boundary.
enum PromptText {
  static let joiner: Unicode.Scalar = "\u{200D}"

  /// The control tokens of Gemma 4 E4B's chat template (each is checked by the tests and probe 19),
  /// plus legacy multimodal delimiters still matched by `Gemma4DataProcessor`.
  static let controlTokens = [
    "<|turn>", "<turn|>", "<|tool>", "<tool|>", "<|tool_call>", "<tool_call|>",
    "<|tool_response>", "<tool_response|>", "<|channel>", "<channel|>", "<|\"|>", "<|think|>",
    "<|image>", "<image|>", "<|image|>", "<|audio>", "<audio|>", "<|audio|>",
    "<start_of_image>", "<start_of_audio>",
  ]

  /// Legacy multimodal delimiters neutralized with a joiner after `<`.
  static let legacyMultimodalTokens = ["<start_of_image>", "<start_of_audio>"]

  /// A date as the model's prompts give it, in English whatever the device's language: in a
  /// French iPhone's locale, "mardi 17 novembre 2026" went into English prompts and came back
  /// in English replies (probe 34, 2026-11-17). The model writes it in the reply's language itself.
  static func date(_ date: Date, timeZone: TimeZone = .current) -> String {
    var style = Date.FormatStyle(date: .complete, time: .omitted).locale(Locale(identifier: "en_US_POSIX"))
    style.timeZone = timeZone
    return date.formatted(style)
  }

  /// A date and time as the model's tools give them, in English (see ``date(_:timeZone:)``).
  static func dateTime(_ date: Date, timeZone: TimeZone = .current) -> String {
    var style = Date.FormatStyle(date: .complete, time: .shortened).locale(Locale(identifier: "en_US_POSIX"))
    style.timeZone = timeZone
    return date.formatted(style)
  }

  /// `text` with a joiner inside every `<|` and `|>` and after `<` in legacy multimodal
  /// delimiters (`<start_of_image>`, `<start_of_audio>`). Idempotent.
  static func neutralized(_ text: String) -> String {
    let utf8 = text.utf8
    let hasPipe = utf8.contains(UInt8(ascii: "|"))
    let hasLessThan = utf8.contains(UInt8(ascii: "<"))
    guard hasPipe || hasLessThan else { return text }

    let hasLegacyMultimodal =
      hasLessThan
      && (text.range(of: "<start_of_image>", options: .literal) != nil
        || text.range(of: "<start_of_audio>", options: .literal) != nil)
    guard hasPipe || hasLegacyMultimodal else { return text }

    var result = text
    if hasPipe {
      var scalars = String.UnicodeScalarView()
      var previous: Unicode.Scalar?
      for scalar in result.unicodeScalars {
        if (previous == "<" && scalar == "|") || (previous == "|" && scalar == ">") {
          scalars.append(joiner)
        }
        scalars.append(scalar)
        previous = scalar
      }
      result = String(scalars)
    }
    if hasLegacyMultimodal {
      result = result
        .replacingOccurrences(
          of: "<start_of_image>", with: "<\(joiner)start_of_image>", options: .literal)
        .replacingOccurrences(
          of: "<start_of_audio>", with: "<\(joiner)start_of_audio>", options: .literal)
    }
    return result
  }
}
