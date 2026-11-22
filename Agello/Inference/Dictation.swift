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

  /// Which on-device engine handles composer dictation for the current locale.
  enum SpeechBackend: Equatable, Sendable {
    case speechTranscriber(localeIdentifier: String)
    case dictationTranscriber(localeIdentifier: String)
    case gemmaAudio
  }

  /// Picks the fastest already-installed on-device ANE speech engine for the user's primary
  /// language, or `.gemmaAudio` when no matching Apple Speech asset is installed (never silently
  /// switches to a different language).
  static func selectBackend(
    preferredLanguages: [String],
    installedSpeechTranscriber: [String],
    installedDictationTranscriber: [String]
  ) -> SpeechBackend {
    guard let primary = preferredLanguages.first, !primary.isEmpty else { return .gemmaAudio }
    if let match = matchingLocale(for: primary, in: installedSpeechTranscriber) {
      return .speechTranscriber(localeIdentifier: match)
    }
    if let match = matchingLocale(for: primary, in: installedDictationTranscriber) {
      return .dictationTranscriber(localeIdentifier: match)
    }
    return .gemmaAudio
  }

  /// Exact BCP-47 match first (`fr-CA` == `fr_CA`), then same base language (`fr`).
  static func matchingLocale(for preferred: String, in installed: [String]) -> String? {
    func normalize(_ id: String) -> String {
      id.replacingOccurrences(of: "_", with: "-").lowercased()
    }
    func baseLanguage(_ id: String) -> String {
      String(normalize(id).prefix { $0 != "-" })
    }
    let wanted = normalize(preferred)
    if let exact = installed.first(where: { normalize($0) == wanted }) {
      return exact
    }
    let base = baseLanguage(preferred)
    guard !base.isEmpty else { return nil }
    return installed.first { baseLanguage($0) == base }
  }

  /// Accumulates live streaming dictation updates (finalized phrases + volatile partial words)
  /// on top of any text the user had already typed in the composer.
  struct LiveTranscript: Equatable, Sendable {
    let base: String
    private(set) var finalized = ""
    private(set) var volatile = ""

    init(base: String = "") {
      self.base = base
    }

    /// Combined spoken text from this dictation session (finalized + current volatile tail).
    var spokenText: String {
      Self.join(finalized, volatile)
    }

    /// Full composer draft combining the pre-existing `base` with `spokenText`.
    var composedDraft: String {
      Dictation.insert(spokenText, into: base)
    }

    mutating func apply(text: String, isFinal: Bool) {
      let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if isFinal {
        if !cleaned.isEmpty {
          finalized = Self.join(finalized, cleaned)
        }
        volatile = ""
      } else {
        volatile = cleaned
      }
    }

    /// Commits any unfinalized volatile tail when dictation stops early and returns the final draft.
    @discardableResult
    mutating func commitVolatile() -> String {
      if !volatile.isEmpty {
        finalized = Self.join(finalized, volatile)
        volatile = ""
      }
      return composedDraft
    }

    private static func join(_ lhs: String, _ rhs: String) -> String {
      let left = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
      let right = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !left.isEmpty else { return right }
      guard !right.isEmpty else { return left }
      let tightLeading: Set<Character> = [",", ".", "!", "?", ";", ":", "…", ")", "]", "。", "！", "？", "、"]
      if let first = right.first, tightLeading.contains(first) {
        return left + right
      }
      return left + " " + right
    }
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
