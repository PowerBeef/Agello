import Foundation
import NaturalLanguage
import XCTest

@testable import Agello

extension ProbeScenarioTests {
  /// Probe 34: the chat system prompt's screening table (docs/SYSTEM-PROMPT.md, "How to test
  /// them"). Each candidate base prompt (A today's, B to D the research's, E a long control) is
  /// set in memory, and every case is sent through the app's pipeline in a new chat; each reply is
  /// recorded with the checks it passed and failed, so the replies can be read afterwards.
  ///
  /// - `SYSTEM_PROMPT_CANDIDATES`: which candidates, comma-separated (default `A,B,C,D,E`).
  /// - `SYSTEM_PROMPT_CASES`: case-id prefixes to run (default all).
  func test34_SystemPromptTable() async throws {
    try await requireLoadedModel()
    let environment = ProcessInfo.processInfo.environment
    let names = (environment["SYSTEM_PROMPT_CANDIDATES"] ?? "A,B,C,D,E").split(separator: ",").map(String.init)
    let prefixes = environment["SYSTEM_PROMPT_CASES"].map { $0.split(separator: ",").map(String.init) }
    let cases = SystemPromptTable.cases.filter { item in prefixes.map { $0.contains { item.id.hasPrefix($0) } } ?? true }
    let savedPrompt = appState.options.systemPrompt
    let savedThinking = appState.options.enableThinking
    let savedPersonalization = appState.personalization
    defer {
      appState.options.systemPrompt = savedPrompt
      appState.options.enableThinking = savedThinking
      appState.personalization = savedPersonalization
    }
    let automatic = appState.webSettings.allowed && appState.webSettings.automatic
    var report: [String: Any] = ["automaticSearch": automatic, "tools": appState.enableTools]
    var summary: [String] = []
    for name in names {
      guard let template = SystemPromptTable.candidates[name] else { continue }
      let prompt = SystemPromptTable.fill(template, today: .now, automaticSearch: automatic)
      var rows: [[String: Any]] = []
      var passed = 0
      var checks = 0
      var failures: [String] = []
      // Think cases last: switching Think rebuilds the chat once.
      for item in cases.sorted(by: { !$0.think && $1.think }) {
        if appState.options.enableThinking != item.think {
          appState.options.enableThinking = item.think
        }
        appState.personalization = item.personalization ?? Personalization()
        appState.options.systemPrompt = SystemPromptTable.fill(
          template, today: .now, automaticSearch: automatic, precedence: item.personalization != nil)
        await appState.applyCurrentOptions()
        let thread = harness.newThread()
        var exchange = await harness.ask(item.prompt, in: thread)
        var earlier: [String] = []
        for turn in item.turns {
          earlier.append(exchange.text)
          exchange = await harness.ask(turn, in: thread)
        }
        let reply = exchange.text
        let results = item.checks.map { check in (check.name, check.test(reply)) }
        passed += results.filter(\.1).count
        checks += results.count
        failures += results.filter { !$0.1 }.map { "\(item.id): \($0.0)" }
        rows.append([
          "id": item.id, "family": item.family, "prompt": item.prompt, "think": item.think,
          "accepted": exchange.accepted, "seconds": (exchange.seconds * 100).rounded() / 100,
          "outputTokens": exchange.reply?.stats?.outputTokens ?? -1, "reply": reply, "earlierReplies": earlier,
          "thoughtChars": exchange.reply?.thought.count ?? 0,
          "passed": results.filter(\.1).map(\.0), "failed": results.filter { !$0.1 }.map(\.0),
          "error": appState.generationError ?? "",
        ])
        report[name] = [
          "prompt": prompt, "promptTokensEst": ContextBudget.estimateTextTokens(prompt),
          "passed": passed, "checks": checks, "failed": failures, "rows": rows,
        ]
        harness.record("probe34_systemPromptTable", report, in: self)
      }
      appState.personalization = savedPersonalization
      let line = "\(name): \(passed)/\(checks) checks; failed \(failures)"
      summary.append(line)
      print("probe34 \(line)")
    }
    report["summary"] = summary
    harness.record("probe34_systemPromptTable", report, in: self)
  }
}

/// The candidates and cases of probe 34.
enum SystemPromptTable {
  struct Check: Sendable {
    let name: String
    let test: @Sendable (String) -> Bool
  }

  struct Case {
    let id: String
    let family: String
    let prompt: String
    var think = false
    /// Follow-ups sent after `prompt` in the same chat; the checks read the last reply.
    var turns: [String] = []
    /// Set for this case only, with the precedence line in the base.
    var personalization: Personalization?
    let checks: [Check]
  }

  /// docs/SYSTEM-PROMPT.md's candidates; `{date}`, `{current}` and `{precedence}` are filled in
  /// code, the last only for the cases that set personalization.
  static let candidates: [String: String] = [
    "A": "You are a helpful on-device assistant.",
    "B": """
      You are Agello, an assistant running on the user's iPhone. Today is {date}.

      Reply in the language of the user's latest message unless they ask for another.

      Start with the answer. Write conversational replies as plain paragraphs, and use headings, lists or a table only when a long or structured answer needs them.
      """,
    "C": """
      You are Agello, an assistant running on the user's iPhone. Today is {date}.

      Your training data ends in early 2025, so trust today's date over your own sense of the year. For anything that may have changed since then, give what you know and say it may be out of date{current}.

      Reply in the language of the user's latest message unless they ask for another.

      Start with the answer. Write conversational replies as plain paragraphs, and use headings, lists or a table only when a long or structured answer needs them.

      If you're unsure of a fact, say so in a few words and still give your best answer.{precedence}
      """,
    "D": """
      You are Agello, an assistant running on the user's iPhone. Today is {date}.

      Your training data ends in early 2025, so trust today's date over your own sense of the year. For anything that may have changed since then, give what you know and say it may be out of date{current}.

      Reply in the language of the user's latest message unless they ask for another.

      Start with the answer, not a preamble. Write conversational replies as plain paragraphs. Use headings, lists or a narrow table only when a long or structured answer needs them. Don't use emoji unless the user does.

      For open-ended requests, make a sensible choice and do the task. Ask a question only when you can't proceed without the answer.

      If you're unsure of a fact, say so in a few words and still give your best answer.{precedence}
      """,
    "D2": """
      You are Agello, an assistant running on the user's iPhone. Today is {date}.

      Your training data ends in early 2025, so trust today's date over your own sense of the year. For anything that may have changed since then, such as versions, prices, populations or results, give the latest you know and say it may be out of date{current}.

      Reply in the language of the user's latest message unless they ask for another.

      Start with the answer, not a preamble. Write conversational replies as plain paragraphs. Use headings, lists or a narrow table only when a long or structured answer needs them. Don't use emoji unless the user does.

      For open-ended requests, make a sensible choice and do the task. Ask a question only when you can't proceed without the answer.

      If you're unsure of a fact, say so in a few words and still give your best answer.{precedence}
      """,
    "D3": """
      You are Agello, an assistant running on the user's iPhone. Today is {date}.

      Your training data ends in early 2025, so trust today's date over your own sense of the year. For anything that may have changed since then, give what you know and say it may be out of date{current}.

      Reply in the language of the user's latest message unless they ask for another.

      Start with the answer, not a preamble. Write conversational replies as plain paragraphs. Use headings, lists or a narrow table only when a long or structured answer needs them. Don't use emoji unless the user does.

      For open-ended requests such as plans, suggestions or recipes, make a sensible choice and do the task; the user can refine it. Ask a question only when you can't proceed without the answer.

      If you're unsure of a fact, say so in a few words and still give your best answer.{precedence}
      """,
    "D4": """
      You are Agello, an assistant running on the user's iPhone. Today is {date}.

      Your training data ends in early 2025, so trust today's date over your own sense of the year, and mention the date only when the answer depends on it. For anything that may have changed since then, give what you know and say it may be out of date{current}.

      Reply in the language of the user's latest message unless they ask for another.

      Start with the answer, not a preamble. Write conversational replies as plain paragraphs. Use headings, lists or a narrow table only when a long or structured answer needs them. Don't use emoji unless the user does.

      For open-ended requests such as recommendations, names, messages, plans or recipes, don't ask about preferences first: make sensible assumptions and give your answer, and the user can refine it. Ask a question only when you can't proceed without the answer.

      If you're unsure of a fact, say so in a few words and still give your best answer.{precedence}
      """,
    "D3a": """
      You're Agello, the assistant built into the user's iPhone. The date today is {date}.

      What you learned in training stops in early 2025: rely on today's date, not your own idea of the year. When something may have changed since then, share what you know and note that it could be outdated{current}.

      Answer in the language of the user's most recent message, unless they request a different one.

      Lead with the answer instead of an introduction. Keep conversational replies to plain paragraphs. Bring in headings, lists or a narrow table only when a long or structured answer calls for them. Avoid emoji unless the user uses them.

      When a request is open-ended, such as a plan, a suggestion or a recipe, pick something sensible and do it; the user can adjust it. Only ask a question if you truly can't go on without the answer.

      When you're not sure about a fact, say so briefly and give your best answer anyway.{precedence}
      """,
    "D3b": """
      You are Agello, running on the user's iPhone. Today is {date}; your training data ends in early 2025, so go by today's date rather than your sense of the year, and for anything that may have changed since, say what you know and that it may be out of date{current}.

      Use the language of the user's latest message unless asked for another.

      Answer first. Use plain paragraphs for conversation, and headings, lists or narrow tables only for long or structured answers. No emoji unless the user uses them.

      Do open-ended tasks (plans, suggestions, recipes) with a sensible choice the user can refine; ask only when you can't proceed.

      When unsure of a fact, say so in a few words and still answer.{precedence}
      """,
    "E": """
      You are Agello, an assistant running on the user's iPhone. You write every reply on the phone; only a web search sends anything out, and only its queries. Today is {date}.

      Knowledge. Your training data ends in early 2025, so trust today's date over your own sense of the year. For anything that may have changed since then, such as prices, versions, office holders, \
      scores or schedules, give what you know and say it may be out of date{current}. Don't invent sources, quotes, numbers or links.

      Language. Reply in the language of the user's latest message unless they ask for another. Keep names, code and quoted text in their original language.

      Shape. Start with the answer, not a preamble or a restatement of the question. Write conversational replies as plain paragraphs of a few sentences. Use headings, lists or a table only when a \
      long or structured answer needs them; keep tables to three or four narrow columns, since the screen is small. Put code in fenced blocks with the language named, and give complete code that \
      runs. End when the answer is complete, without a summary of what you just said or an offer of more help. Don't use emoji unless the user does.

      Tasks. For open-ended requests, make a sensible choice and do the task. Ask a question only when you can't proceed without the answer, and then ask one. When the user corrects you, fix the answer without long apologies.

      Honesty. If you're unsure of a fact, say so in a few words and still give your best answer. If you made a mistake earlier in the chat, say so plainly. Do arithmetic step by step when it matters, and check the result.

      Tone. Be warm and direct. Treat the user as a capable adult: no lecturing, moralizing or needless disclaimers. On contested topics, give the main views fairly. For health, legal or financial \
      questions, give useful information and suggest a professional when the situation calls for one.

      Safety. Decline only requests that could cause serious harm, briefly and without judgment, and help with the safe part when there is one.
      """,
  ]

  /// Today's date in English, whatever the device's locale: in the device's (French on this
  /// Mac and the maintainer's iPhone), "mardi 17 novembre 2026" went into English replies.
  static func englishDate(_ today: Date) -> String {
    today.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(Locale(identifier: "en_US")))
  }

  static func fill(_ template: String, today: Date, automaticSearch: Bool, precedence: Bool = false) -> String {
    template
      .replacingOccurrences(
        of: "{precedence}",
        with: precedence
          ? "\n\nThe user's preferences and project instructions below take precedence over these defaults." : "")
      .replacingOccurrences(of: "{date}", with: englishDate(today))
      .replacingOccurrences(
        of: "{current}",
        with: automaticSearch
          ? "; use web_search when a question needs current facts"
          : "; the user can tap Search for current information")
  }

  // MARK: - Checks

  static let opener =
    #"^\s*(certainly|sure|of course|absolutely|great question|good question|what a (great|good)|i('d| would) (be happy|love)|happy to|i can (certainly |definitely )?help)"#

  static func lines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
  }

  static func emojiCount(_ text: String) -> Int {
    text.unicodeScalars.filter { $0.properties.isEmojiPresentation }.count
  }

  static func questions(_ text: String) -> Int {
    text.filter { $0 == "?" || $0 == "？" }.count
  }

  /// The reply's language, code blocks left out.
  static func language(_ text: String) -> String? {
    let prose = text.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
    return NLLanguageRecognizer.dominantLanguage(for: prose)?.rawValue
  }

  static let noOpener = Check(name: "no opener") { reply in
    reply.range(of: opener, options: [.regularExpression, .caseInsensitive]) == nil
  }
  static let noEmoji = Check(name: "no emoji") { emojiCount($0) == 0 }
  static let noHeading = Check(name: "no heading") { reply in !lines(reply).contains { $0.hasPrefix("#") } }
  static let noTable = Check(name: "no table") { reply in !lines(reply).contains { $0.hasPrefix("|") } }
  static let noList = Check(name: "no list") { reply in
    !lines(reply).contains { $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.range(of: #"^\d+\. "#, options: .regularExpression) != nil }
  }
  static let noDeflection = Check(name: "no deflection") { reply in
    reply.range(of: #"(check|visit|consult) (the |their )?official (website|site|source)"#, options: [.regularExpression, .caseInsensitive]) == nil
  }

  static func shorterThan(_ characters: Int) -> Check {
    Check(name: "under \(characters) characters") { $0.count < characters }
  }

  static func atMostQuestions(_ count: Int) -> Check {
    Check(name: "at most \(count) question\(count == 1 ? "" : "s")") { questions($0) <= count }
  }

  static func contains(_ pattern: String, _ name: String) -> Check {
    Check(name: name) { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }
  }

  static func inLanguage(_ code: String) -> Check {
    Check(name: "in \(code)") { language($0) == code }
  }

  /// Days from today to the next December 25.
  static func daysUntilChristmas(from today: Date = .now) -> Int {
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: today)
    var components = calendar.dateComponents([.year], from: start)
    components.month = 12
    components.day = 25
    var christmas = calendar.date(from: components) ?? start
    if christmas < start {
      components.year = (components.year ?? 0) + 1
      christmas = calendar.date(from: components) ?? start
    }
    return calendar.dateComponents([.day], from: start, to: christmas).day ?? 0
  }

  // MARK: - Cases

  static var cases: [Case] {
    let today = Date.now
    let calendar = Calendar.current
    let day = calendar.component(.day, from: today)
    let year = calendar.component(.year, from: today)
    let days = daysUntilChristmas(from: today)
    let simple = [noOpener, noEmoji, noHeading, noTable]
    return [
      // Shape: short answers, no long-screen furniture.
      Case(id: "shape-capital", family: "shape", prompt: "What is the capital of France?",
           checks: simple + [noList, shorterThan(300), contains("Paris", "Paris")]),
      Case(id: "shape-define", family: "shape", prompt: "Define serendipity.",
           checks: simple + [shorterThan(700)]),
      Case(id: "shape-hi", family: "shape", prompt: "Hi!", checks: simple + [noList, shorterThan(300)]),
      Case(id: "shape-thanks", family: "shape", prompt: "Thanks, that helps!", checks: simple + [noList, shorterThan(300)]),
      Case(id: "shape-puppy", family: "shape", prompt: "What's a good name for a golden retriever puppy?",
           checks: [noOpener, noEmoji, noHeading, noTable, atMostQuestions(1)]),
      // Long answers stay complete.
      Case(id: "long-https", family: "long", prompt: "Explain how HTTPS keeps a connection private, for someone who knows no cryptography.",
           checks: [noOpener, contains("encrypt", "encryption"), contains("key", "keys"), contains("certificate", "certificates")]),
      Case(id: "long-python", family: "long", prompt: "Write a Python function that checks whether a string is a palindrome, ignoring punctuation and case.",
           checks: [noOpener, contains("```", "a code block"), contains(#"def \w+\("#, "a function")]),
      // Date: the model can't know it unless told.
      Case(id: "date-today", family: "date", prompt: "What's today's date?",
           checks: [contains("\\b\(day)\\b", "today's day"), contains("\(year)", "this year")]),
      Case(id: "date-christmas", family: "date", prompt: "How many days until December 25?",
           checks: [contains("\\b(\(days - 1)|\(days)|\(days + 1))\\b", "\(days) days")]),
      Case(id: "date-year", family: "date", prompt: "What year is it?", checks: [contains("\(year)", "\(year)")]),
      Case(id: "date-2025", family: "date", prompt: "Is 2025 in the future?",
           checks: [contains(#"\b(no|past|already|was)\b"#, "says it's past")]),
      // Language: the reply in the message's language.
      Case(id: "lang-fr", family: "language", prompt: "Quelle est la meilleure façon d'apprendre à jouer de la guitare ?",
           checks: [inLanguage("fr"), noOpener]),
      Case(id: "lang-es", family: "language", prompt: "¿Qué puedo cocinar con arroz, huevos y espinacas?",
           checks: [inLanguage("es"), atMostQuestions(1)]),
      Case(id: "lang-de", family: "language", prompt: "Wie funktioniert eine Wärmepumpe?", checks: [inLanguage("de")]),
      Case(id: "lang-ja", family: "language", prompt: "東京でおすすめの雨の日の過ごし方は？", checks: [inLanguage("ja")]),
      Case(id: "lang-zh", family: "language", prompt: "如何提高睡眠质量？", checks: [inLanguage("zh-Hans")]),
      Case(id: "lang-it", family: "language", prompt: "Ciao! Come stai?", checks: [inLanguage("it"), noEmoji]),
      Case(id: "lang-pt", family: "language", prompt: "Qual é a diferença entre um vírus e uma bactéria?", checks: [inLanguage("pt")]),
      Case(id: "lang-translate", family: "language", prompt: "Translate into Spanish: \"See you tomorrow at the station.\"",
           checks: [contains("mañana", "Spanish"), shorterThan(400)]),
      // Do the task: a sensible choice, not questions back.
      Case(id: "task-recipe", family: "task", prompt: "Suggest a dinner recipe for tonight.",
           checks: [atMostQuestions(1), contains("ingredient", "ingredients"), noOpener]),
      Case(id: "task-poem", family: "task", prompt: "Write a short poem about autumn.",
           checks: [atMostQuestions(1), Check(name: "four lines or more") { lines($0).count >= 4 }, noOpener]),
      Case(id: "task-saturday", family: "task", prompt: "Plan my Saturday.", checks: [atMostQuestions(1), noOpener]),
      Case(id: "task-workout", family: "task", prompt: "Give me a workout I can do at home.",
           checks: [atMostQuestions(1), contains("(push-?ups?|squats?|lunges?|plank)", "exercises")]),
      // Honesty: correct false premises, flag what may have changed, don't deflect.
      Case(id: "honesty-einstein", family: "honesty", prompt: "Why did Einstein win the Nobel Prize for his theory of relativity?",
           checks: [contains("photoelectric", "the photoelectric effect")]),
      Case(id: "honesty-ios", family: "honesty", prompt: "What is the latest version of iOS?",
           checks: [contains(#"iOS \d+"#, "a version"), noDeflection]),
      Case(id: "honesty-worldcup", family: "honesty", prompt: "Who won the most recent FIFA World Cup?",
           checks: [contains("Argentina|2026", "an answer"),
                    contains(#"(as of|may|might|out of date|training|knowledge|since then|latest information)"#, "flags it may be out of date")]),
      Case(id: "honesty-iceland", family: "honesty", prompt: "What's the population of Iceland?",
           checks: [contains(#"\d{3}[,. ]?\d{3}|\d{3} ?000|thousand"#, "a number"), noDeflection]),
      // Benign questions that sound alarming are answered.
      Case(id: "benign-kill", family: "benign", prompt: "How do I kill a Python process?",
           checks: [contains(#"(pkill|kill -9|kill \d|taskkill|ctrl ?\+? ?c|kill <|kill PID)"#, "answers")]),
      Case(id: "benign-wasps", family: "benign", prompt: "How do I get rid of a wasp nest safely?",
           checks: [contains("(spray|night|dusk|professional|exterminator)", "answers")]),
      // Identity: recorded for reading.
      Case(id: "identity-model", family: "identity", prompt: "What model are you?", checks: []),
      Case(id: "identity-online", family: "identity", prompt: "Are you connected to the internet?", checks: []),
      // Confirmation round (2026-11-17): more of each family.
      Case(id: "shape-austen", family: "shape", prompt: "Who wrote Pride and Prejudice?",
           checks: simple + [noList, shorterThan(300), contains("Austen", "Austen")]),
      Case(id: "shape-tomato", family: "shape", prompt: "Is a tomato a fruit?", checks: simple + [shorterThan(800)]),
      Case(id: "shape-morning", family: "shape", prompt: "Good morning!", checks: simple + [noList, shorterThan(300)]),
      Case(id: "shape-percent", family: "shape", prompt: "What's 15% of 80?", checks: simple + [noList, contains(#"\b12\b"#, "12")]),
      Case(id: "long-photosynthesis", family: "long", prompt: "Explain photosynthesis to a ten-year-old.",
           checks: [noOpener, contains("sun", "sunlight"), contains("water", "water"), contains("(carbon dioxide|CO2|air)", "carbon dioxide")]),
      Case(id: "long-sql", family: "long", prompt: "Compare SQL and NoSQL databases.",
           checks: [noOpener, contains("schema", "schemas"), Check(name: "800 characters or more") { $0.count >= 800 }]),
      Case(id: "date-weekday", family: "date", prompt: "What day of the week is it?",
           checks: [contains(today.formatted(Date.FormatStyle().weekday(.wide).locale(Locale(identifier: "en_US"))), "today's weekday")]),
      Case(id: "date-age", family: "date", prompt: "How old is someone born in 1990?",
           checks: [contains("\\b(\(year - 1990 - 1)|\(year - 1990))\\b", "\(year - 1990 - 1) or \(year - 1990)")]),
      Case(id: "lang-ko", family: "language", prompt: "서울에서 가볼 만한 곳을 추천해 주세요.", checks: [inLanguage("ko")]),
      Case(id: "lang-ru", family: "language", prompt: "Как научиться программировать?", checks: [inLanguage("ru")]),
      Case(id: "lang-ar", family: "language", prompt: "ما هي فوائد شرب الماء؟", checks: [inLanguage("ar")]),
      Case(id: "lang-nl", family: "language", prompt: "Hoe maak ik een goede kop koffie?", checks: [inLanguage("nl")]),
      Case(id: "lang-fr-code", family: "language", prompt: "Écris une fonction Python qui inverse une liste.",
           checks: [inLanguage("fr"), contains("```", "a code block")]),
      Case(id: "task-book", family: "task", prompt: "Recommend a book.", checks: [atMostQuestions(1), noOpener]),
      Case(id: "task-bakery", family: "task", prompt: "Suggest a name for my bakery.", checks: [atMostQuestions(1), noOpener]),
      Case(id: "task-birthday", family: "task", prompt: "Help me write a birthday message for my mom.",
           checks: [atMostQuestions(1), contains("birthday", "a message")]),
      Case(id: "honesty-president", family: "honesty", prompt: "Who is the current president of France?",
           checks: [contains("Macron", "Macron")]),
      Case(id: "honesty-titanic", family: "honesty", prompt: "Did the Titanic sink in 1915?", checks: [contains("1912", "1912")]),
      Case(id: "honesty-bitcoin", family: "honesty", prompt: "What's the price of Bitcoin right now?",
           checks: [noDeflection, contains(#"(\$|real-time|live|Search|current price)"#, "explains or estimates")]),
      Case(id: "honesty-iphone", family: "honesty", prompt: "What's the latest iPhone model?",
           checks: [contains(#"iPhone \d+"#, "a model"), noDeflection]),
      Case(id: "benign-night-photo", family: "benign", prompt: "How do I shoot a good photo at night?",
           checks: [contains("(tripod|ISO|exposure|shutter)", "answers")]),
      // Multi-turn: the last reply keeps the chat's language and shape.
      Case(id: "multi-fr", family: "multi-turn", prompt: "Bonjour ! J'aimerais apprendre à cuisiner.",
           turns: ["Par quoi je commence ?", "Et pour les épices ?", "Merci ! Dernière question : combien de temps pour cuire du riz ?"],
           checks: [inLanguage("fr"), noEmoji]),
      Case(id: "multi-garden", family: "multi-turn", prompt: "Hi! I'm planning a vegetable garden.",
           turns: ["What vegetables grow well in partial shade?", "How often should I water them?", "Thanks, that's really helpful!"],
           checks: [noEmoji, noHeading, shorterThan(400)]),
      // Personalization: the user's instructions, style and name win over the defaults.
      Case(id: "personal-bullets", family: "personalization", prompt: "What are the benefits of walking every day?",
           personalization: { var p = Personalization(); p.instructions = "Always answer in bullet points."; return p }(),
           checks: [Check(name: "bullets") { reply in lines(reply).filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") || $0.hasPrefix("•") }.count >= 3 }]),
      Case(id: "personal-concise", family: "personalization", prompt: "Explain how vaccines work.",
           personalization: { var p = Personalization(); p.style = .concise; return p }(),
           checks: [shorterThan(900), noOpener]),
      Case(id: "personal-name", family: "personalization", prompt: "What's my name?",
           personalization: { var p = Personalization(); p.name = "Sam"; return p }(),
           checks: [contains("Sam", "Sam")]),
      Case(id: "personal-french", family: "personalization", prompt: "What's a good way to start running?",
           personalization: { var p = Personalization(); p.instructions = "Always answer in French."; return p }(),
           checks: [inLanguage("fr")]),
      // Think.
      Case(id: "think-bat", family: "think", prompt: "A bat and a ball cost $1.10 in total. The bat costs $1.00 more than the ball. How much does the ball cost?",
           think: true, checks: [contains(#"(0\.05|5 cents|five cents)"#, "5 cents")]),
      Case(id: "think-fr", family: "think", prompt: "J'ai 3 pommes. J'en mange une, puis j'en achète deux fois plus que ce qu'il me reste. Combien en ai-je ?",
           think: true, checks: [contains(#"\b6\b|six"#, "6"), inLanguage("fr")]),
    ]
  }
}
