import Foundation

/// Items shared from other apps (the share extension's inbox), answered in new chats.
extension AppState {
  /// Answers shared items one at a time, one pass at a time (launch and activation both ask).
  func answerSharedItems(inbox base: URL? = nil) async {
    guard !answeringSharedItems else { return }
    answeringSharedItems = true
    defer { answeringSharedItems = false }
    while await answerNextSharedItem(inbox: base) {}
  }

  /// Answer the oldest item shared to Agello (share sheet) in a new chat, removing it once it's
  /// sent. Returns false when there is nothing to do, a reply is running, or the send failed.
  @discardableResult
  func answerNextSharedItem(inbox base: URL? = nil) async -> Bool {
    guard !isBusy, let context = modelContext,
      let (item, file) = ShareInbox.pending(base: base).first(where: { !sharedItemsTried.contains($0.item.id) })
    else { return false }
    let thread = newThread(in: context)
    newChatProjectID = nil
    selectedThreadID = thread.id
    var question = ShareInbox.question(for: item)
    var files: [FileRecord] = []
    var image: Data?

    func attach(_ extracted: ExtractedDocument) {
      if let document = knowledge.add(extracted, threadID: thread.id) {
        files.append(
          FileRecord(
            id: document.id, name: document.name, kind: document.kindRaw,
            pageCount: document.pageCount))
      }
    }

    switch item.kind {
    case .file:
      if let file, let extracted = try? await DocumentIngestor.extract(from: file) {
        attach(extracted)
      } else {
        generationError = String(localized: "Agello couldn't read the shared file.")
      }
    case .image:
      if let file, let data = try? Data(contentsOf: file) { image = ImagePreparer.prepare(data) ?? data }
    case .url:
      let link = item.url.flatMap(URL.init(string:))
      if webSettings.allowed, let link, let page = await WebClient().readPage(link) {
        attach(
          ExtractedDocument(
            name: page.title ?? link.host() ?? link.absoluteString, kind: .text,
            byteCount: Int64(page.text.utf8.count), pages: [page.text]))
        question += "\n\n(\(link.absoluteString))"
      } else if let link {
        question += "\n\n\(link.absoluteString)"
      }
    case .text:
      let text = item.text ?? ""
      if text.count > ShareInbox.inlineTextLimit {
        attach(
          ExtractedDocument(
            name: String(localized: "Shared text"), kind: .text, byteCount: Int64(text.utf8.count),
            pages: [text]))
      } else if question != text {
        question += "\n\n\(text)"
      }
    }
    // Removed once it's sent: a send that fails leaves it for the next launch.
    guard await send(text: question, imageData: image, audioFileURL: nil, files: files, in: thread)
    else {
      sharedItemsTried.insert(item.id)
      for record in files {
        if let document = knowledge.documents(threadID: thread.id).first(where: { $0.id == record.id }) {
          knowledge.delete(document)
        }
      }
      return false
    }
    ShareInbox.remove(item.id, base: base)
    return true
  }
}
