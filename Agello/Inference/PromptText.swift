import Foundation

/// Text from outside the app's own prompts can't open or close a chat turn: files, web pages,
/// tool results, shared items, memories, the user's messages and the model's earlier replies all
/// reach the model as plain text. Gemma 4's control tokens (`<|turn>`, `<turn|>`,
/// `<|tool_response>`, `<|channel>`, `<|"|>`, `<|think|>`…) all start with `<|` or end with `|>`;
/// a zero-width joiner between those two characters keeps the tokenizer from reading them as a
/// control token (probe 19), and the text reads the same. Applied at the engine boundary.
enum PromptText {
  static let joiner: Unicode.Scalar = "\u{200D}"

  /// The control tokens of Gemma 4 E4B's chat template (each is checked by the tests and probe 19).
  static let controlTokens = [
    "<|turn>", "<turn|>", "<|tool>", "<tool|>", "<|tool_call>", "<tool_call|>",
    "<|tool_response>", "<tool_response|>", "<|channel>", "<channel|>", "<|\"|>", "<|think|>",
    "<|image>", "<image|>", "<|image|>", "<|audio>", "<audio|>", "<|audio|>",
  ]

  /// `text` with a joiner inside every `<|` and `|>`. Idempotent.
  static func neutralized(_ text: String) -> String {
    guard text.utf8.contains(UInt8(ascii: "|")) else { return text }
    var scalars = String.UnicodeScalarView()
    var previous: Unicode.Scalar?
    for scalar in text.unicodeScalars {
      if (previous == "<" && scalar == "|") || (previous == "|" && scalar == ">") {
        scalars.append(joiner)
      }
      scalars.append(scalar)
      previous = scalar
    }
    return String(scalars)
  }
}
