import Foundation

/// Text handling for voice mode. Pure (unit-tested).
enum VoiceText {
  static let openMark = "⟦"
  static let closeMark = "⟧"

  /// Added to the system prompt while voice mode is on. Measured on device:
  /// Gemma follows it reliably and the first answer sentence is ready
  /// ~0.7–1.0 s after the user stops talking.
  static let instruction =
    "The user is talking to you by voice. Start every reply with exactly what the user said, "
    + "transcribed in their language between \(openMark) and \(closeMark), then answer in their "
    + "language in one to three short, natural spoken sentences. No markdown, lists, links, or "
    + "emoji. When an image is attached, it shows what the user's camera sees right now."

  /// Splits a (possibly partial) reply into the user's transcript and the
  /// answer. `heard` is nil until the transcript is complete.
  static func split(_ reply: String) -> (heard: String?, answer: String) {
    let trimmed = reply.drop { $0.isWhitespace }
    guard trimmed.hasPrefix(openMark) else { return (nil, reply) }
    guard let close = trimmed.range(of: closeMark) else { return (nil, "") }
    let heard = trimmed[trimmed.index(after: trimmed.startIndex)..<close.lowerBound]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let answer = trimmed[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    return (heard, answer)
  }

  /// Text as it should be spoken: no markdown, citations, links, or emoji.
  static func speakable(_ text: String) -> String {
    var spoken = text
    spoken = spoken.replacingOccurrences(
      of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)  // links
    spoken = spoken.replacingOccurrences(of: #"\[\d{1,2}\]"#, with: "", options: .regularExpression)
    spoken = spoken.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
    spoken = spoken.replacingOccurrences(of: #"[*_#`~>|]"#, with: "", options: .regularExpression)
    spoken = String(spoken.unicodeScalars.filter { !$0.properties.isEmojiPresentation }.map(Character.init))
    spoken = spoken.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
      .joined(separator: " ")
    return spoken.replacingOccurrences(of: #" ([.,!?;:])"#, with: "$1", options: .regularExpression)
  }

  /// Sentence ends: Latin, CJK full-width, Devanagari danda, Arabic and Urdu.
  static let sentenceEnds: Set<Character> = [
    ".", "!", "?", "…", "\n", "。", "！", "？", "।", "॥", "؟", "۔",
  ]
  /// Ends that need no following space.
  static let closesWithoutSpace: Set<Character> = ["。", "！", "？", "\n"]

  /// The installed voice language for a language the recognizer named ("zh-Hans", "fr", "nb"):
  /// voices are named by region ("zh-CN", "fr-CA", "nb-NO"). The user's own region first, then
  /// the first voice in that language; nil when none is installed.
  static func voiceLanguage(
    for language: String, available: [String], preferred: [String] = Locale.preferredLanguages
  ) -> String? {
    let scripts = ["zh-Hans": ["zh-CN"], "zh-Hant": ["zh-TW", "zh-HK"]]
    if let regional = scripts[language] {
      return regional.first(where: available.contains)
        ?? available.first { $0.hasPrefix("zh") }
    }
    if available.contains(language) { return language }
    let base = String(language.prefix { $0 != "-" && $0 != "_" })
    func sameLanguage(_ code: String) -> Bool {
      code == base || code.hasPrefix(base + "-") || code.hasPrefix(base + "_")
    }
    if let own = preferred.first(where: { sameLanguage($0) && available.contains($0) }) { return own }
    return available.first(where: sameLanguage)
  }

  /// Feeds a growing answer and hands out complete sentences to speak as
  /// soon as they're done (the rest when the reply ends).
  struct SentenceStream: Equatable {
    /// Characters of the answer already handed out.
    private(set) var spokenCount = 0

    /// Complete sentences added since the last call.
    mutating func next(from answer: String, final: Bool = false) -> [String] {
      guard answer.count > spokenCount else { return [] }
      let pending = String(answer.dropFirst(spokenCount))
      var sentences: [String] = []
      var consumed = 0
      var current = ""
      let characters = Array(pending)
      for (index, character) in characters.enumerated() {
        current.append(character)
        let isEnd = sentenceEnds.contains(character)
        let nextIsBreak = index + 1 >= characters.count ? final : characters[index + 1].isWhitespace
        // "3.5" or "e.g." mid-word isn't an end; wait for the following space. Chinese and
        // Japanese write no space after a full stop.
        if isEnd, nextIsBreak || closesWithoutSpace.contains(character),
          current.trimmingCharacters(in: .whitespaces).count > 1
        {
          let sentence = speakable(current)
          if !sentence.isEmpty { sentences.append(sentence) }
          consumed = index + 1
          current = ""
        }
      }
      if final, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let sentence = speakable(current)
        if !sentence.isEmpty { sentences.append(sentence) }
        consumed = characters.count
      }
      spokenCount += consumed
      return sentences
    }
  }
}

/// Turn-taking from microphone levels: speech starts when the level stays
/// above the noise floor for a moment, and ends after a stretch of silence.
/// Pure (unit-tested with synthetic levels).
struct VoiceActivityDetector: Equatable {
  enum Event: Equatable { case speechStarted, speechEnded }

  /// Level above the noise floor that counts as speech.
  var margin: Float = 14
  /// Speech must last this long to start an utterance.
  var startAfter: TimeInterval = 0.2
  /// Silence this long ends the utterance.
  var endAfter: TimeInterval = 0.8
  /// Utterances shorter than this are ignored (coughs, clicks).
  var minimumSpeech: TimeInterval = 0.35
  /// Extra margin while the assistant speaks (echo leaks past cancellation).
  var bargeInMargin: Float = 10

  /// The room's noise level is measured for this long before listening.
  var calibration: TimeInterval = 0.5

  private(set) var noiseFloor: Float = -60
  private(set) var speaking = false
  private var calibrated: TimeInterval = 0
  private var above: TimeInterval = 0
  private var below: TimeInterval = 0
  private var speechLength: TimeInterval = 0

  /// Feed one level (dBFS) measured over `duration` seconds.
  mutating func feed(level: Float, duration: TimeInterval, assistantSpeaking: Bool = false)
    -> Event?
  {
    if calibrated < calibration {
      // Average the room's level before listening.
      let weight = Float(duration / max(calibration, duration))
      noiseFloor = calibrated == 0 ? level : noiseFloor + (level - noiseFloor) * min(1, weight * 2)
      calibrated += duration
      return nil
    }
    let threshold = noiseFloor + margin + (assistantSpeaking ? bargeInMargin : 0)
    let loud = level > threshold
    if !speaking {
      // Follow the room's noise (not the assistant's echo): quickly down,
      // slowly up, so steady noise never counts as speech.
      if !assistantSpeaking {
        noiseFloor = level < noiseFloor ? level : noiseFloor + (level - noiseFloor) * 0.02
        noiseFloor = max(noiseFloor, -80)
      }
      above = loud ? above + duration : 0
      if above >= startAfter {
        speaking = true
        speechLength = above
        below = 0
        return .speechStarted
      }
      return nil
    }
    speechLength += duration
    below = loud ? 0 : below + duration
    if below >= endAfter {
      speaking = false
      above = 0
      let spoken = speechLength - below
      below = 0
      return spoken >= minimumSpeech ? .speechEnded : nil
    }
    return nil
  }

  /// Back to waiting for speech (e.g. after a barge-in was handled).
  mutating func reset() {
    speaking = false
    above = 0
    below = 0
    speechLength = 0
  }
}
