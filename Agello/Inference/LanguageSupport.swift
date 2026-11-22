import Foundation

/// Pure, zero-latency multilingual normalization and intent helpers shared by tools, web sources,
/// and structured parsers. Keeps machine-to-code parsing resilient across natural-language inputs
/// in English, French, Spanish, German, Italian, Portuguese, Dutch, Polish, Russian, Arabic,
/// Japanese, Chinese, and Korean without inflating prompts or degrading English performance.
enum LanguageSupport {
  // MARK: - Current location ("near me" / "here")

  private static let currentLocationPhrases: Set<String> = [
    // English
    "me", "here", "my location", "current location", "my current location", "nearby", "around me",
    // French
    "moi", "ici", "ma position", "ma localisation", "autour de moi", "a proximite",
    // Spanish
    "mi", "aqui", "mi ubicacion", "ubicacion actual", "cerca de mi",
    // German
    "mir", "hier", "mein standort", "meiner nahe", "in meiner nahe",
    // Italian
    "me stesso", "qui", "la mia posizione", "mia posizione", "vicino a me",
    // Portuguese
    "mim", "minha localizacao", "localizacao atual", "perto de mim",
    // Dutch
    "mij", "mijn locatie", "in de buurt",
    // Polish
    "mnie", "tutaj", "tu", "moja lokalizacja", "w poblizu",
    // Russian
    "здесь", "тут", "рядом", "рядом со мной", "мое местоположение",
    // Arabic
    "هنا", "موقعي", "بالقرب مني", "قريب مني",
    // Japanese, Chinese, Korean
    "ここ", "現在地", "近く", "私の近く",
    "这里", "這裡", "当前位置", "目前位置", "附近",
    "여기", "현재 위치", "내 위치", "근처",
  ]

  /// Whether `place` refers to the user's current physical location in any supported language.
  static func meansCurrentLocation(_ place: String) -> Bool {
    let normalized = fold(place)
      .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
    return currentLocationPhrases.contains(normalized)
  }

  // MARK: - Place query splitting ("<what> near <where>")

  /// Splits proximity place queries across major European and CJK languages into `(what, place)`.
  /// Handles both `<what> <connector> <where>` (European) and `<where><connector><what>` (JA/ZH/KO).
  static func splitPlaceQuery(_ query: String) -> (what: String, place: String?) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return (trimmed, nil) }

    // 1. European connectors (`<what> <connector> <where>`). Match on diacritic-folded text
    //    using character offsets mapped safely back to the original string.
    let folded = fold(trimmed)
    let connectors = [
      // English
      " near ", " close to ", " around ", " next to ",
      // French
      " pres de ", " pres du ", " pres des ", " pres d'", " pres d’",
      " proche de ", " proche du ", " proche des ", " proche d'",
      " a cote de ", " a cote du ", " autour de ", " autour du ",
      // Spanish
      " cerca de ", " cerca del ", " junto a ", " alrededor de ",
      // German
      " in der nahe von ", " in der nahe vom ", " in der nahe des ", " nahe ", " bei ",
      // Italian
      " vicino a ", " vicino al ", " vicino alla ", " vicino allo ", " vicino all'", " nei pressi di ",
      // Portuguese
      " perto de ", " perto do ", " perto da ", " proximo de ", " proximo a ",
      // Dutch
      " dichtbij ", " in de buurt van ", " bij ",
      // Polish
      " blisko ", " obok ", " w poblizu ",
      // Russian
      " рядом с ", " около ", " возле ", " недалеко от ",
      // Arabic
      " بالقرب من ", " قريب من ", " قرب ",
    ]
    for connector in connectors {
      if let (what, place) = splitPreservingOriginal(trimmed, folded: folded, connector: connector) {
        return (what, place)
      }
    }

    // 2. CJK reverse order (`<where><connector><what>`): e.g. "渋谷駅近くの薬局", "台北101附近的药店".
    let cjkConnectors = ["の近くの", "の近くにある", "近くの", "付近の", "周辺の", "附近的", "附近", "근처의 ", "근처 "]
    for connector in cjkConnectors {
      if let range = trimmed.range(of: connector) {
        let place = trimmed[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let what = trimmed[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !what.isEmpty, !place.isEmpty { return (what, place) }
      }
    }

    return (trimmed, nil)
  }

  private static func splitPreservingOriginal(
    _ original: String, folded: String, connector: String
  ) -> (String, String)? {
    // Compare folded substrings by scanning original indices with `.diacriticInsensitive`.
    guard
      let range = original.range(
        of: connector, options: [.caseInsensitive, .diacriticInsensitive])
    else { return nil }
    let what = original[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    let place = original[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    guard !what.isEmpty, !place.isEmpty else { return nil }
    return (what, place)
  }

  // MARK: - Store-hours & weather query noise stripping

  private static let placeHoursNoise: Set<String> = [
    // English
    "closing", "close", "closes", "opening", "open", "opens", "hours", "hour", "time", "at", "what", "does",
    // French
    "fermeture", "ferme", "ouverture", "ouvre", "horaire", "horaires", "heure", "heures", "quelle", "quel", "de", "d",
    // Spanish
    "cierre", "cierra", "apertura", "abre", "horario", "horarios", "hora", "horas", "que",
    // German
    "offnungszeiten", "schliesst", "offnet", "uhrzeit", "wann", "bis",
    // Italian
    "chiusura", "chiude", "apertura", "apre", "orari", "orario", "ora", "quando",
    // Portuguese
    "fechamento", "fecha", "abertura", "abre", "horario", "horarios", "horas",
    // Dutch / Polish
    "openingstijden", "sluit", "godziny", "otwarcia", "zamkniecia",
  ]

  /// Strips store opening/closing-hour noise words across languages to isolate a business name.
  static func stripPlaceHoursNoise(_ query: String) -> String {
    let base = stripWeatherNoise(query)
    return base.split(whereSeparator: \.isWhitespace)
      .filter { word in
        let clean = stripElisionPrefix(fold(String(word)).trimmingCharacters(in: .punctuationCharacters))
        return !clean.isEmpty && !placeHoursNoise.contains(clean)
      }
      .joined(separator: " ")
  }

  private static func stripElisionPrefix(_ word: String) -> String {
    for prefix in ["d'", "d’", "l'", "l’"] where word.hasPrefix(prefix) {
      return String(word.dropFirst(prefix.count))
    }
    return word
  }

  private static let weatherNoise: Set<String> = [
    // English
    "weather", "forecast", "temperature", "today", "tomorrow", "tonight", "this", "week", "weekend",
    "rain", "snow", "will", "it",
    // French
    "meteo", "previsions", "prevision", "temps", "temperature", "demain", "aujourd'hui", "aujourdhui",
    "ce", "soir", "semaine", "pluie", "neige",
    // Spanish
    "tiempo", "clima", "pronostico", "temperatura", "hoy", "manana", "lluvia", "nieve", "esta", "semana",
    // German
    "wetter", "vorhersage", "wettervorhersage", "temperatur", "heute", "morgen", "regen", "schnee", "woche",
    // Italian
    "meteo", "previsioni", "tempo", "oggi", "domani", "pioggia", "neve", "settimana",
    // Portuguese
    "tempo", "clima", "previsao", "hoje", "amanha", "chuva", "neve", "semana",
    // Dutch / Polish
    "weer", "weersverwachting", "vandaag", "morgen", "regen",
    "pogoda", "prognoza", "dzisiaj", "dzis", "jutro", "deszcz",
    // Russian / Arabic
    "погода", "прогноз", "сегодня", "завтра", "дождь", "снег",
    "الطقس", "توقعات", "اليوم", "غدا", "مطر",
  ]

  /// Prepositions stripped ONLY when left dangling at the start/end after removing weather words,
  /// so city names like "Rio de Janeiro", "La Paz", or "El Paso" are never corrupted.
  private static let danglingPrepositions: Set<String> = [
    "in", "for", "at", "on", "of", "a", "au", "en", "de", "du", "del", "im", "am", "fur", "di", "do", "da", "em", "w", "в", "في",
  ]

  private static let weatherCJKNoise = [
    "天気予報", "天気", "気温", "明日", "今日", "今夜", "週間", "雨", "雪", "の",
    "天气预报", "天氣預報", "天气", "天氣", "气温", "氣溫", "明天", "今天", "今晚", "下雨", "下雪", "的",
    "날씨", "일기예보", "기온", "내일", "오늘", "비", "눈",
  ]

  private static let multilingualMonths: Set<String> = {
    var set = Set<String>()
    let locales = ["en_US", "fr_FR", "es_ES", "de_DE", "it_IT", "pt_PT", "nl_NL", "pl_PL", "ru_RU"]
    for id in locales {
      var cal = Calendar(identifier: .gregorian)
      cal.locale = Locale(identifier: id)
      for month in cal.monthSymbols + cal.shortMonthSymbols + cal.standaloneMonthSymbols {
        set.insert(fold(month).trimmingCharacters(in: .punctuationCharacters))
      }
    }
    return set
  }()

  /// Strips weather/forecast/date words across languages to isolate the place name.
  /// Month names are removed only when adjacent to a numeric day/year so city names like
  /// "Rio de Janeiro" ("Janeiro" = January) or "La Paz" ("paź" = Oct) are never corrupted.
  static func stripWeatherNoise(_ query: String) -> String {
    var text = query
    for token in weatherCJKNoise where text.contains(token) {
      text = text.replacingOccurrences(of: token, with: " ")
    }
    let rawWords = text.split(whereSeparator: \.isWhitespace).map(String.init)
    var words: [String] = []
    for (idx, word) in rawWords.enumerated() {
      let plain = fold(word).trimmingCharacters(in: .punctuationCharacters)
      if plain.isEmpty || weatherNoise.contains(plain) || Int(plain) != nil { continue }
      if multilingualMonths.contains(plain) {
        let prevIsNum = idx > 0 && Int(rawWords[idx - 1].trimmingCharacters(in: .punctuationCharacters)) != nil
        let nextIsNum =
          idx + 1 < rawWords.count
          && Int(rawWords[idx + 1].trimmingCharacters(in: .punctuationCharacters)) != nil
        if prevIsNum || nextIsNum { continue }
      }
      words.append(word)
    }
    while let first = words.first,
      danglingPrepositions.contains(fold(first).trimmingCharacters(in: .punctuationCharacters))
    {
      words.removeFirst()
    }
    while let last = words.last,
      danglingPrepositions.contains(fold(last).trimmingCharacters(in: .punctuationCharacters))
    {
      words.removeLast()
    }
    return words.joined(separator: " ")
      .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
  }

  // MARK: - Transport mode normalization (MapKit)

  /// Normalizes localized transport modes into canonical `"driving"`, `"walking"`, or `"transit"`.
  static func normalizeTransportMode(_ raw: String) -> String {
    let cleaned = fold(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    let walking: Set<String> = [
      "walking", "walk", "foot", "on foot", "pedestrian",
      "marche", "a pied", "pied", "caminando", "a pie", "andar",
      "zu fuss", "gehen", "a piedi", "camminando", "a pe", "lopen", "pieszo", "пешком", "徒歩", "步行", "도보",
    ]
    let transit: Set<String> = [
      "transit", "public transit", "public transport", "subway", "metro", "bus", "train",
      "transport en commun", "transports en commun", "transporte publico", "opnv", "nahverkehr",
      "trasporto pubblico", "transporte", "openbaar vervoer", "komunikacja", "транспорт", "電車", "公共交通", "대중교통",
    ]
    if walking.contains(cleaned) { return "walking" }
    if transit.contains(cleaned) { return "transit" }
    return "driving"
  }

  // MARK: - Localized number parsing (US + European CSV/currency)

  /// Parses numbers in US (`$1,250.50`, `1,000`, `18%`) and European (`1 250,50 €`, `1.250,50`, `42,75`)
  /// formats deterministically.
  static func parseLocalizedNumber(_ raw: String) -> Double? {
    var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    let isPercent = cleaned.hasSuffix("%")
    if isPercent { cleaned.removeLast() }
    // Strip currency symbols and thin/non-breaking spaces used as thousands separators.
    cleaned = cleaned
      .replacingOccurrences(of: #"[$€£¥₹₩\s\u00A0\u202F]"#, with: "", options: .regularExpression)
    guard !cleaned.isEmpty else { return nil }

    let hasDot = cleaned.contains(".")
    let hasComma = cleaned.contains(",")
    if hasDot && hasComma {
      // Whichever separator appears last is the decimal separator (`1,250.50` vs `1.250,50`).
      if let lastDot = cleaned.lastIndex(of: "."), let lastComma = cleaned.lastIndex(of: ",") {
        if lastComma > lastDot {
          cleaned = cleaned.replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: ".")
        } else {
          cleaned = cleaned.replacingOccurrences(of: ",", with: "")
        }
      }
    } else if hasComma {
      let parts = cleaned.split(separator: ",", omittingEmptySubsequences: false)
      // Single comma with 1–2 trailing digits (or non-3-digit group) is a European decimal comma (`42,5`, `1250,75`);
      // 3-digit groups like `1,250` or `1,250,000` are US thousands separators.
      if parts.count == 2, let fractional = parts.last, fractional.count != 3 {
        cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
      } else {
        cleaned = cleaned.replacingOccurrences(of: ",", with: "")
      }
    }
    guard let value = Double(cleaned), value.isFinite else { return nil }
    return isPercent ? value / 100.0 : value
  }

  // MARK: - Multilingual comparative follow-up detection (`WebContext.replansAsQuestion`)

  /// Whether a follow-up asks for a difference/margin between two figures in any major language.
  static func isDifferenceFollowUp(_ question: String) -> Bool {
    let folded = fold(question)
    let latinPattern =
      #"\b("#
      + #"by how (much|many|far|long)|how (much|many) (more|less|fewer|longer|shorter|faster|slower|bigger|smaller|older|younger|higher|lower)|difference|margin|gap|ahead of|behind"#
      + #"|de combien|combien de (plus|moins)|ecart|avance|retard"#
      + #"|por cuantos?|por cuantas?|cuantos? (mas|menos)|diferencia|margen|ventaja"#
      + #"|um wie viele?|wie viele? (mehr|weniger)|unterschied|abstand|vorsprung"#
      + #"|di quant[oiae]|quant[oiae] (piu|meno)|differenza|distacco"#
      + #"|por quant[oa]s?|quant[oa]s? (mais|menos)|diferenca"#
      + #"|hoeveel (meer|minder)|verschil|o ile|roznica"#
      + #")\b"#
    if folded.range(of: latinPattern, options: .regularExpression) != nil { return true }
    let cjkPatterns = ["何分差", "何秒差", "どれくらい差", "差は", "差多少", "相差", "多多少", "少多少", "차이", "разница", "на сколько", "الفرق", "بكم"]
    return cjkPatterns.contains { question.contains($0) }
  }

  /// Lowercases, expands German `ß` to `ss`, and strips Latin diacritics while preserving non-Latin scripts.
  static func fold(_ text: String) -> String {
    text.lowercased()
      .replacingOccurrences(of: "ß", with: "ss")
      .folding(options: .diacriticInsensitive, locale: nil)
  }
}
