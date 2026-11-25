import Foundation

/// Loopback embedder for `AgelloSim`: proxies EmbeddingGemma 2 vector requests to
/// `POST /v1/embeddings` on the host Mac's `agello serve` (backed by `CoreAIEmbedder` on ANE).
actor RemoteEmbedder: TextEmbedder {
  nonisolated let dimensions = EmbeddingGemmaPrompts.outputSize
  nonisolated let identifier = EmbeddingGemmaPrompts.identifier
  nonisolated let relatedThreshold: Float = 0.60
  nonisolated let relatedMargin: Float = 0.07
  nonisolated let usesGPU = false

  private let baseURL: URL

  init(baseURL: URL = RemoteChatClient.resolveBaseURL()) {
    self.baseURL = baseURL
  }

  func embed(documents: [(title: String, text: String)]) async throws -> [[Float]] {
    guard !documents.isEmpty else { return [] }
    let payload: [String: Any] = [
      "input": documents.map(\.text),
      "titles": documents.map(\.title),
      "task": "document",
    ]
    return try await fetchVectors(payload: payload)
  }

  func embed(query: String) async throws -> [Float] {
    try await embed(query: query, task: .search)
  }

  func embed(query: String, task: EmbeddingQueryTask) async throws -> [Float] {
    let payload: [String: Any] = [
      "input": query,
      "task": task == .code ? "code" : "search",
    ]
    let vectors = try await fetchVectors(payload: payload)
    guard let first = vectors.first else {
      throw ChatError.underlying(message: "Remote embeddings returned no vector.")
    }
    return first
  }

  func unload() async {}

  private func fetchVectors(payload: [String: Any]) async throws -> [[Float]] {
    let url = baseURL.appendingPathComponent("embeddings")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 60
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
      throw ChatError.underlying(message: "Remote embeddings failed: \(msg)")
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let rows = json["data"] as? [[String: Any]]
    else {
      throw ChatError.underlying(message: "Malformed /v1/embeddings response.")
    }
    return rows.compactMap { row in
      (row["embedding"] as? [NSNumber])?.map(\.floatValue)
    }
  }
}
