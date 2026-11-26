import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Ask Agello" in the share sheet: shows what's shared, takes an optional
/// question, and saves both for the app (which answers when it's opened).
final class ShareViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
  private var model: ShareModel?

  override func viewDidLoad() {
    super.viewDidLoad()
    let model = ShareModel(context: extensionContext)
    self.model = model
    let host = UIHostingController(rootView: ShareView(model: model))
    addChild(host)
    host.view.frame = view.bounds
    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(host.view)
    host.didMove(toParent: self)
    model.startLoading()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    presentationController?.delegate = self
    parent?.presentationController?.delegate = self
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || isMovingFromParent {
      model?.cancelTasksAndCleanup()
    }
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    model?.cancel()
  }
}

@MainActor
@Observable
final class ShareModel {
  enum Phase: Equatable { case loading, ready, saving, saved, failed(String) }

  private enum LoadedFile: Sendable {
    case file(URL)
    case image(Data)
  }

  private enum ShareError: LocalizedError {
    case unsupported
    case tooLarge(limitMB: Int)

    var errorDescription: String? {
      switch self {
      case .unsupported:
        return String(localized: "Agello can't read this item.")
      case .tooLarge(let limitMB):
        return String(localized: "Files up to \(limitMB) MB are supported.")
      }
    }
  }

  /// Matches `DocumentIngestor.maxFileBytes` while staying safely under the 120 MB share
  /// extension jetsam ceiling.
  nonisolated static let maxDocumentBytes: Int64 = 50_000_000
  /// Source image files are subsampled directly on disk via `CGImageSourceCreateWithURL`.
  nonisolated static let maxImageSourceBytes: Int64 = 100_000_000
  private nonisolated static let tempFolderPrefix = "agello-share-"

  private nonisolated static let supportedDocumentTypes: [UTType] = {
    var types: [UTType] = [
      .pdf, .rtf, .sourceCode, .json, .commaSeparatedText, .tabSeparatedText, .xml, .yaml,
      .swiftSource, .pythonScript, .javaScript, .shellScript, .cSource, .cPlusPlusSource,
    ]
    for ext in ["md", "markdown", "log", "toml", "ini", "kt", "go", "rs", "ts", "tsx", "rb", "java"] {
      if let type = UTType(filenameExtension: ext) { types.append(type) }
    }
    return types
  }()

  private nonisolated static let supportedFileDocumentTypes: [UTType] =
    supportedDocumentTypes + [.plainText, .utf8PlainText, .text, .html]

  var phase: Phase = .loading
  var question = ""
  private(set) var preview = ""
  private(set) var symbol = "doc"
  private var item: ShareInbox.Item?
  private var file: URL?
  private var imageData: Data?
  private weak var context: NSExtensionContext?
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private var finished = false

  init(context: NSExtensionContext?) {
    self.context = context
  }

  func startLoading() {
    loadTask?.cancel()
    loadTask = Task { await load() }
  }

  func load() async {
    let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
    do {
      // Check images before documents/fileURLs so Photos shares (which often advertise both
      // UTType.image and UTType.fileURL) are streamed through ImageIO downsampling.
      if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) {
        let jpeg = try await loadDownsampledImage(provider)
        try Task.checkCancellation()
        imageData = jpeg
        item = ShareInbox.Item(kind: .image, question: "", fileName: "image.jpg")
        preview = String(localized: "Image")
        symbol = "photo"
      } else if let provider = providers.first(where: { isSupportedDocument($0) }) {
        let loaded = try await loadFile(provider)
        if Task.isCancelled {
          if case .file(let url) = loaded { Self.removeTempItem(at: url) }
          return
        }
        switch loaded {
        case .image(let jpeg):
          imageData = jpeg
          item = ShareInbox.Item(kind: .image, question: "", fileName: "image.jpg")
          preview = String(localized: "Image")
          symbol = "photo"
        case .file(let url):
          file = url
          item = ShareInbox.Item(kind: .file, question: "", fileName: url.lastPathComponent)
          preview = url.lastPathComponent
          symbol = "doc.richtext"
        }
      } else if let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
          && !$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
      }), let url = try await loadURL(provider) {
        try Task.checkCancellation()
        item = ShareInbox.Item(kind: .url, question: "", url: url.absoluteString)
        preview = url.host() ?? url.absoluteString
        symbol = "link"
      } else if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }),
        let text = try await loadText(provider)
      {
        try Task.checkCancellation()
        item = ShareInbox.Item(kind: .text, question: "", text: text)
        preview = String(text.prefix(140))
        symbol = "text.quote"
      } else {
        phase = .failed(String(localized: "Agello can't read this item."))
        return
      }
      phase = .ready
    } catch is CancellationError {
      removeTemporaryCopy()
    } catch {
      removeTemporaryCopy()
      phase = .failed(error.localizedDescription)
    }
  }

  func ask() {
    guard phase == .ready, var item else { return }
    item.question = question
    let itemToSave = item
    let fileURL = file
    let dataToSave = imageData
    phase = .saving
    saveTask?.cancel()
    saveTask = Task {
      do {
        try await Task.detached(priority: .userInitiated) {
          _ = try ShareInbox.save(itemToSave, file: fileURL, fileData: dataToSave)
        }.value
        guard !Task.isCancelled else { return }
        removeTemporaryCopy()
        phase = .saved
      } catch is CancellationError {
        // Dismissed while saving; temporary copy cleaned by cancelTasksAndCleanup.
      } catch {
        phase = .failed(String(localized: "Couldn't save the item for Agello."))
      }
    }
  }

  func cancel() {
    cancelTasksAndCleanup()
    guard !finished else { return }
    finished = true
    context?.cancelRequest(withError: CocoaError(.userCancelled))
  }

  func close() {
    cancelTasksAndCleanup()
    guard !finished else { return }
    finished = true
    context?.completeRequest(returningItems: nil)
  }

  func cancelTasksAndCleanup() {
    loadTask?.cancel()
    loadTask = nil
    saveTask?.cancel()
    saveTask = nil
    removeTemporaryCopy()
  }

  /// The copy ``loadFile(_:)`` made in the extension's temporary folder.
  private func removeTemporaryCopy() {
    guard let file else { return }
    Self.removeTempItem(at: file)
    self.file = nil
  }

  private nonisolated static func removeTempItem(at file: URL) {
    let tempPath = FileManager.default.temporaryDirectory.path
    guard file.path.hasPrefix(tempPath) else { return }
    let parent = file.deletingLastPathComponent()
    if parent.lastPathComponent.hasPrefix(tempFolderPrefix), parent.path.hasPrefix(tempPath) {
      try? FileManager.default.removeItem(at: parent)
    } else {
      try? FileManager.default.removeItem(at: file)
    }
  }

  private func isSupportedDocument(_ provider: NSItemProvider) -> Bool {
    let types = provider.registeredContentTypes
    if types.contains(where: { type in
      Self.supportedDocumentTypes.contains { type.conforms(to: $0) }
    }) {
      return true
    }
    guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
      return false
    }
    let blocked: [UTType] = [.movie, .audio, .archive, .folder, .package]
    return !types.contains { type in blocked.contains { type.conforms(to: $0) } }
  }

  private nonisolated static func isAllowedDocumentFile(url: URL, type: UTType?) -> Bool {
    let resolved = type ?? UTType(filenameExtension: url.pathExtension)
    if let resolved {
      if resolved.conforms(to: .movie) || resolved.conforms(to: .audio)
        || resolved.conforms(to: .archive) || resolved.conforms(to: .folder)
        || resolved.conforms(to: .package)
      {
        return false
      }
      if supportedFileDocumentTypes.contains(where: { resolved.conforms(to: $0) }) {
        return true
      }
    }
    // Unknown extension: allow only small plain text files without NUL bytes.
    guard let handle = try? FileHandle(forReadingFrom: url),
      let head = try? handle.read(upToCount: 4_096)
    else { return false }
    try? handle.close()
    return !head.isEmpty && !head.contains(0)
  }

  /// Streams a shared image from its on-disk representation via `CGImageSourceCreateWithURL` so
  /// 48 MP / ProRAW images never decode full bitmaps or full buffers into extension RAM.
  private func loadDownsampledImage(_ provider: NSItemProvider) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadFileRepresentation(for: .image, openInPlace: false) { url, _, error in
        guard let url else {
          continuation.resume(throwing: error ?? CocoaError(.fileReadCorruptFile))
          return
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= Self.maxImageSourceBytes else {
          continuation.resume(
            throwing: ShareError.tooLarge(limitMB: Int(Self.maxImageSourceBytes / 1_000_000)))
          return
        }
        guard let jpeg = Self.downsampleImage(at: url, maxPixels: 1_568) else {
          continuation.resume(throwing: CocoaError(.fileReadCorruptFile))
          return
        }
        continuation.resume(returning: jpeg)
      }
    }
  }

  private nonisolated static func downsampleImage(at url: URL, maxPixels: Int) -> Data? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixels,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      return nil
    }
    return ImageDownsampler.jpeg(cgImage)
  }

  /// Copy the shared file somewhere that outlives the provider's callback, enforcing a safe file
  /// size cap and handling `.fileURL`-only providers as well as concrete document UTTypes.
  private func loadFile(_ provider: NSItemProvider) async throws -> LoadedFile {
    let concreteDocType = provider.registeredContentTypes.first { type in
      !type.conforms(to: .url)
        && Self.supportedFileDocumentTypes.contains { type.conforms(to: $0) }
    }
    if let type = concreteDocType {
      return try await loadFileRepresentation(provider, type: type)
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      guard let url = try await loadURL(provider, identifier: UTType.fileURL.identifier), url.isFileURL else {
        throw ShareError.unsupported
      }
      return try await Task.detached(priority: .userInitiated) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try Self.processFileURL(url)
      }.value
    }
    throw ShareError.unsupported
  }

  private func loadFileRepresentation(
    _ provider: NSItemProvider, type: UTType
  ) async throws -> LoadedFile {
    try await withCheckedThrowingContinuation { continuation in
      _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
        guard let url else {
          continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile))
          return
        }
        do {
          continuation.resume(returning: try Self.processFileURL(url))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private nonisolated static func processFileURL(_ url: URL) throws -> LoadedFile {
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values.isRegularFile != false else { throw ShareError.unsupported }
    let size = Int64(values.fileSize ?? 0)
    let fileType = UTType(filenameExtension: url.pathExtension)
    if let fileType, fileType.conforms(to: .image) {
      guard size <= maxImageSourceBytes else {
        throw ShareError.tooLarge(limitMB: Int(maxImageSourceBytes / 1_000_000))
      }
      guard let jpeg = downsampleImage(at: url, maxPixels: 1_568) else {
        throw CocoaError(.fileReadCorruptFile)
      }
      return .image(jpeg)
    }
    guard isAllowedDocumentFile(url: url, type: fileType) else { throw ShareError.unsupported }
    guard size <= maxDocumentBytes else {
      throw ShareError.tooLarge(limitMB: Int(maxDocumentBytes / 1_000_000))
    }
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent(tempFolderPrefix + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let safeName = ShareInbox.safeName(url.lastPathComponent) ?? "shared-file"
    let copy = dir.appendingPathComponent(safeName)
    try FileManager.default.copyItem(at: url, to: copy)
    return .file(copy)
  }

  private func loadURL(
    _ provider: NSItemProvider, identifier: String = UTType.url.identifier
  ) async throws -> URL? {
    let item = try await provider.loadItem(forTypeIdentifier: identifier)
    if let url = item as? URL { return url }
    if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
    if let text = item as? String { return URL(string: text) }
    return nil
  }

  private func loadText(_ provider: NSItemProvider) async throws -> String? {
    let item = try await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
    if let text = item as? String { return text }
    if let data = item as? Data { return String(data: data, encoding: .utf8) }
    return nil
  }
}

/// Agello's dark palette mirrored locally so the Share Extension stays decoupled from app-only types.
private enum SharePalette {
  static let canvas = Color(red: 0.086, green: 0.094, blue: 0.137)
  static let canvasBottom = Color(red: 0.038, green: 0.044, blue: 0.056)
  static let group = Color.white.opacity(0.05)
  static let hairline = Color(red: 0.97, green: 0.92, blue: 0.82, opacity: 0.08)
  static let glacier = Color(red: 0.541, green: 0.690, blue: 0.784)
  static let healthy = Color(red: 0.55, green: 0.70, blue: 0.55)
  static let critical = Color(red: 0.85, green: 0.50, blue: 0.50)
  static let text = Color(red: 0.95, green: 0.94, blue: 0.92)
  static let secondary = Color(red: 0.78, green: 0.76, blue: 0.72)
  static let tertiary = Color(red: 0.62, green: 0.60, blue: 0.55)
  static let placeholder = Color(red: 0.60, green: 0.63, blue: 0.68)
}

struct ShareView: View {
  @Bindable var model: ShareModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var focused: Bool

  var body: some View {
    NavigationStack {
      Form {
        switch model.phase {
        case .loading:
          HStack(spacing: 12) {
            ProgressView()
              .tint(SharePalette.glacier)
              .accessibilityLabel("Loading shared item")
            Text("Loading…")
              .foregroundStyle(SharePalette.secondary)
          }
          .listRowBackground(SharePalette.group)
          .listRowSeparatorTint(SharePalette.hairline)
        case .saving:
          HStack(spacing: 12) {
            ProgressView()
              .tint(SharePalette.glacier)
            Text("Saving for Agello…")
              .foregroundStyle(SharePalette.secondary)
          }
          .listRowBackground(SharePalette.group)
          .listRowSeparatorTint(SharePalette.hairline)
        case .failed(let message):
          HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(SharePalette.critical)
              .accessibilityHidden(true)
            Text(message)
              .foregroundStyle(SharePalette.critical)
          }
          .listRowBackground(SharePalette.group)
          .listRowSeparatorTint(SharePalette.hairline)
        case .ready:
          Section {
            Label {
              Text(model.preview)
                .foregroundStyle(SharePalette.text)
                .lineLimit(3)
            } icon: {
              Image(systemName: model.symbol)
                .foregroundStyle(SharePalette.glacier)
            }
          }
          .listRowBackground(SharePalette.group)
          .listRowSeparatorTint(SharePalette.hairline)
          Section {
            TextField(
              "Ask about this… (optional)", text: $model.question,
              prompt: Text("Ask about this… (optional)").foregroundStyle(SharePalette.placeholder),
              axis: .vertical
            )
            .foregroundStyle(SharePalette.text)
            .lineLimit(1...5)
            .focused($focused)
          } footer: {
            Text("Agello answers on this iPhone when you open it.")
              .foregroundStyle(SharePalette.tertiary)
          }
          .listRowBackground(SharePalette.group)
          .listRowSeparatorTint(SharePalette.hairline)
        case .saved:
          Section {
            HStack(spacing: 10) {
              Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(SharePalette.healthy)
                .transition(.symbolEffect(.drawOn))
                .accessibilityHidden(true)
              Text("Saved for Agello")
                .foregroundStyle(SharePalette.text)
            }
          } footer: {
            Text("Open Agello to see the answer.")
              .foregroundStyle(SharePalette.tertiary)
          }
          .listRowBackground(SharePalette.group)
          .listRowSeparatorTint(SharePalette.hairline)
        }
      }
      .scrollContentBackground(.hidden)
      .background {
        ZStack {
          LinearGradient(
            colors: [SharePalette.canvas, SharePalette.canvasBottom],
            startPoint: .top, endPoint: .bottom)
          RadialGradient(
            colors: [SharePalette.glacier.opacity(0.20), .clear],
            center: .top, startRadius: 0, endRadius: 260)
        }
        .ignoresSafeArea()
      }
      .animation(
        reduceMotion ? .easeInOut(duration: 0.18) : .smooth(duration: 0.22),
        value: model.phase)
      .navigationTitle("Ask Agello")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if model.phase != .saved {
            Button("Cancel") { model.cancel() }
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          if model.phase == .saved {
            Button("Done") { model.close() }
          } else {
            Button("Ask") {
              focused = false
              model.ask()
            }
            .disabled(model.phase != .ready)
          }
        }
      }
      .onChange(of: model.phase, initial: true) { _, phase in
        focused = phase == .ready
      }
    }
    .tint(SharePalette.glacier)
    .preferredColorScheme(.dark)
  }
}
