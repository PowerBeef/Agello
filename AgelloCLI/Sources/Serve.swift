import Darwin
import Foundation
import LiteRTLM

/// Strict FIFO async turn serializer ensuring concurrent HTTP requests never interleave or overlap
/// `Engine`/`Conversation` operations across `await` suspension points (`W3-22`).
actor ServeTurnQueue {
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    guard busy else {
      busy = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
  }

  func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
    await acquire()
    defer { release() }
    return try await operation()
  }
}

/// Unshipped local-only OpenAI `/v1` HTTP server for external evaluation harnesses (`gbench`) and
/// the iOS Simulator bridge (`AgelloSim`). Binds strictly to `127.0.0.1`.
enum Serve {
  static let maxRequestBodyBytes = 64 * 1024 * 1024, maxHeaderBytes = 1_048_576
  fileprivate static let socketTimeoutSeconds = 30
  fileprivate static let httpIOQueue = DispatchQueue(
    label: "com.patricedery.agello.serve.http-io", qos: .userInitiated, attributes: .concurrent)

  struct Options: Sendable {
    var port: UInt16 = 8091
    var modelID = "google/gemma-4-E4B-it"
    var kvTokens = 65_536, thinkingBudget = DeviceProfile.defaultThinkingBudget
    var thinkByDefault = false, allowMTP = true
  }

  struct HTTPRequest: Sendable, Equatable {
    let method, path: String
    let body: Data
  }

  struct ParsedHeaders: Sendable, Equatable {
    let method, path: String
    let contentLength: Int
    let chunked: Bool
  }

  enum HTTPReadOutcome: Sendable, Equatable {
    case request(HTTPRequest), payloadTooLarge, badRequest(String), closedOrInvalid
  }

  enum HeaderParseError: Error, Equatable, Sendable {
    case malformed, invalidContentLength, payloadTooLarge
    var message: String {
      switch self {
      case .malformed: "Malformed HTTP request headers."
      case .invalidContentLength: "Invalid Content-Length header."
      case .payloadTooLarge: "Request body exceeds 64 MiB limit."
      }
    }
  }

  private struct UsageError: Error { let message: String }

  static func main(_ arguments: inout Arguments, paths: [String: String]) async -> Int32 {
    let opts: Options
    do { opts = try parseOptions(&arguments) } catch {
      note(error.message)
      return 2
    }
    let modelsDir = paths["models"] ?? Setup.expand(Setup.modelsDefault)
    guard let modelURL = resolveModelURL(modelsDir: modelsDir) else {
      note("Model file \(ModelCatalog.e4b.fileName) not found in \(modelsDir).")
      return 1
    }
    let serverEngine: ServeEngine
    do {
      serverEngine = try await ServeEngine.load(modelURL: modelURL, modelsDir: modelsDir, options: opts)
    } catch {
      note("Failed to load engine: \(error)")
      return 1
    }
    guard let listenFD = openLoopbackSocket(port: opts.port) else { return 1 }
    defer { close(listenFD) }
    note(
      "agello serve ready on http://127.0.0.1:\(opts.port)/v1 (model=\(opts.modelID), "
        + "kv=\(serverEngine.allocatedPositions), mtp=\(opts.allowMTP), "
        + "embeddings=\(serverEngine.hasEmbedder), runtime_build=\(EngineCache.runtimeBuildID))")
    await acceptLoop(listenFD: listenFD, engine: serverEngine, modelID: opts.modelID)
    return 0
  }

  private static func parseOptions(_ arguments: inout Arguments) throws(UsageError) -> Options {
    var opts = Options()
    if let portText = arguments.value("port") {
      guard let parsed = UInt16(portText), parsed > 0 else {
        throw UsageError(message: "--port expects a valid TCP port (1-65535).")
      }
      opts.port = parsed
    }
    if let id = arguments.value("model-id"), !id.isEmpty { opts.modelID = id }
    if let kv = arguments.value("kv").flatMap(Int.init), kv > 0 { opts.kvTokens = kv }
    let thinkArg = arguments.think()
    if thinkArg.given && !arguments.flag("no-think") {
      opts.thinkByDefault = true
      if let budget = thinkArg.budget { opts.thinkingBudget = budget }
    }
    if arguments.flag("no-mtp") { opts.allowMTP = false }
    guard arguments.rest.isEmpty else {
      throw UsageError(message: "Not understood: \(arguments.rest.joined(separator: " "))")
    }
    return opts
  }

  private static func resolveModelURL(modelsDir: String) -> URL? {
    [ModelCatalog.e4b.fileName, "gemma-4-E4B-it-fp16-rope.litertlm"]
      .map(URL(fileURLWithPath: modelsDir).appendingPathComponent)
      .first { FileManager.default.fileExists(atPath: $0.path) }
  }

  private static func openLoopbackSocket(port: UInt16) -> Int32? {
    signal(SIGPIPE, SIG_IGN)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var reuse: Int32 = 1, addr = sockaddr_in()
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(fd, 32) == 0 else {
      note("bind/listen(127.0.0.1:\(port)) failed: errno \(errno)")
      close(fd)
      return nil
    }
    return fd
  }

  static func configureClientSocket(_ fd: Int32) {
    var noSigPipe: Int32 = 1, timeout = timeval(tv_sec: socketTimeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  }

  private static func acceptLoop(listenFD: Int32, engine: ServeEngine, modelID: String) async {
    while true {
      let clientFD = await withCheckedContinuation { continuation in
        httpIOQueue.async {
          var clientAddr = sockaddr_in(), addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
          let fd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(listenFD, $0, &addrLen) }
          }
          continuation.resume(returning: fd)
        }
      }
      if clientFD < 0 {
        if errno == EINTR { continue }
        break
      }
      configureClientSocket(clientFD)
      Task.detached(priority: .userInitiated) { await handleConnection(clientFD, engine: engine, modelID: modelID) }
    }
  }

  private static func handleConnection(_ fd: Int32, engine: ServeEngine, modelID: String) async {
    defer { close(fd) }
    let request: HTTPRequest
    switch await readHTTPRequest(fd) {
    case .request(let parsed): request = parsed
    case .payloadTooLarge: return writePayloadTooLarge(fd)
    case .badRequest(let msg):
      let (s, d) = ServeProtocol.errorResponse(status: 400, message: msg, type: "invalid_request_error")
      return writeRaw(fd, status: s, contentType: "application/json", body: d)
    case .closedOrInvalid: return
    }
    let cleanPath = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
    switch (request.method, cleanPath) {
    case ("GET", "/health"), ("GET", "/v1/health"):
      writeJSON(
        fd, status: 200,
        object: ServeProtocol.healthObject(
          modelID: modelID, allocatedPositions: engine.allocatedPositions, hasEmbedder: engine.hasEmbedder))
    case ("GET", "/v1/models"), ("GET", "/models"):
      let entry: [String: Any] = [
        "id": modelID, "object": "model", "created": Int(Date().timeIntervalSince1970),
        "owned_by": "agello", "max_model_len": engine.allocatedPositions,
      ]
      writeJSON(fd, status: 200, object: ["object": "list", "data": [entry]])
    case ("POST", "/tokenize"), ("POST", "/v1/tokenize"):
      let (s, d) = await engine.tokenizeEndpoint(requestData: request.body)
      writeRaw(fd, status: s, contentType: "application/json", body: d)
    case ("POST", "/reset"), ("POST", "/v1/reset"):
      let (s, d) = await engine.resetEndpoint()
      writeRaw(fd, status: s, contentType: "application/json", body: d)
    case ("POST", "/v1/embeddings"), ("POST", "/embeddings"):
      let (s, d) = await engine.embeddingsEndpoint(requestData: request.body)
      writeRaw(fd, status: s, contentType: "application/json", body: d)
    case ("POST", "/v1/chat/completions"), ("POST", "/chat/completions"):
      if ServeProtocol.wantsStreaming(requestData: request.body) {
        await engine.streamChatCompletion(requestData: request.body, fd: fd)
      } else {
        let (s, ct, d) = await engine.chatCompletion(requestData: request.body)
        writeRaw(fd, status: s, contentType: ct, body: d)
      }
    default:
      writeJSON(fd, status: 404, object: ["error": ["message": "Not found: \(cleanPath)", "type": "invalid_request_error"]])
    }
  }
}

// MARK: - Off-pool HTTP/1.1 reader, body limits & wire writers

extension Serve {
  static func writePayloadTooLarge(_ fd: Int32) {
    let (s, d) = ServeProtocol.errorResponse(
      status: 413, message: "Request body exceeds 64 MiB limit.", type: "invalid_request_error")
    writeRaw(fd, status: s, contentType: "application/json", body: d)
  }

  static func readHTTPRequest(_ fd: Int32) async -> HTTPReadOutcome {
    await withCheckedContinuation { cont in httpIOQueue.async { cont.resume(returning: readHTTPRequestSync(fd)) } }
  }

  static func readHTTPRequestSync(_ fd: Int32) -> HTTPReadOutcome {
    guard let (headerText, remainder) = readHeaderBlock(fd) else { return .closedOrInvalid }
    switch parseHeaders(headerText) {
    case .failure(let err): return err == .payloadTooLarge ? .payloadTooLarge : .badRequest(err.message)
    case .success(let headers): return readBody(fd, initial: remainder, headers: headers)
    }
  }

  private static func readHeaderBlock(_ fd: Int32) -> (String, Data)? {
    var buffer = Data(), chunk = [UInt8](repeating: 0, count: 65_536)
    let delimiter = Data("\r\n\r\n".utf8)
    while true {
      let n = Darwin.read(fd, &chunk, chunk.count)
      if n <= 0 { return nil }
      buffer.append(chunk, count: n)
      if let range = buffer.range(of: delimiter) {
        guard let text = String(data: buffer[..<range.lowerBound], encoding: .utf8) else { return nil }
        return (text, Data(buffer[range.upperBound...]))
      }
      if buffer.count > maxHeaderBytes { return nil }
    }
  }

  static func parseHeaders(_ headerText: String) -> Result<ParsedHeaders, HeaderParseError> {
    let lines = headerText.components(separatedBy: "\r\n")
    guard let parts = lines.first?.split(separator: " ", maxSplits: 2), parts.count >= 2 else {
      return .failure(.malformed)
    }
    var contentLength = 0, chunked = false, seenContentLength: Int?
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if key == "content-length" {
        guard !val.isEmpty, !val.hasPrefix("-"), val.allSatisfy({ $0.isASCII && $0.isNumber }) else {
          return .failure(.invalidContentLength)
        }
        guard let parsed64 = Int64(val), parsed64 <= Int64(maxRequestBodyBytes) else {
          return .failure(.payloadTooLarge)
        }
        let parsed = Int(parsed64)
        if let prev = seenContentLength, prev != parsed { return .failure(.invalidContentLength) }
        seenContentLength = parsed
        contentLength = parsed
      } else if key == "transfer-encoding", val.lowercased().contains("chunked") {
        chunked = true
      }
    }
    return .success(
      ParsedHeaders(
        method: String(parts[0]).uppercased(), path: String(parts[1]),
        contentLength: contentLength, chunked: chunked))
  }

  private static func readBody(_ fd: Int32, initial: Data, headers: ParsedHeaders) -> HTTPReadOutcome {
    var body = initial, chunk = [UInt8](repeating: 0, count: 65_536)
    if headers.chunked {
      let endMarker = Data("0\r\n\r\n".utf8), maxWireBytes = maxRequestBodyBytes + 1_048_576
      while !body.contains(endMarker) {
        if body.count > maxWireBytes { return .payloadTooLarge }
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        body.append(chunk, count: n)
      }
      switch decodeChunked(body, maxBytes: maxRequestBodyBytes) {
      case .success(let decoded):
        return .request(HTTPRequest(method: headers.method, path: headers.path, body: decoded))
      case .failure(.payloadTooLarge): return .payloadTooLarge
      case .failure: return .badRequest("Malformed chunked request body.")
      }
    }
    if headers.contentLength > maxRequestBodyBytes { return .payloadTooLarge }
    while body.count < headers.contentLength {
      let n = Darwin.read(fd, &chunk, min(chunk.count, headers.contentLength - body.count))
      if n <= 0 { break }
      body.append(chunk, count: n)
    }
    guard body.count >= headers.contentLength else { return .badRequest("Incomplete request body.") }
    let exact = body.count > headers.contentLength ? Data(body.prefix(headers.contentLength)) : body
    return .request(HTTPRequest(method: headers.method, path: headers.path, body: exact))
  }

  static func decodeChunked(_ raw: Data, maxBytes: Int = maxRequestBodyBytes) -> Result<Data, HeaderParseError> {
    var out = Data(), cursor = raw.startIndex
    let crlf = Data("\r\n".utf8)
    while cursor < raw.endIndex {
      guard let lineEnd = raw.range(of: crlf, in: cursor..<raw.endIndex),
        let sizeStr = String(data: raw[cursor..<lineEnd.lowerBound], encoding: .ascii)?
          .split(separator: ";").first?.trimmingCharacters(in: .whitespaces),
        !sizeStr.isEmpty, sizeStr.allSatisfy({ $0.isASCII && $0.isHexDigit })
      else { return .failure(.malformed) }
      guard let size64 = Int64(sizeStr, radix: 16) else { return .failure(.payloadTooLarge) }
      if size64 == 0 { return .success(out) }
      if size64 > Int64(maxBytes) || Int64(out.count) + size64 > Int64(maxBytes) {
        return .failure(.payloadTooLarge)
      }
      let size = Int(size64)
      cursor = lineEnd.upperBound
      guard cursor + size <= raw.endIndex else { return .failure(.malformed) }
      out.append(raw[cursor..<(cursor + size)])
      cursor = min(cursor + size + 2, raw.endIndex)
    }
    return .failure(.malformed)
  }

  static func httpReasonPhrase(for status: Int) -> String {
    [200: "OK", 400: "Bad Request", 404: "Not Found", 413: "Payload Too Large", 503: "Service Unavailable"][status]
      ?? "Internal Server Error"
  }

  static func writeJSON(_ fd: Int32, status: Int, object: Any) {
    writeRaw(
      fd, status: status, contentType: "application/json",
      body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8))
  }

  static func writeRaw(_ fd: Int32, status: Int, contentType: String, body: Data) {
    let header =
      "HTTP/1.1 \(status) \(httpReasonPhrase(for: status))\r\n"
      + "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    _ = writeBytes(fd, Data(header.utf8) + body)
  }

  @discardableResult
  static func writeSSEHeaders(_ fd: Int32) -> Bool {
    writeBytes(fd, Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n".utf8))
  }

  @discardableResult
  static func writeSSEObject(_ fd: Int32, _ object: [String: Any]) -> Bool {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object),
      let text = String(data: data, encoding: .utf8)
    else { return true }
    return writeBytes(fd, Data("data: \(text)\n\n".utf8))
  }

  @discardableResult
  static func writeBytes(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { rawBuf in
      guard let base = rawBuf.baseAddress else { return true }
      var written = 0
      while written < data.count {
        let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
        if n <= 0 {
          if n < 0 && errno == EINTR { continue }
          return false
        }
        written += n
      }
      return true
    }
  }
}

// MARK: - Serialized LiteRT-LM evaluation & simulator-bridge engine

private actor ServeEngine {
  private let engine: Engine
  private let options: Serve.Options
  let allocatedPositions: Int
  let hasEmbedder: Bool
  private let visualTokenBudget: Int32
  private let embedder: CoreAIEmbedder?
  private let turnQueue = ServeTurnQueue()
  private var cachedSession: ServeProtocol.CachedSession?
  private var requestCount = 0

  private init(
    engine: Engine, options: Serve.Options, allocatedPositions: Int, visualTokenBudget: Int32, embedder: CoreAIEmbedder?
  ) {
    self.engine = engine
    self.options = options
    self.allocatedPositions = allocatedPositions
    self.visualTokenBudget = visualTokenBudget
    self.embedder = embedder
    self.hasEmbedder = embedder != nil
  }

  static func load(modelURL: URL, modelsDir: String, options: Serve.Options) async throws -> ServeEngine {
    ExperimentalFlags.optIntoExperimentalAPIs()
    ExperimentalFlags.enableBenchmark = false
    ExperimentalFlags.filterChannelContentFromKvCache = true
    ExperimentalFlags.enableSpeculativeDecoding = options.allowMTP
    RuntimeTelemetry.recordSpans()
    let info = ModelInfo(modelPath: modelURL.path)
    let exportWindow = ContextBudget.exportWindow(reported: info?.maxContextTokens())
    let kv = min(options.kvTokens, exportWindow)
    let allocated = ContextBudget.allocatedPositions(requested: kv, exportWindow: exportWindow)
    let visionLimit = info?.maxVisionTokenBudget() ?? 280
    let visionBudget = Int32(visionLimit > 0 ? min(visionLimit, 280) : 280)
    let config = try EngineConfig(
      modelPath: modelURL.path, backend: .gpu, visionBackend: .gpu, audioBackend: .cpu(),
      maxNumTokens: kv, cacheDir: try EngineCache.directory())
    let engine = Engine(engineConfig: config)
    try await Task.detached(priority: .userInitiated) { try await engine.initialize() }.value
    let probe = try await engine.createConversation(with: ConversationConfig())
    _ = try await probe.sendMessage(LiteRTLM.Message("Hi"), maxOutputTokens: 1)
    let aneURL = URL(fileURLWithPath: modelsDir)
      .appendingPathComponent(CoreAIEmbedder.bundleDirectoryName, isDirectory: true)
    let embedder = CoreAIEmbedder.isAvailable(at: aneURL) ? CoreAIEmbedder(bundleURL: aneURL) : nil
    return ServeEngine(
      engine: engine, options: options, allocatedPositions: allocated, visualTokenBudget: visionBudget, embedder: embedder)
  }

  func tokenizeEndpoint(requestData: Data) async -> (Int, Data) {
    await turnQueue.run { await self.tokenizeSerialized(requestData: requestData) }
  }

  func resetEndpoint() async -> (Int, Data) { await turnQueue.run { await self.resetSerialized() } }

  func embeddingsEndpoint(requestData: Data) async -> (Int, Data) {
    guard let embedder else {
      return ServeProtocol.errorResponse(
        status: 503, message: "EmbeddingGemma ANE bundle not found in models directory.")
    }
    return await ServeProtocol.runEmbeddings(embedder: embedder, requestData: requestData)
  }

  func chatCompletion(requestData: Data) async -> (Int, String, Data) {
    await turnQueue.run { await self.chatCompletionSerialized(requestData: requestData) }
  }

  func streamChatCompletion(requestData: Data, fd: Int32) async {
    await turnQueue.run { await self.streamChatCompletionSerialized(requestData: requestData, fd: fd) }
  }

  private func tokenizeSerialized(requestData: Data) async -> (Int, Data) {
    await ServeProtocol.runTokenize(
      engine: engine, context: makeContext(), cachedSession: cachedSession, requestData: requestData)
  }

  private func resetSerialized() async -> (Int, Data) {
    if let existing = cachedSession {
      cachedSession = nil
      await ServeProtocol.drainConversation(existing.conversation)
    }
    return (200, (try? JSONSerialization.data(withJSONObject: ["status": "ok", "reset": true])) ?? Data("{}".utf8))
  }

  private func chatCompletionSerialized(requestData: Data) async -> (Int, String, Data) {
    requestCount += 1
    let prior = cachedSession
    cachedSession = nil
    let out = await ServeProtocol.runCompletion(
      engine: engine, context: makeContext(), cachedSession: prior, requestData: requestData)
    cachedSession = out.cachedSession
    return (out.status, out.contentType, out.body)
  }

  private func streamChatCompletionSerialized(requestData: Data, fd: Int32) async {
    requestCount += 1
    let prior = cachedSession
    cachedSession = nil
    cachedSession = await ServeProtocol.runStreamingCompletion(
      engine: engine, context: makeContext(), cachedSession: prior, requestData: requestData, fd: fd)
  }

  private func makeContext() -> ServeProtocol.ExecutionContext {
    .init(options: options, allocatedPositions: allocatedPositions, requestIndex: requestCount, visualTokenBudget: visualTokenBudget)
  }
}
