import Foundation

/// What `ask` attaches to its first message, read the way the chat screen reads it: files
/// through ``DocumentIngestor``, an image scaled by ``ImagePreparer``, a voice message as the
/// app records them.
struct Attachments {
  var files: [ExtractedDocument] = []
  var image: Data?
  var audio: URL?

  init(_ arguments: inout Arguments) async throws(UsageError) {
    for path in arguments.values("file") {
      let url = URL(fileURLWithPath: Setup.expand(path))
      do {
        files.append(try await DocumentIngestor.extract(from: url))
      } catch {
        throw UsageError("\(path) couldn't be read as a document: \(error.localizedDescription)")
      }
    }
    if let path = arguments.value("image") {
      guard let data = FileManager.default.contents(atPath: Setup.expand(path)),
        let prepared = ImagePreparer.prepare(data)
      else { throw UsageError("\(path) couldn't be read as an image.") }
      image = prepared
    }
    if let path = arguments.value("audio") {
      let url = URL(fileURLWithPath: Setup.expand(path))
      guard FileManager.default.fileExists(atPath: url.path) else { throw UsageError("\(path) isn't there.") }
      audio = url
    }
  }
}

/// Ctrl-C as the Stop button: the first stops the reply and keeps its text, the second quits.
@MainActor
final class StopSignal {
  private let source: any DispatchSourceSignal
  private var count = 0

  init(onStop: @escaping @MainActor () -> Void) {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    self.source = source
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.count += 1
        if self.count > 1 { exit(130) }
        note("\nStopping (Ctrl-C again to quit)…")
        onStop()
      }
    }
    source.resume()
  }

  func cancel() {
    source.cancel()
    signal(SIGINT, SIG_DFL)
  }
}
