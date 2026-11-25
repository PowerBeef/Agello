import Darwin
import Foundation
import LiteRTLM

/// Unshipped local-only OpenAI `/v1` HTTP server for running external evaluation harnesses
/// (such as `gbench --remote-endpoint http://127.0.0.1:PORT/v1`) directly against Agello's
/// Metal 4 LiteRT-LM runtime and v2 model. Binds strictly to `127.0.0.1`.
enum Serve {
  struct Options: Sendable {
    var port: UInt16 = 8091
    var modelID = "google/gemma-4-E4B-it"
    var kvTokens = 65_536
    var thinkByDefault = false
    var thinkingBudget = DeviceProfile.defaultThinkingBudget
    var allowMTP = true
  }

  static func main(_ arguments: inout Arguments, paths: [String: String]) async -> Int32 {
    let opts: Options
    do {
      opts = try parseOptions(&arguments)
    } catch {
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
      serverEngine = try await ServeEngine.load(modelURL: modelURL, options: opts)
    } catch {
      note("Failed to load engine: \(error)")
      return 1
    }

    guard let listenFD = openLoopbackSocket(port: opts.port) else { return 1 }
    defer { close(listenFD) }

    let modelID = opts.modelID
    note(
      "agello serve ready on http://127.0.0.1:\(opts.port)/v1 "
        + "(model=\(modelID), kv=\(serverEngine.allocatedPositions), "
        + "mtp=\(opts.allowMTP), build=\(EngineCache.runtimeBuildID))"
    )

    await acceptLoop(listenFD: listenFD, engine: serverEngine, modelID: modelID)
    return 0
  }

  private struct UsageError: Error {
    let message: String
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
    let dir = URL(fileURLWithPath: modelsDir)
    let primary = dir.appendingPathComponent(ModelCatalog.e4b.fileName)
    if FileManager.default.fileExists(atPath: primary.path) { return primary }
    let fallback = dir.appendingPathComponent("gemma-4-E4B-it-fp16-rope.litertlm")
    return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
  }

  // MARK: - Loopback HTTP/1.1 transport

  private static func openLoopbackSocket(port: UInt16) -> Int32? {
    signal(SIGPIPE, SIG_IGN)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else {
      note("socket() failed: errno \(errno)")
      return nil
    }
    var reuse: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else {
      note("bind(127.0.0.1:\(port)) failed: errno \(errno)")
      close(fd)
      return nil
    }
    guard listen(fd, 32) == 0 else {
      note("listen() failed: errno \(errno)")
      close(fd)
      return nil
    }
    return fd
  }

  private static func acceptLoop(listenFD: Int32, engine: ServeEngine, modelID: String) async {
    while true {
      let clientFD = await Task.detached(priority: .userInitiated) {
        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        return withUnsafeMutablePointer(to: &clientAddr) { ptr in
          ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.accept(listenFD, $0, &addrLen)
          }
        }
      }.value
      if clientFD < 0 {
        if errno == EINTR { continue }
        break
      }
      Task.detached(priority: .userInitiated) {
        await handleConnection(clientFD, engine: engine, modelID: modelID)
      }
    }
  }

  private struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let body: Data
  }

  private struct ParsedHeaders {
    let method: String
    let path: String
    let contentLength: Int
    let chunked: Bool
  }

  private static func handleConnection(_ fd: Int32, engine: ServeEngine, modelID: String) async {
    defer { close(fd) }
    guard let request = readHTTPRequest(fd) else { return }
    let cleanPath =
      request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path

    switch (request.method, cleanPath) {
    case ("GET", "/health"), ("GET", "/v1/health"):
      writeJSON(fd, status: 200, object: ["status": "ok"])
    case ("GET", "/v1/models"), ("GET", "/models"):
      writeJSON(
        fd, status: 200,
        object: [
          "object": "list",
          "data": [
            [
              "id": modelID,
              "object": "model",
              "created": Int(Date().timeIntervalSince1970),
              "owned_by": "agello",
              "max_model_len": engine.allocatedPositions,
            ]
          ],
        ]
      )
    case ("POST", "/tokenize"), ("POST", "/v1/tokenize"):
      let (status, payload) = await engine.tokenizeEndpoint(requestData: request.body)
      writeRaw(fd, status: status, contentType: "application/json", body: payload)
    case ("POST", "/v1/chat/completions"), ("POST", "/chat/completions"):
      let (status, contentType, payload) = await engine.chatCompletion(requestData: request.body)
      writeRaw(fd, status: status, contentType: contentType, body: payload)
    default:
      writeJSON(
        fd, status: 404,
        object: ["error": ["message": "Not found: \(cleanPath)", "type": "invalid_request_error"]])
    }
  }

  private static func readHTTPRequest(_ fd: Int32) -> HTTPRequest? {
    guard let (headerText, remainder) = readHeaderBlock(fd),
      let headers = parseHeaders(headerText)
    else { return nil }
    let body = readBody(fd, initial: remainder, headers: headers)
    return HTTPRequest(method: headers.method, path: headers.path, body: body)
  }

  private static func readHeaderBlock(_ fd: Int32) -> (String, Data)? {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 65_536)
    let delimiter = Data("\r\n\r\n".utf8)
    while true {
      let n = Darwin.read(fd, &chunk, chunk.count)
      if n <= 0 { return nil }
      buffer.append(chunk, count: n)
      if let range = buffer.range(of: delimiter) {
        guard let text = String(data: buffer[..<range.lowerBound], encoding: .utf8) else {
          return nil
        }
        return (text, Data(buffer[range.upperBound...]))
      }
      if buffer.count > 1_048_576 { return nil }
    }
  }

  private static func parseHeaders(_ headerText: String) -> ParsedHeaders? {
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let parts = requestLine.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2 else { return nil }

    var contentLength = 0
    var chunked = false
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if key == "content-length", let n = Int(val) { contentLength = n }
      if key == "transfer-encoding", val.lowercased().contains("chunked") { chunked = true }
    }
    return ParsedHeaders(
      method: String(parts[0]).uppercased(), path: String(parts[1]),
      contentLength: contentLength, chunked: chunked)
  }

  private static func readBody(_ fd: Int32, initial: Data, headers: ParsedHeaders) -> Data {
    var body = initial
    var chunk = [UInt8](repeating: 0, count: 65_536)
    if headers.chunked {
      let endMarker = Data("0\r\n\r\n".utf8)
      while !body.contains(endMarker) && body.count <= 64 * 1024 * 1024 {
        let n = Darwin.read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        body.append(chunk, count: n)
      }
      return decodeChunked(body)
    }
    while body.count < headers.contentLength {
      let remaining = min(chunk.count, headers.contentLength - body.count)
      let n = Darwin.read(fd, &chunk, remaining)
      if n <= 0 { break }
      body.append(chunk, count: n)
    }
    return body.count > headers.contentLength ? Data(body.prefix(headers.contentLength)) : body
  }

  private static func decodeChunked(_ raw: Data) -> Data {
    var out = Data()
    var cursor = raw.startIndex
    let crlf = Data("\r\n".utf8)
    while cursor < raw.endIndex {
      guard let lineEnd = raw.range(of: crlf, in: cursor..<raw.endIndex),
        let sizeStr = String(data: raw[cursor..<lineEnd.lowerBound], encoding: .ascii)?
          .split(separator: ";").first?.trimmingCharacters(in: .whitespaces),
        let size = Int(sizeStr, radix: 16)
      else { break }
      cursor = lineEnd.upperBound
      if size == 0 { break }
      let end = min(cursor + size, raw.endIndex)
      out.append(raw[cursor..<end])
      cursor = min(end + 2, raw.endIndex)
    }
    return out
  }

  private static func writeJSON(_ fd: Int32, status: Int, object: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    writeRaw(fd, status: status, contentType: "application/json", body: data)
  }

  private static func writeRaw(_ fd: Int32, status: Int, contentType: String, body: Data) {
    let reason: String
    switch status {
    case 200: reason = "OK"
    case 400: reason = "Bad Request"
    case 404: reason = "Not Found"
    default: reason = "Internal Server Error"
    }
    let header =
      "HTTP/1.1 \(status) \(reason)\r\n"
      + "Content-Type: \(contentType)\r\n"
      + "Content-Length: \(body.count)\r\n"
      + "Connection: close\r\n\r\n"
    var response = Data(header.utf8)
    response.append(body)
    response.withUnsafeBytes { rawBuf in
      guard let base = rawBuf.baseAddress else { return }
      var written = 0
      while written < response.count {
        let n = Darwin.write(fd, base.advanced(by: written), response.count - written)
        if n <= 0 { break }
        written += n
      }
    }
  }
}

// MARK: - Serialized LiteRT-LM evaluation engine

private actor ServeEngine {
  private let engine: Engine
  private let options: Serve.Options
  let allocatedPositions: Int
  private let visualTokenBudget: Int32
  private var requestCount = 0

  private init(
    engine: Engine, options: Serve.Options, allocatedPositions: Int, visualTokenBudget: Int32
  ) {
    self.engine = engine
    self.options = options
    self.allocatedPositions = allocatedPositions
    self.visualTokenBudget = visualTokenBudget
  }

  static func load(modelURL: URL, options: Serve.Options) async throws -> ServeEngine {
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
      modelPath: modelURL.path,
      backend: .gpu,
      visionBackend: .gpu,
      audioBackend: .cpu(),
      maxNumTokens: kv,
      cacheDir: try EngineCache.directory()
    )
    let engine = Engine(engineConfig: config)
    try await Task.detached(priority: .userInitiated) {
      try await engine.initialize()
    }.value

    // Validate the initialized engine with a 1-token probe, matching ChatEngine.swift.
    let probe = try await engine.createConversation(with: ConversationConfig())
    _ = try await probe.sendMessage(LiteRTLM.Message("Hi"), maxOutputTokens: 1)

    return ServeEngine(
      engine: engine, options: options, allocatedPositions: allocated,
      visualTokenBudget: visionBudget)
  }

  func tokenizeEndpoint(requestData: Data) async -> (Int, Data) {
    guard let json = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
      let prompt = (json["prompt"] as? String) ?? (json["text"] as? String)
    else {
      return ServeProtocol.errorResponse(status: 400, message: "Expected JSON with 'prompt' string.")
    }
    do {
      let ids = try await engine.tokenize(prompt)
      let data = try JSONSerialization.data(withJSONObject: ["tokens": ids, "count": ids.count])
      return (200, data)
    } catch {
      return ServeProtocol.errorResponse(status: 500, message: "tokenize failed: \(error)")
    }
  }

  func chatCompletion(requestData: Data) async -> (Int, String, Data) {
    requestCount += 1
    let context = ServeProtocol.ExecutionContext(
      options: options,
      allocatedPositions: allocatedPositions,
      visualTokenBudget: visualTokenBudget,
      requestIndex: requestCount
    )
    return await ServeProtocol.runCompletion(
      engine: engine, context: context, requestData: requestData)
  }
}
