import XCTest

@testable import Agello

/// Probe 39: EmbeddingGemma put to two more uses (2026-11-17). How close a memory is to the same
/// fact reworded, against a related but different fact (the threshold that keeps a reworded
/// memory from being saved twice); and whether code questions over files find the right passage
/// sooner with the model's code-retrieval task than with its search task.
extension ProbeScenarioTests {
  func test39_EmbeddingTasks() async throws {
    try await requireLoadedModel()
    let knowledge = appState.knowledge
    _ = try await harness.ensureDownloaded(ModelCatalog.embeddingGemma, timeout: 1800)
    let embedder = knowledge.currentEmbedder()
    XCTAssertTrue(
      embedder is CoreAIEmbedder || embedder is LiteRTEmbedder,
      "EmbeddingGemma isn't the embedder")
    let pairs: [(String, String, Bool)] = [
      ("Is vegetarian", "Doesn't eat meat", true),
      ("Lives in Montreal", "Lives in Montréal, Canada", true),
      ("Has a dog named Max", "Owns a dog called Max", true),
      ("Works as a nurse", "Is a nurse by profession", true),
      ("Is learning Spanish", "Is studying Spanish", true),
      ("Prefers metric units", "Likes measurements in metric", true),
      ("Has two children", "Is the parent of two kids", true),
      ("Is allergic to peanuts", "Has a peanut allergy", true),
      ("Is vegetarian", "Is vegan", false),
      ("Lives in Montreal", "Works in Montreal", false),
      ("Has a dog named Max", "Has a cat named Max", false),
      ("Works as a nurse", "Works as a doctor", false),
      ("Is learning Spanish", "Is learning French", false),
      ("Has two children", "Has two brothers", false),
      ("Is allergic to peanuts", "Is allergic to cats", false),
      ("Likes hiking", "Likes cooking", false),
    ]
    var pairRows: [[String: Any]] = []
    for (a, b, same) in pairs {
      let similarity = await knowledge.nearestSimilarity(of: a, among: [b]) ?? -1
      pairRows.append(["a": a, "b": b, "same": same, "similarity": Double(similarity)])
    }
    let sameScores = pairRows.filter { $0["same"] as? Bool == true }.compactMap { $0["similarity"] as? Double }
    let otherScores = pairRows.filter { $0["same"] as? Bool == false }.compactMap { $0["similarity"] as? Double }
    print("probe39 same \(sameScores.map { String(format: "%.3f", $0) }) other \(otherScores.map { String(format: "%.3f", $0) })")

    let passages = [
      "def reverse_words(text):\n    return ' '.join(reversed(text.split()))",
      "function debounce(fn, ms) {\n  let timer;\n  return (...args) => { clearTimeout(timer); timer = setTimeout(() => fn(...args), ms); };\n}",
      "struct User: Codable {\n  let id: Int\n  let name: String\n}\nlet user = try JSONDecoder().decode(User.self, from: data)",
      "SELECT city, COUNT(*) FROM orders GROUP BY city ORDER BY COUNT(*) DESC LIMIT 5;",
      "import re\nemails = re.findall(r'[\\w.+-]+@[\\w-]+\\.[\\w.]+', text)",
      "with open('data.csv', newline='') as f:\n    rows = list(csv.DictReader(f))",
      "Our quarterly report shows revenue grew by twelve percent, driven by the new subscription plans.",
      "The team decided to move the weekly meeting to Thursday afternoons starting next month.",
      "Water quality in district 4 was inspected in March; all samples met the national standard.",
      "The library will close for renovations from June to August and reopen in September.",
      "Remote work policies now allow two days a week from home for every department.",
      "The new bridge reduces the commute between the two neighborhoods by about fifteen minutes.",
    ]
    let questions: [(String, Int)] = [
      ("How do I reverse the order of words in a string in Python?", 0),
      ("debounce a function call in JavaScript", 1),
      ("How do I decode JSON into a struct in Swift?", 2),
      ("Which SQL query gives the top 5 cities by number of orders?", 3),
      ("extract email addresses with a regex", 4),
      ("How do I read a CSV file into a list of dicts?", 5),
    ]
    var codeRows: [[String: Any]] = []
    for (question, answer) in questions {
      var row: [String: Any] = ["question": question]
      for task in [EmbeddingQueryTask.search, .code] {
        let ranked = await knowledge.rank(passages, against: question, task: task) ?? []
        row[task == .search ? "searchRank" : "codeRank"] = (ranked.firstIndex(of: passages[answer]) ?? -1) + 1
      }
      codeRows.append(row)
    }
    print("probe39 code ranks \(codeRows.map { "\($0["searchRank"] ?? 0)/\($0["codeRank"] ?? 0)" })")

    // Harder: code passages only, on overlapping subjects, and questions that name what the code
    // does in other words.
    let code = [
      "def slugify(title):\n    return re.sub(r'[^a-z0-9]+', '-', title.lower()).strip('-')",
      "def word_count(text):\n    return Counter(text.lower().split())",
      "def dedupe(items):\n    seen = set()\n    return [x for x in items if not (x in seen or seen.add(x))]",
      "def chunks(items, size):\n    return [items[i:i + size] for i in range(0, len(items), size)]",
      "def flatten(nested):\n    return [x for sub in nested for x in sub]",
      "def read_json(path):\n    with open(path) as f:\n        return json.load(f)",
      "def write_json(path, data):\n    with open(path, 'w') as f:\n        json.dump(data, f, indent=2)",
      "def days_between(a, b):\n    return abs((date.fromisoformat(b) - date.fromisoformat(a)).days)",
      "def fetch(url):\n    with urllib.request.urlopen(url, timeout=10) as response:\n        return response.read().decode()",
      "const sortByDate = (items) => [...items].sort((a, b) => new Date(a.date) - new Date(b.date));",
      "const groupBy = (items, key) => items.reduce((acc, x) => ((acc[x[key]] ??= []).push(x), acc), {});",
      "const throttle = (fn, ms) => { let last = 0; return (...a) => { const now = Date.now(); if (now - last >= ms) { last = now; fn(...a); } }; };",
      "func isPalindrome(_ s: String) -> Bool {\n  let letters = s.lowercased().filter(\\.isLetter)\n  return letters == String(letters.reversed())\n}",
      "extension Array {\n  func chunked(into size: Int) -> [[Element]] {\n    stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }\n  }\n}",
    ]
    let hardQuestions: [(String, Int)] = [
      ("turn a blog post title into a URL-friendly string", 0),
      ("how often does each word occur in a text", 1),
      ("remove repeated entries from a list but keep the order", 2),
      ("split a list into pieces of n elements in Python", 3),
      ("make one list out of a list of lists", 4),
      ("save a dictionary to a file as pretty JSON", 6),
      ("number of days between two ISO dates", 7),
      ("download the contents of a web page", 8),
      ("order objects by their date field in JavaScript", 9),
      ("bucket an array of objects by a property", 10),
      ("call a function at most once every N milliseconds", 11),
      ("check whether a string reads the same backwards in Swift", 12),
    ]
    var hardRows: [[String: Any]] = []
    for (question, answer) in hardQuestions {
      var row: [String: Any] = ["question": question]
      for task in [EmbeddingQueryTask.search, .code] {
        let ranked = await knowledge.rank(code, against: question, task: task) ?? []
        row[task == .search ? "searchRank" : "codeRank"] = (ranked.firstIndex(of: code[answer]) ?? -1) + 1
      }
      hardRows.append(row)
    }
    func reciprocal(_ key: String) -> Double {
      hardRows.map { 1 / Double(max(1, $0[key] as? Int ?? 99)) }.reduce(0, +) / Double(hardRows.count)
    }
    print("probe39 hard ranks \(hardRows.map { "\($0["searchRank"] ?? 0)/\($0["codeRank"] ?? 0)" }) MRR search \(reciprocal("searchRank")) code \(reciprocal("codeRank"))")
    harness.record(
      "probe39_embeddingTasks",
      ["pairs": pairRows, "sameMin": sameScores.min() ?? 0, "otherMax": otherScores.max() ?? 0, "code": codeRows,
       "hardCode": hardRows],
      in: self)
  }
}
