import Foundation

/// What a search is about, as the planner names it: it decides which sources answer it. Every
/// source is free and permits an app like this one under its own terms, with no API key (the
/// maintainer's choice, 2026-11-12, App Review 5.2.2). One word each: our runtime's grammar fails
/// on a space inside an enum value (``WebContext/searchedKinds``).
enum SearchTopic: String, CaseIterable, Sendable {
  /// Anything else: Wikipedia, with Wikidata's facts for the article found first.
  case general
  /// Destinations, things to see and do, getting around: Wikivoyage, then Wikipedia.
  case travel
  /// A word's meaning, spelling, pronunciation, origin or translation: Wiktionary.
  case word
  /// Quotations, who said what: Wikiquote, then Wikipedia.
  case quote
  /// Weather and forecasts for a place: Apple Weather (WeatherKit).
  case weather
  /// Addresses, businesses, opening hours, places near somewhere: Apple Maps (MapKit).
  case place
  /// Exchange rates and converting money: the European Central Bank's reference rates.
  case currency
  /// Scientific studies and papers: Crossref, then Wikipedia.
  case research
  /// Medicine, symptoms, treatments: PubMed, then Wikipedia.
  case health
  /// What happened in the last few days: Wikipedia's Current events, then Wikipedia.
  case news

  /// The planner's list: each topic in a line, in the words the prompt uses.
  static var promptList: String {
    allCases.map { "- \($0.rawValue): \($0.promptDescription)" }.joined(separator: "\n")
  }

  var promptDescription: String {
    switch self {
    case .general: return "anything else: facts about people, places and things (a city's population, a country's capital), history, science, how-to, and requests to build something"
    case .travel: return "a trip, a destination, things to see or do, getting around"
    case .word: return "what a word or phrase means, how it's spelled or said, where it comes from, or how to say it in another language"
    case .quote: return "quotations, or who said something"
    case .weather: return "the weather or forecast, somewhere or where the user is"
    case .place: return "finding a business or an address on a map: the nearest gas station, a pharmacy near somewhere, when a store closes, a restaurant's address or phone number"
    case .currency: return "an exchange rate or converting an amount of money"
    case .research: return "scientific studies or papers on a subject"
    case .health: return "a disease, symptoms, a medicine or a treatment"
    case .news: return "something that happened in the last few days"
    }
  }

  /// How the planner writes this topic's queries (``WebContext/queryPrompt``).
  var queryStyle: String? {
    switch self {
    case .weather: return "the place alone, like \"Montreal\", or here when the user means where they are"
    case .place: return "what, then near, then where, like \"pharmacy near Place des Arts, Montreal\", with near me when the user means around them, like \"gas station near me\" or \"Walmart near me\""
    case .currency: return "the amount and the currencies' three-letter codes, like \"100 USD to EUR\""
    case .word: return "the word or phrase alone"
    case .quote: return "the quotation's own words"
    default: return nil
    }
  }

  /// The planner's instructions for those topics' queries, in one paragraph.
  static var queryStyles: String {
    allCases.compactMap { topic in topic.queryStyle.map { "For \(topic.rawValue), the query is \($0)." } }
      .joined(separator: " ")
  }

  /// Topics answered by one structured source: its answer comes first, alone. When it fails, the
  /// reply says so rather than answering from unrelated pages (a failed weather lookup fell back to
  /// Wikipedia and cited Paris Orly Airport, 2026-11-12).
  var isStructured: Bool { self == .weather || self == .place || self == .currency }

  /// The structured source's name, for "… isn't available right now".
  var sourceName: String {
    switch self {
    case .weather: return "Apple Weather"
    case .place: return "Apple Maps"
    case .currency: return "The European Central Bank's exchange rates"
    default: return "Search"
    }
  }
}
