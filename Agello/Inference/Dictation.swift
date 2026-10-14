import Foundation

/// Speech to text with Gemma's own audio input. Pure parts (unit-tested).
enum Dictation {
  static let instruction =
    "Transcribe this audio recording exactly as spoken, in its original language. "
    + "Output only the transcript, with normal punctuation and capitalization. "
    + "If there is no speech, output nothing."
  /// ~30 s of speech is about 90 words.
  static let maxOutputTokens = 256

  /// The transcript without labels, wrapping quotes, or stray whitespace.
  static func clean(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    for label in ["Transcript:", "Transcription:", "Transcription :"] where text.hasPrefix(label) {
      text = String(text.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
    }
    let quotes = CharacterSet(charactersIn: "\"“”«»")
    if let first = text.unicodeScalars.first, let last = text.unicodeScalars.last,
      quotes.contains(first), quotes.contains(last), text.count > 1
    {
      text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }
    return text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  /// `text` appended to `draft` with a separating space.
  static func insert(_ text: String, into draft: String) -> String {
    guard !text.isEmpty else { return draft }
    let trimmed = draft.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? text : trimmed + " " + text
  }

  /// Word error rate of `hypothesis` against `reference` (case, accents and
  /// punctuation ignored): edits needed / reference words.
  static func wordErrorRate(reference: String, hypothesis: String) -> Double {
    func words(_ text: String) -> [String] {
      text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    }
    let ref = words(reference)
    let hyp = words(hypothesis)
    guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
    var previous = Array(0...hyp.count)
    for (i, r) in ref.enumerated() {
      var current = [i + 1] + Array(repeating: 0, count: hyp.count)
      for (j, h) in hyp.enumerated() {
        current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (r == h ? 0 : 1))
      }
      previous = current
    }
    return Double(previous[hyp.count]) / Double(ref.count)
  }
}
