import NaturalLanguage
import XCTest

@testable import Agello

/// Probe 37: the Concise style's instruction (2026-11-17). Under D4, "Explain how vaccines work"
/// came back in 1,000 to 1,200 characters with the Concise style; its line ("Keep answers short
/// and to the point; skip preambles and summaries.") was too weak. A table of everyday asks,
/// each with a ceiling and what it must still say, under candidate lines placed where the style
/// goes (after the base and the precedence line). `STYLE_CANDIDATES` picks some by name.
extension ProbeScenarioTests {
  func test37_ConciseStyleTable() async throws {
    try await requireLoadedModel()
    let saved = (appState.options, appState.personalization)
    defer { (appState.options, appState.personalization) = saved }
    let candidates: [(String, String?)] = [
      ("standard", nil),
      ("C0", "Keep answers short and to the point; skip preambles and summaries."),
      ("app", Personalization.Style.concise.instruction),
      ("C1", "Keep answers short: a few sentences, or a short list when the answer is a set of steps or items. Skip preambles, background and summaries."),
      ("C2", "Answer in as few words as the question allows, usually two to four sentences. Leave out background, caveats and summaries unless the user asks for them."),
      ("C3", "Be brief. Most answers should be one short paragraph; use a short list only for steps or items, with a few words each. No preamble, no summary, no offer of more help."),
      ("C4", "Keep answers short: two to four sentences for a question. For a recipe, a plan or steps, give only what's needed to do it, as a compact list. Leave out background, caveats, summaries and offers of more help."),
      ("C5", "Be concise. Answer a question in two to four sentences. For a recipe, a plan or a how-to, give a compact list with just the essentials (amounts, steps, days). No preamble, no summary, no offer of more help."),
    ]
    let wanted = ProcessInfo.processInfo.environment["STYLE_CANDIDATES"]?.split(separator: ",").map(String.init)
    struct Ask { let id: String; let prompt: String; let ceiling: Int; let must: [String]; var language: String? = nil }
    let asks = [
      Ask(id: "vaccines", prompt: "Explain how vaccines work.", ceiling: 700, must: ["immune"]),
      Ask(id: "walking", prompt: "What are the benefits of walking every day?", ceiling: 600, must: ["heart|cardio"]),
      Ask(id: "pancakes", prompt: "How do I make pancakes?", ceiling: 1000, must: ["flour", "egg|milk", #"(\d+|one|two|three|half|a) ?(cups?|tablespoons?|tbsp|teaspoons?|tsp|g\b|grams?|ml)"#]),
      Ask(id: "virus", prompt: "What's the difference between a virus and a bacterium?", ceiling: 600, must: ["cell"]),
      Ask(id: "reverse", prompt: "Write a Python function that reverses a string.", ceiling: 600, must: ["```", "def "]),
      Ask(id: "https", prompt: "How does HTTPS keep a connection private?", ceiling: 700, must: ["encrypt"]),
      Ask(id: "paris", prompt: "Plan a 3-day trip to Paris.", ceiling: 900, must: ["Day 1|Day one|First day", "Day 3|Day three|Third day", "Louvre|Eiffel"]),
      Ask(id: "japan", prompt: "What is the capital of Japan?", ceiling: 120, must: ["Tokyo"]),
      Ask(id: "moteur", prompt: "Comment fonctionne un moteur électrique ?", ceiling: 700, must: ["magn"], language: "fr"),
      Ask(id: "budget", prompt: "Give me tips to save money on groceries.", ceiling: 700, must: ["list|plan|bulk|sale"]),
    ]
    var report: [String: Any] = [:]
    for (name, line) in candidates where wanted == nil || wanted!.contains(name) {
      appState.personalization = Personalization()
      let base = SystemPrompt.fill(SystemPrompt.base, today: .now, current: .tapSearch, precedence: line != nil)
      appState.options.systemPrompt = line.map { base + "\n\n" + $0 } ?? base
      appState.options.enableThinking = false
      await appState.applyCurrentOptions()
      var rows: [[String: Any]] = []
      var passed = 0
      var total = 0
      for ask in asks {
        let exchange = await harness.ask(ask.prompt, in: harness.newThread())
        let reply = exchange.text
        var failed: [String] = []
        if reply.count > ask.ceiling { failed.append("over \(ask.ceiling) (\(reply.count))") }
        for pattern in ask.must where reply.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil {
          failed.append("missing \(pattern)")
        }
        if let language = ask.language, NLLanguageRecognizer.dominantLanguage(for: reply)?.rawValue != language {
          failed.append("not \(language)")
        }
        total += 1
        if failed.isEmpty { passed += 1 }
        rows.append(["id": ask.id, "characters": reply.count, "failed": failed, "reply": reply])
      }
      report[name] = ["line": line ?? "", "passed": passed, "total": total, "rows": rows]
      print("probe37 \(name): \(passed)/\(total); characters \(rows.map { $0["characters"] as? Int ?? 0 })")
    }
    harness.record("probe37_conciseStyle", report, in: self)
  }
}
