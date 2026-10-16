import Foundation
import PDFKit
import UIKit
import UniformTypeIdentifiers
import Vision

/// What a file is, for icons, prompts, and how it was read.
enum DocumentKind: String, Codable, Sendable {
  case pdf, text, scan

  var symbol: String {
    switch self {
    case .pdf: return "doc.richtext"
    case .text: return "doc.text"
    case .scan: return "doc.viewfinder"
    }
  }
}

/// Text extracted from a file: one entry per page for paged documents
/// (PDFs, scans), a single entry otherwise.
struct ExtractedDocument: Sendable, Equatable {
  var name: String
  var kind: DocumentKind
  var byteCount: Int64
  var pages: [String]
  /// Passages, split during extraction (off the main thread); nil until ``prepared()``.
  var chunks: [ChunkDraft]?
  /// The text was longer than ``DocumentIngestor/maxExtractedCharacters`` and was cut.
  var truncated = false
  var isPaged: Bool { kind != .text }

  /// Caps the text and splits it into passages. Extraction calls it, so the work happens off
  /// the main thread.
  func prepared() -> ExtractedDocument {
    var document = self
    var budget = DocumentIngestor.maxExtractedCharacters
    var kept: [String] = []
    for page in pages {
      guard budget > 0 else {
        document.truncated = true
        break
      }
      let count = page.count
      if count <= budget {
        kept.append(page)
        budget -= count
      } else {
        kept.append(String(page.prefix(budget)))
        budget = 0
        document.truncated = true
      }
    }
    document.pages = kept
    document.chunks = Chunker.chunks(pages: kept, paged: isPaged)
    return document
  }

  var characterCount: Int { pages.reduce(0) { $0 + $1.count } }

  /// Stored text: pages separated by "[Page N]" markers when paged.
  var fullText: String {
    guard isPaged else { return pages.first ?? "" }
    return pages.enumerated()
      .map { "[Page \($0.offset + 1)]\n\($0.element)" }
      .joined(separator: "\n\n")
  }
}

enum IngestionError: LocalizedError, Equatable {
  case unsupported(String)
  case tooLarge(limitMB: Int)
  case unreadable(String)
  case noText(String)

  var errorDescription: String? {
    switch self {
    case .unsupported(let name): return "\(name) isn't a supported file type."
    case .tooLarge(let limit): return "Files up to \(limit) MB are supported."
    case .unreadable(let name): return "\(name) couldn't be read."
    case .noText(let name): return "No text was found in \(name)."
    }
  }
}

/// Reads PDFs, text-like files, RTF, and scanned pages into plain text.
/// Runs off the main actor (PDF parsing and OCR can take seconds).
enum DocumentIngestor {
  static let maxFileBytes: Int64 = 50_000_000
  /// Pages without a text layer are recognized with Vision, up to this many.
  static let maxOCRPages = 60
  /// Text kept from one file (about 1,250 passages); longer files are cut.
  static let maxExtractedCharacters = 2_000_000

  /// File types offered in the file picker.
  static let supportedTypes: [UTType] = {
    var types: [UTType] = [
      .pdf, .plainText, .utf8PlainText, .text, .sourceCode, .json, .commaSeparatedText,
      .tabSeparatedText, .xml, .yaml, .html, .rtf, .swiftSource, .pythonScript,
      .javaScript, .shellScript, .cSource, .cPlusPlusSource,
    ]
    for ext in ["md", "markdown", "log", "toml", "ini", "kt", "go", "rs", "ts", "tsx", "rb", "java"] {
      if let type = UTType(filenameExtension: ext) { types.append(type) }
    }
    return types
  }()

  static func extract(from url: URL) async throws -> ExtractedDocument {
    let name = url.lastPathComponent
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    guard size <= maxFileBytes else { throw IngestionError.tooLarge(limitMB: Int(maxFileBytes / 1_000_000)) }
    let type = UTType(filenameExtension: url.pathExtension) ?? .data

    let document: ExtractedDocument
    if type.conforms(to: .pdf) {
      document = try await extractPDF(url: url, name: name, size: size)
    } else if type.conforms(to: .rtf) {
      let attributed = try? NSAttributedString(
        url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil)
      guard let attributed else { throw IngestionError.unreadable(name) }
      document = ExtractedDocument(name: name, kind: .text, byteCount: size, pages: [attributed.string])
    } else if type.conforms(to: .text) || type.conforms(to: .sourceCode) || isTextData(url) {
      guard let data = try? Data(contentsOf: url), let text = decodeText(data) else {
        throw IngestionError.unreadable(name)
      }
      document = ExtractedDocument(name: name, kind: .text, byteCount: size, pages: [text])
    } else {
      throw IngestionError.unsupported(name)
    }
    guard document.pages.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    else { throw IngestionError.noText(name) }
    return document.prepared()
  }

  /// Pages photographed with the document scanner.
  static func extract(scannedPages images: [CGImage], name: String) async throws -> ExtractedDocument {
    var pages: [String] = []
    for image in images.prefix(maxOCRPages) {
      try Task.checkCancellation()
      pages.append(try await recognizeText(in: image))
    }
    let document = ExtractedDocument(name: name, kind: .scan, byteCount: 0, pages: pages)
    guard document.characterCount > 0 else { throw IngestionError.noText(name) }
    return document.prepared()
  }

  // MARK: - PDF

  private static func extractPDF(url: URL, name: String, size: Int64) async throws -> ExtractedDocument {
    guard let pdf = PDFDocument(url: url) else { throw IngestionError.unreadable(name) }
    guard !pdf.isLocked else { throw IngestionError.unreadable(name) }
    var pages: [String] = []
    var ocrPages = 0
    for index in 0..<pdf.pageCount {
      // A long scanned PDF takes minutes to read: stop when the read is cancelled.
      try Task.checkCancellation()
      guard let page = pdf.page(at: index) else {
        pages.append("")
        continue
      }
      var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      // No text layer (a scanned PDF): read the rendered page.
      if text.isEmpty, ocrPages < maxOCRPages, let image = render(page) {
        ocrPages += 1
        text = (try? await recognizeText(in: image)) ?? ""
      }
      pages.append(text)
    }
    return ExtractedDocument(name: name, kind: .pdf, byteCount: size, pages: pages)
  }

  private static func render(_ page: PDFPage) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    // ~200 dpi on letter-size pages: enough for OCR, bounded memory.
    let scale = min(2.8, 2_200 / max(bounds.width, bounds.height))
    let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    return page.thumbnail(of: size, for: .mediaBox).cgImage
  }

  // MARK: - OCR

  static func recognizeText(in image: CGImage) async throws -> String {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    let observations = try await request.perform(on: image)
    return observations
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
  }

  // MARK: - Text

  /// UTF-8 (with or without BOM), UTF-16, then Latin-1 as a last resort.
  static func decodeText(_ data: Data) -> String? {
    if let text = String(data: data, encoding: .utf8) { return text }
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
      let text = String(data: data, encoding: .utf16)
    {
      return text
    }
    return String(data: data, encoding: .isoLatin1)
  }

  /// Unknown extensions: treat as text when the first bytes contain no NULs.
  private static func isTextData(_ url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url),
      let head = try? handle.read(upToCount: 4_096)
    else { return false }
    try? handle.close()
    return !head.isEmpty && !head.contains(0)
  }
}
