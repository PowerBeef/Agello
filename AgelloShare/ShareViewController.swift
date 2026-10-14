import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Ask iRTChat" in the share sheet: shows what's shared, takes an optional
/// question, and saves both for the app (which answers when it's opened).
final class ShareViewController: UIViewController {
  override func viewDidLoad() {
    super.viewDidLoad()
    let model = ShareModel(context: extensionContext)
    let host = UIHostingController(rootView: ShareView(model: model))
    addChild(host)
    host.view.frame = view.bounds
    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(host.view)
    host.didMove(toParent: self)
    Task { await model.load() }
  }
}

@MainActor
@Observable
final class ShareModel {
  enum Phase: Equatable { case loading, ready, saved, failed(String) }

  var phase: Phase = .loading
  var question = ""
  private(set) var preview = ""
  private(set) var symbol = "doc"
  private var item: ShareInbox.Item?
  private var file: URL?
  private var imageData: Data?
  private weak var context: NSExtensionContext?

  init(context: NSExtensionContext?) {
    self.context = context
  }

  func load() async {
    let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    do {
      if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) || isDocument($0) }) {
        let url = try await loadFile(provider)
        file = url
        item = ShareInbox.Item(kind: .file, question: "", fileName: url.lastPathComponent)
        preview = url.lastPathComponent
        symbol = "doc.richtext"
      } else if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
        let data = try await loadData(provider, type: .image)
        guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) else {
          throw CocoaError(.fileReadCorruptFile)
        }
        imageData = jpeg
        item = ShareInbox.Item(kind: .image, question: "", fileName: "image.jpg")
        preview = String(localized: "Image")
        symbol = "photo"
      } else if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }),
        let url = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL
      {
        item = ShareInbox.Item(kind: .url, question: "", url: url.absoluteString)
        preview = url.host() ?? url.absoluteString
        symbol = "link"
      } else if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }),
        let text = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String
      {
        item = ShareInbox.Item(kind: .text, question: "", text: text)
        preview = String(text.prefix(140))
        symbol = "text.quote"
      } else {
        phase = .failed(String(localized: "iRTChat can't read this item."))
        return
      }
      phase = .ready
    } catch {
      phase = .failed(error.localizedDescription)
    }
  }

  func ask() {
    guard var item else { return }
    item.question = question
    do {
      try ShareInbox.save(item, file: file, fileData: imageData)
      phase = .saved
    } catch {
      phase = .failed(String(localized: "Couldn't save the item for iRTChat."))
    }
  }

  func close() {
    context?.completeRequest(returningItems: nil)
  }

  private func isDocument(_ provider: NSItemProvider) -> Bool {
    provider.registeredContentTypes.contains {
      $0.conforms(to: .fileURL) || $0.conforms(to: .pdf) || $0.conforms(to: .rtf)
        || ($0.conforms(to: .data) && !$0.conforms(to: .image) && !$0.conforms(to: .url)
          && !$0.conforms(to: .plainText))
    }
  }

  private func loadData(_ provider: NSItemProvider, type: UTType) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadDataRepresentation(for: type) { data, error in
        if let data {
          continuation.resume(returning: data)
        } else {
          continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
        }
      }
    }
  }

  /// Copy the shared file somewhere that outlives the provider's callback.
  private func loadFile(_ provider: NSItemProvider) async throws -> URL {
    let type = provider.registeredContentTypes.first { !$0.conforms(to: .url) } ?? .data
    return try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
        guard let url else {
          continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile))
          return
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: copy)
        do {
          try FileManager.default.copyItem(at: url, to: copy)
          continuation.resume(returning: copy)
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}

struct ShareView: View {
  @Bindable var model: ShareModel
  @FocusState private var focused: Bool

  var body: some View {
    NavigationStack {
      Form {
        switch model.phase {
        case .loading:
          ProgressView()
        case .failed(let message):
          Text(message).foregroundStyle(.secondary)
        case .ready:
          Section {
            Label(model.preview, systemImage: model.symbol)
              .lineLimit(3)
          }
          Section {
            TextField("Ask about this… (optional)", text: $model.question, axis: .vertical)
              .lineLimit(1...5)
              .focused($focused)
          } footer: {
            Text("iRTChat answers on this iPhone when you open it.")
          }
        case .saved:
          Section {
            Label("Saved for iRTChat", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          } footer: {
            Text("Open iRTChat to see the answer.")
          }
        }
      }
      .navigationTitle("Ask iRTChat")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if model.phase != .saved {
            Button("Cancel") { model.close() }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          if model.phase == .saved {
            Button("Done") { model.close() }
          } else {
            Button("Ask") { model.ask() }
              .disabled(model.phase != .ready)
          }
        }
      }
      .onAppear { focused = true }
    }
  }
}
