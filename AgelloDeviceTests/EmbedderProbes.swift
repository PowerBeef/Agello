import Foundation
import LiteRTLM
import XCTest

@testable import Agello

extension ProbeScenarioTests {
  /// Probe 32: EmbeddingGemma 2 as the app could run it. Google's card warns that float16
  /// activations can overflow (NaN or silently degraded vectors), and our GPU runs float16 unless
  /// told otherwise; it also gives 768 dimensions (we keep 256) and a "question answering" task
  /// prefix (we use "search result" for every query). Per precision, the same passages and
  /// questions, several languages and code among them, with long distractors:
  /// - NaN and infinite components;
  /// - each passage's cosine between the float16 and float32 vectors;
  /// - whether each question's nearest passage is the right one, at 768 and 256 dimensions and
  ///   with each prefix, and by how much it beats the next one;
  /// - seconds per passage.
  func test32_EmbedderPrecision() async throws {
    await appState.engine.unload()
    let url = try ModelStore.modelsDirectory().appendingPathComponent("embeddinggemma-2-text-270m.litertlm")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("Legacy LiteRT EmbeddingGemma .litertlm not present")
    }
    let corpus = Self.embedderCorpus
    let documents = corpus.passages.map { "title: none | text: \($0)" }
    var vectors: [String: [[Float]]] = [:]
    var record: [String: Any] = ["passages": documents.count, "questions": corpus.questions.count]
    for (name, activation) in [("fp16", ActivationDataType?.none), ("fp32", ActivationDataType.float32)] {
      let engine = EmbeddingEngine(
        config: EmbeddingEngineConfig(
          modelPath: url.path, backend: .gpu, cacheDir: EngineCache.disabled, activationDataType: activation))
      try await engine.initialize()
      let options = EmbeddingOptions(normalize: true, outputSize: 768, inputOverflowStrategy: .truncate)
      let started = Date()
      var passageVectors: [[Float]] = []
      for document in documents {
        passageVectors.append(try await engine.computeEmbedding(contents: [.text(document)], options: options).embedding)
      }
      let perPassage = Date().timeIntervalSince(started) / Double(documents.count)
      var queryVectors: [String: [[Float]]] = [:]
      for prefix in ["search result", "question answering"] {
        var list: [[Float]] = []
        for question in corpus.questions {
          let text = "task: \(prefix) | query: \(question.text)"
          list.append(try await engine.computeEmbedding(contents: [.text(text)], options: options).embedding)
        }
        queryVectors[prefix] = list
      }
      await engine.close()
      vectors[name] = passageVectors
      let nonFinite = (passageVectors + queryVectors.values.flatMap { $0 }).reduce(0) { total, vector in
        total + vector.filter { !$0.isFinite }.count
      }
      var retrieval: [String: Any] = [:]
      for dimensions in [768, 256] {
        for (prefix, queries) in queryVectors {
          let ranked = Self.retrieval(
            passages: passageVectors.map { Self.truncated($0, dimensions) },
            queries: queries.map { Self.truncated($0, dimensions) }, expected: corpus.questions.map(\.answer))
          retrieval["\(dimensions)d \(prefix)"] = ranked
        }
      }
      record[name] = [
        "nonFiniteComponents": nonFinite, "secondsPerPassage": (perPassage * 10_000).rounded() / 10_000,
        "retrieval": retrieval,
      ]
      print("probe32 \(name): \(nonFinite) non-finite; \(String(format: "%.4f", perPassage)) s/passage; \(retrieval)")
    }
    if let half = vectors["fp16"], let full = vectors["fp32"] {
      let cosines = zip(half, full).map { Self.cosine($0, $1) }
      record["fp16VsFp32Cosine"] = [
        "min": Double(cosines.min() ?? 0), "mean": Double(cosines.reduce(0, +) / Float(max(1, cosines.count))),
        "perPassage": cosines.map { (Double($0) * 10_000).rounded() / 10_000 },
      ]
      print("probe32 fp16 vs fp32 cosine: min \(cosines.min() ?? 0), mean \(cosines.reduce(0, +) / Float(max(1, cosines.count)))")
    }
    harness.record("probe32_embedderPrecision", record, in: self)
    let fp32 = try XCTUnwrap(record["fp32"] as? [String: Any])
    XCTAssertEqual(fp32["nonFiniteComponents"] as? Int, 0)
  }

  /// Probe 33: the chat search's scores at 256 and 768 dimensions, to move its threshold (0.60)
  /// and margin over the median (0.08), calibrated at 256 by `KnowledgeScenarioTests.test03`. The
  /// same four chats and queries as that test, embedded as the drawer does (title and opening
  /// turns), plus unrelated queries; per dimension, each query's score for its chat, the best
  /// other chat and the median.
  func test33_ChatScoresByDimension() async throws {
    await appState.engine.unload()
    let url = try ModelStore.modelsDirectory().appendingPathComponent("embeddinggemma-2-text-270m.litertlm")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw XCTSkip("Legacy LiteRT EmbeddingGemma .litertlm not present")
    }
    let chats = [
      "Weeknight carbonara\nHow do I make carbonara without cream?\nWhisk eggs and pecorino, toss with hot spaghetti and crispy guanciale.",
      "Car making a grinding noise\nMy car grinds when I brake, what is it?\nWorn brake pads are the usual cause; have the rotors checked too.",
      "Kyoto itinerary\nPlan three days in Kyoto in spring.\nDay 1: Fushimi Inari and Gion; day 2: Arashiyama; day 3: temples in Higashiyama.",
      "Filing my tax return\nWhen is the filing deadline and what forms do I need?\nCollect your T4 slips and file by April 30 to avoid penalties.",
      "Knitting a scarf\nWhich stitch is easiest for a first scarf?\nGarter stitch: knit every row with a medium-weight wool.",
      "Laptop for school\nWhat laptop should I buy for university?\nA light 13-inch model with 16 GB of memory and all-day battery.",
    ]
    let queries: [(String, Int?)] = [
      ("Italian pasta dinner", 0), ("vehicle stopping problem", 1), ("Japan vacation plans", 2),
      ("money owed to the government", 3), ("how to train a puppy", nil), ("stock market crash of 1929", nil),
    ]
    let engine = EmbeddingEngine(
      config: EmbeddingEngineConfig(modelPath: url.path, backend: .gpu, cacheDir: EngineCache.disabled))
    try await engine.initialize()
    let options = EmbeddingOptions(normalize: true, outputSize: 768, inputOverflowStrategy: .truncate)
    var chatVectors: [[Float]] = []
    for chat in chats {
      chatVectors.append(
        try await engine.computeEmbedding(
          contents: [.text(LiteRTEmbedder.documentPrompt(title: "none", text: chat))], options: options
        ).embedding)
    }
    var queryVectors: [[Float]] = []
    for query in queries {
      queryVectors.append(
        try await engine.computeEmbedding(contents: [.text(LiteRTEmbedder.queryPrompt(query.0))], options: options)
          .embedding)
    }
    await engine.close()
    var record: [String: Any] = [:]
    for dimensions in [256, 512, 768] {
      var rows: [[String: Any]] = []
      for (index, query) in queries.enumerated() {
        let scores = chatVectors.map { Self.cosine(Self.truncated($0, dimensions), Self.truncated(queryVectors[index], dimensions)) }
        let sorted = scores.sorted()
        let median = sorted[sorted.count / 2]
        let own = query.1.map { scores[$0] }
        let others = scores.enumerated().filter { $0.offset != query.1 }.map(\.element)
        rows.append([
          "query": query.0, "own": own.map(Double.init) ?? -1, "bestOther": Double(others.max() ?? 0),
          "median": Double(median),
        ])
        let ownText = own.map { String(format: "%.3f", $0) } ?? "-"
        print("probe33 \(dimensions)d \(query.0): own \(ownText), best other \(String(format: "%.3f", others.max() ?? 0)), median \(String(format: "%.3f", median))")
      }
      record["\(dimensions)d"] = rows
    }
    harness.record("probe33_chatScoresByDimension", record, in: self)
  }

  /// The nearest passage per question, how many are right, and each right one's margin over the
  /// best wrong passage (negative when a wrong one wins).
  static func retrieval(passages: [[Float]], queries: [[Float]], expected: [Int]) -> [String: Any] {
    var correct = 0
    var margins: [Double] = []
    for (query, answer) in zip(queries, expected) {
      let scores = passages.map { cosine($0, query) }
      let best = scores.indices.max { scores[$0] < scores[$1] } ?? -1
      if best == answer { correct += 1 }
      let rival = scores.enumerated().filter { $0.offset != answer }.map(\.element).max() ?? 0
      margins.append((Double(scores[answer] - rival) * 1_000).rounded() / 1_000)
    }
    return ["correct": correct, "of": expected.count, "margins": margins]
  }

  /// A Matryoshka prefix, normalized again (the card's rule).
  static func truncated(_ vector: [Float], _ dimensions: Int) -> [Float] {
    let head = Array(vector.prefix(dimensions))
    let norm = head.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return norm > 0 ? head.map { $0 / norm } : head
  }

  static func cosine(_ a: [Float], _ b: [Float]) -> Float {
    let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    let norms = a.reduce(0) { $0 + $1 * $1 }.squareRoot() * b.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return norms > 0 ? dot / norms : 0
  }

  /// Passages in several languages, code among them, with near-miss and long distractors, and
  /// questions (in English) whose answer is one passage.
  static var embedderCorpus: (passages: [String], questions: [(text: String, answer: Int)]) {
    let passages = [
      "The Montreal Metro opened in October 1966 and its trains run on rubber tires.",  // 0
      "La tour Eiffel mesure 330 mètres depuis l'ajout de nouvelles antennes à son sommet.",  // 1
      "El Amazonas es el río más caudaloso del mundo y desemboca en el océano Atlántico.",  // 2
      "Die Berliner Mauer fiel am 9. November 1989, nach Wochen friedlicher Proteste.",  // 3
      "富士山の標高は3776メートルで、日本で最も高い山です。",  // 4
      "func fibonacci(_ n: Int) -> Int { n < 2 ? n : fibonacci(n - 1) + fibonacci(n - 2) }",  // 5
      "Metformin's most common side effects are nausea, diarrhea and an upset stomach, which often fade.",  // 6
      "The lease requires sixty days' written notice before the tenant moves out.",  // 7
      "Photosynthesis turns light, water and carbon dioxide into glucose and oxygen in the leaves.",  // 8
      "The warranty covers manufacturing defects for two years but excludes water damage.",  // 9
      "The Toronto subway opened in 1954 and was Canada's first underground railway.",  // near-miss
      "Mount Everest stands 8,849 metres above sea level on the border of Nepal and China.",
      "The Danube flows through ten countries before reaching the Black Sea.",
      "Notice of the annual meeting was sent to shareholders ten days in advance.",
      "def factorial(n): return 1 if n < 2 else n * factorial(n - 1)",
      "Ibuprofen can irritate the stomach and is best taken with food.",
      CalibrationScenarioTests.filler(bytes: 1_800),
      CalibrationScenarioTests.filler(bytes: 4_000),
      String(repeating: "Le port de Montréal accueille des navires de croisière chaque été. ", count: 40),
    ]
    let questions: [(String, Int)] = [
      ("When did Montreal's subway open?", 0),
      ("How tall is the Eiffel Tower?", 1),
      ("Which river carries the most water?", 2),
      ("When did the Berlin Wall come down?", 3),
      ("How high is Mount Fuji?", 4),
      ("Swift function that computes Fibonacci numbers recursively", 5),
      ("What are the common side effects of metformin?", 6),
      ("How much notice do I need to give before leaving my apartment?", 7),
      ("How do plants make food from sunlight?", 8),
      ("Is water damage covered by the warranty?", 9),
    ]
    return (passages, questions.map { (text: $0.0, answer: $0.1) })
  }
}
