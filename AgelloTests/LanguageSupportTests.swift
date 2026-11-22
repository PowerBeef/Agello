import XCTest

@testable import Agello

/// Unit tests verifying language-agnostic parsing and tool normalization across major languages
/// while keeping English canonical forms exact.
final class LanguageSupportTests: XCTestCase {
  func testCurrentLocationRecognitionAcrossLanguages() {
    for phrase in [
      "me", "here", "my location", "moi", "ici", "ma position", "aquí", "aqui", "mi ubicación",
      "hier", "mein Standort", "qui", "mia posizione", "minha localização", "mijn locatie",
      "tutaj", "здесь", "هنا", "ここ", "現在地", "这里", "這裡", "여기", "현재 위치",
    ] {
      XCTAssertTrue(CurrentLocation.meansHere(phrase), "Should recognize '\(phrase)' as here")
    }
    for place in ["Montreal", "Place des Arts", "Paris", "Tokyo", "Berlin"] {
      XCTAssertFalse(CurrentLocation.meansHere(place), "Should NOT treat '\(place)' as here")
    }
  }

  func testSplitPlaceQueryAcrossEuropeanAndCJKLanguages() {
    let cases: [(query: String, what: String, place: String)] = [
      ("pharmacy near Place des Arts, Montreal", "pharmacy", "Place des Arts, Montreal"),
      ("pharmacie près de Place des Arts Montréal", "pharmacie", "Place des Arts Montréal"),
      ("café proche du Vieux-Port", "café", "Vieux-Port"),
      ("farmacia cerca de la Sagrada Familia", "farmacia", "la Sagrada Familia"),
      ("Apotheke in der Nähe vom Alexanderplatz", "Apotheke", "Alexanderplatz"),
      ("farmacia vicino al Colosseo", "farmacia", "Colosseo"),
      ("farmácia perto da Avenida Paulista", "farmácia", "Avenida Paulista"),
      ("apotheek bij Centraal Station", "apotheek", "Centraal Station"),
      ("apteka blisko Rynku", "apteka", "Rynku"),
      ("аптека рядом с Красной площадью", "аптека", "Красной площадью"),
      ("渋谷駅近くの薬局", "薬局", "渋谷駅"),
      ("台北101附近的咖啡店", "咖啡店", "台北101"),
      ("강남역 근처 약국", "약국", "강남역"),
    ]
    for item in cases {
      let split = PlaceSearch.split(item.query)
      XCTAssertEqual(split.what, item.what, "what mismatch for '\(item.query)'")
      XCTAssertEqual(split.place, item.place, "place mismatch for '\(item.query)'")
    }
    XCTAssertNil(PlaceSearch.split("Pharmaprix Montreal").place)
  }

  func testWeatherAndStoreHoursNoiseStrippingAcrossLanguages() {
    XCTAssertEqual(WeatherLookup.placeName(in: "Montreal weather forecast November 13 2026"), "Montreal")
    XCTAssertEqual(WeatherLookup.placeName(in: "météo Montréal demain 23 novembre"), "Montréal")
    XCTAssertEqual(WeatherLookup.placeName(in: "Wetter Berlin morgen"), "Berlin")
    XCTAssertEqual(WeatherLookup.placeName(in: "pronóstico del tiempo Madrid mañana"), "Madrid")
    XCTAssertEqual(WeatherLookup.placeName(in: "météo Rio de Janeiro demain"), "Rio de Janeiro")
    XCTAssertEqual(WeatherLookup.placeName(in: "La Paz weather tomorrow"), "La Paz")
    XCTAssertEqual(WeatherLookup.placeName(in: "東京の明日の天気予報"), "東京")
    XCTAssertEqual(WeatherLookup.placeName(in: "서울 내일 날씨"), "서울")

    XCTAssertEqual(LanguageSupport.stripPlaceHoursNoise("Walmart closing time November 22 2026"), "Walmart")
    XCTAssertEqual(LanguageSupport.stripPlaceHoursNoise("heures d'ouverture Walmart demain"), "Walmart")
    XCTAssertEqual(LanguageSupport.stripPlaceHoursNoise("Öffnungszeiten Aldi heute"), "Aldi")
  }

  func testLocalizedNumberParsingUSAndEuropean() throws {
    // US & English formats
    XCTAssertEqual(LanguageSupport.parseLocalizedNumber("$1,250.50"), 1250.5)
    XCTAssertEqual(LanguageSupport.parseLocalizedNumber("1,250,000"), 1_250_000)
    XCTAssertEqual(LanguageSupport.parseLocalizedNumber("18%"), 0.18)
    // European decimal comma & non-breaking space thousands
    XCTAssertEqual(LanguageSupport.parseLocalizedNumber("42,75"), 42.75)
    XCTAssertEqual(LanguageSupport.parseLocalizedNumber("1 250,50 €"), 1250.5)
    XCTAssertEqual(LanguageSupport.parseLocalizedNumber("1\u{202F}250,50 €"), 1250.5)
    XCTAssertEqual(LanguageSupport.parseLocalizedNumber("1.250,50"), 1250.5)

    // European semicolon CSV with decimal commas works directly in StructuredDataQuery
    let euroCSV = "ville;montant\nMontréal;1 250,50 €\nQuébec;749,50 €\n"
    let sum = try StructuredDataQuery.execute(
      raw: euroCSV, request: .init(operation: "sum", column: "montant"))
    XCTAssertTrue(sum.summary.contains("sum=2000"), sum.summary)
  }

  func testExchangeRatesMultilingualAndSymbols() {
    let known: Set<String> = ["EUR", "USD", "CAD", "GBP", "JPY", "CHF", "CNY", "KRW", "INR"]
    XCTAssertEqual(
      ExchangeRates.request("100,50 € en dollars canadiens", known: known),
      ExchangeRates.Request(amount: 100.5, from: "EUR", to: ["CAD"]))
    XCTAssertEqual(
      ExchangeRates.request("$100 CAD to EUR", known: known),
      ExchangeRates.Request(amount: 100, from: "CAD", to: ["EUR"]))
    XCTAssertEqual(
      ExchangeRates.request("250 £ en euros", known: known),
      ExchangeRates.Request(amount: 250, from: "GBP", to: ["EUR"]))
    XCTAssertEqual(
      ExchangeRates.request("1000円をドルに", known: known),
      ExchangeRates.Request(amount: 1000, from: "JPY", to: ["USD"]))
    XCTAssertEqual(
      ExchangeRates.request("50 livres sterling en francs suisses", known: known),
      ExchangeRates.Request(amount: 50, from: "GBP", to: ["CHF"]))
  }

  func testUnitConverterMultilingualAliases() throws {
    let km = try UnitConverter.convert(value: 10, from: "kilomètres", to: "milles")
    XCTAssertEqual(km.outputValue, 6.213711922, accuracy: 1e-4)

    let temp = try UnitConverter.convert(value: 350, from: "degrés Fahrenheit", to: "Celsius")
    XCTAssertEqual(temp.outputValue, 176.6666667, accuracy: 1e-3)

    let mass = try UnitConverter.convert(value: 10, from: "Pfund", to: "Kilogramm")
    XCTAssertEqual(mass.outputValue, 4.5359237, accuracy: 1e-4)

    let speed = try UnitConverter.convert(value: 100, from: "kilómetros por hora", to: "millas por hora")
    XCTAssertEqual(speed.outputValue, 62.13711922, accuracy: 1e-3)

    let bytes = try UnitConverter.convert(value: 512, from: "Mo", to: "Go")
    XCTAssertEqual(bytes.outputValue, 0.512, accuracy: 1e-6)
  }

  func testTransportModeNormalizationAndDifferenceFollowUps() {
    XCTAssertEqual(LanguageSupport.normalizeTransportMode("à pied"), "walking")
    XCTAssertEqual(LanguageSupport.normalizeTransportMode("zu Fuß"), "walking")
    XCTAssertEqual(LanguageSupport.normalizeTransportMode("transport en commun"), "transit")
    XCTAssertEqual(LanguageSupport.normalizeTransportMode("ÖPNV"), "transit")
    XCTAssertEqual(LanguageSupport.normalizeTransportMode("voiture"), "driving")

    for followUp in [
      "By how many minutes?", "De combien de minutes ?", "¿Por cuántos minutos?",
      "Um wie viele Minuten?", "Di quanti minuti?", "何分差ですか？", "差多少分钟？",
    ] {
      XCTAssertTrue(LanguageSupport.isDifferenceFollowUp(followUp), followUp)
    }
    XCTAssertFalse(LanguageSupport.isDifferenceFollowUp("Tell me more about Paris."))
  }

  func testSummaryAndMemoryCuesCoverRussianAndArabic() {
    XCTAssertTrue(FileContext.wantsSummary("Сделай краткое резюме этого документа"))
    XCTAssertTrue(FileContext.wantsSummary("أعطني ملخص هذا الملف"))
    XCTAssertTrue(HelperTasks.shouldLookForMemories("Запомни, я живу в Монреале"))
    XCTAssertTrue(HelperTasks.shouldLookForMemories("أنا نباتي وأعيش في مونتريال"))
  }
}
