import PDFKit
import UIKit
import XCTest

@testable import Agello

final class IngestionTests: XCTestCase {
  /// Minified JSON or a log without line breaks: cutting it used to recount the rest of the
  /// text for every piece (quadratic, on the main thread). 5 MB must take seconds, not minutes.
  func testHugeSingleLineTextChunksInLinearTime() {
    let text = String(repeating: "abcdefghij", count: 500_000)
    let started = ContinuousClock.now
    let chunks = Chunker.chunks(pages: [text], paged: false)
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    XCTAssertEqual(chunks.count, 3_125)
    XCTAssertTrue(chunks.allSatisfy { $0.text.count <= Chunker.targetCharacters })
  }

  /// A cut prefers a space in the piece's second half.
  func testLongSentencesBreakAtSpaces() {
    let words = Array(repeating: "lighthouse", count: 400).joined(separator: " ")
    let chunks = Chunker.chunks(pages: [words], paged: false)
    XCTAssertGreaterThan(chunks.count, 1)
    for chunk in chunks { XCTAssertFalse(chunk.text.hasPrefix(" ") || chunk.text.hasSuffix(" ")) }
    XCTAssertTrue(chunks.allSatisfy { $0.text.split(separator: " ").allSatisfy { $0 == "lighthouse" } })
  }

  func testExtractedTextIsCappedAndSplitDuringExtraction() {
    let big = String(repeating: "a b ", count: 600_000)
    let prepared = ExtractedDocument(name: "big.txt", kind: .text, byteCount: 0, pages: [big]).prepared()
    XCTAssertEqual(prepared.pages.first?.count, DocumentIngestor.maxExtractedCharacters)
    XCTAssertTrue(prepared.truncated)
    XCTAssertFalse(prepared.chunks?.isEmpty ?? true)
  }

  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("IngestionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
  }

  // MARK: - Chunker

  func testShortDocumentIsOneChunk() {
    let chunks = Chunker.chunks(pages: ["Hello.\n\nSecond paragraph."], paged: false)
    XCTAssertEqual(chunks.count, 1)
    XCTAssertEqual(chunks[0].text, "Hello.\n\nSecond paragraph.")
    XCTAssertNil(chunks[0].pageStart)
  }

  func testChunksTrackPagesAndKeepEveryParagraph() {
    let paragraph = String(repeating: "word ", count: 80).trimmingCharacters(in: .whitespaces)  // ~400 chars
    let pages = (1...6).map { page in
      (1...3).map { "P\(page)-\($0) " + paragraph }.joined(separator: "\n\n")
    }
    let chunks = Chunker.chunks(pages: pages, paged: true)
    XCTAssertGreaterThan(chunks.count, 3)
    XCTAssertEqual(chunks.map(\.index), Array(0..<chunks.count))
    XCTAssertTrue(chunks.allSatisfy { $0.text.count <= Chunker.targetCharacters + 450 })
    // Every paragraph appears somewhere, in order, with its page.
    for page in 1...6 {
      for n in 1...3 {
        let marker = "P\(page)-\(n) "
        let holder = chunks.first { $0.text.contains(marker) }
        XCTAssertNotNil(holder, marker)
        XCTAssertTrue((holder!.pageStart!...holder!.pageEnd!).contains(page), marker)
      }
    }
    XCTAssertEqual(chunks.first?.pageStart, 1)
    XCTAssertEqual(chunks.last?.pageEnd, 6)
  }

  func testNeighbouringChunksOverlap() {
    let paragraphs = (1...12).map { "Paragraph \($0). " + String(repeating: "x", count: 150) }
    let chunks = Chunker.chunks(pages: [paragraphs.joined(separator: "\n\n")], paged: false)
    XCTAssertGreaterThan(chunks.count, 1)
    for (a, b) in zip(chunks, chunks.dropFirst()) {
      let lastParagraph = a.text.components(separatedBy: "\n\n").last!
      XCTAssertTrue(b.text.hasPrefix(lastParagraph), "No overlap between \(a.index) and \(b.index)")
    }
  }

  func testLongParagraphIsSplitIntoSentencesAndWrapped() {
    let sentence = "This is a sentence about lighthouses and their keepers. "
    let long = String(repeating: sentence, count: 80)  // ~4,500 chars, one paragraph
    let chunks = Chunker.chunks(pages: [long], paged: false)
    XCTAssertGreaterThan(chunks.count, 2)
    XCTAssertTrue(chunks.allSatisfy { $0.text.count <= Chunker.targetCharacters + 100 })
    let unbroken = String(repeating: "a", count: 5_000)
    XCTAssertTrue(
      Chunker.chunks(pages: [unbroken], paged: false).allSatisfy {
        $0.text.count <= Chunker.targetCharacters
      })
  }

  func testEmptyPagesProduceNoChunks() {
    XCTAssertTrue(Chunker.chunks(pages: ["", "  \n\n "], paged: true).isEmpty)
  }

  // MARK: - Extraction

  func testPDFTextIsExtractedPerPage() async throws {
    let url = directory.appendingPathComponent("report.pdf")
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
    try renderer.writePDF(to: url) { context in
      for page in 1...3 {
        context.beginPage()
        ("Quarterly report page \(page). Revenue grew in region \(page)." as NSString)
          .draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
      }
    }
    let document = try await DocumentIngestor.extract(from: url)
    XCTAssertEqual(document.kind, .pdf)
    XCTAssertEqual(document.pages.count, 3)
    XCTAssertTrue(document.pages[1].contains("page 2"), document.pages[1])
    XCTAssertTrue(document.fullText.contains("[Page 3]"))
  }

  func testTextAndCodeFiles() async throws {
    let markdown = directory.appendingPathComponent("notes.md")
    try "# Notes\n\nBuy milk.".write(to: markdown, atomically: true, encoding: .utf8)
    let notes = try await DocumentIngestor.extract(from: markdown)
    XCTAssertEqual(notes.kind, .text)
    XCTAssertEqual(notes.pages, ["# Notes\n\nBuy milk."])

    let swift = directory.appendingPathComponent("main.swift")
    try "print(\"hi\")".write(to: swift, atomically: true, encoding: .utf8)
    let code = try await DocumentIngestor.extract(from: swift)
    XCTAssertEqual(code.fullText, "print(\"hi\")")
  }

  func testBinaryAndEmptyFilesAreRejected() async throws {
    let binary = directory.appendingPathComponent("blob.bin")
    try Data([0x00, 0x01, 0x02, 0x00]).write(to: binary)
    do {
      _ = try await DocumentIngestor.extract(from: binary)
      XCTFail("Binary accepted")
    } catch let error as IngestionError {
      XCTAssertEqual(error, .unsupported("blob.bin"))
    }
    let empty = directory.appendingPathComponent("empty.txt")
    try "  \n".write(to: empty, atomically: true, encoding: .utf8)
    do {
      _ = try await DocumentIngestor.extract(from: empty)
      XCTFail("Empty accepted")
    } catch let error as IngestionError {
      XCTAssertEqual(error, .noText("empty.txt"))
    }
  }

  func testLatin1FallbackDecoding() {
    let data = "café".data(using: .isoLatin1)!
    XCTAssertEqual(DocumentIngestor.decodeText(data), "café")
  }

  /// Text files in the encodings people save them in: Windows-1252 quotes, UTF-16, a UTF-8 BOM,
  /// Shift-JIS and GB18030.
  func testTextEncodingsAreDetected() throws {
    let quotes = "“Smart quotes” – café, naïve, 5 €"
    XCTAssertEqual(TextDecoding.decode(try XCTUnwrap(quotes.data(using: .windowsCP1252))), quotes)
    XCTAssertEqual(TextDecoding.decode(try XCTUnwrap(quotes.data(using: .utf16))), quotes)
    XCTAssertEqual(TextDecoding.decode(Data([0xEF, 0xBB, 0xBF]) + Data(quotes.utf8)), quotes)
    let japanese = String(repeating: "今日は良い天気ですね。東京の桜が満開になりました。", count: 8)
    XCTAssertEqual(TextDecoding.decode(try XCTUnwrap(japanese.data(using: .shiftJIS))), japanese)
    let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
      CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    let chinese = String(repeating: "今天天气很好，我们去公园散步吧。", count: 8)
    XCTAssertEqual(TextDecoding.decode(try XCTUnwrap(chinese.data(using: gb18030)), declared: "gb18030"), chinese)
  }

  func testHTMLCharsetDeclarations() {
    XCTAssertEqual(TextDecoding.htmlCharset(in: Data(#"<html><head><meta charset="windows-1252">"#.utf8)), "windows-1252")
    XCTAssertEqual(
      TextDecoding.htmlCharset(
        in: Data(#"<meta http-equiv="Content-Type" content="text/html; charset=Shift_JIS">"#.utf8)),
      "Shift_JIS")
    XCTAssertNil(TextDecoding.htmlCharset(in: Data("<html><body>No charset</body></html>".utf8)))
    XCTAssertEqual(TextDecoding.encoding(ianaName: "ISO-8859-1"), .windowsCP1252)
    XCTAssertEqual(TextDecoding.encoding(ianaName: "utf-8"), .utf8)
  }

  /// A saved web page is read for its text: no markup, scripts or comments.
  func testHTMLFilesAreReadForTheirText() async throws {
    let url = directory.appendingPathComponent("page.html")
    let html = """
      <html><head><meta charset="windows-1252"><title>Harbour news</title>
      <script>
        var tracking = "secret";
      </script></head>
      <body><!-- a
      multi-line comment --><p>The council approved the renovation of the pier,
      a project that residents have asked for since the storm damaged it two winters ago,
      with work to begin in spring and to end before the summer ferry season.</p></body></html>
      """
    try XCTUnwrap(html.data(using: .windowsCP1252)).write(to: url)
    let document = try await DocumentIngestor.extract(from: url)
    XCTAssertTrue(document.fullText.hasPrefix("Harbour news"), document.fullText)
    XCTAssertTrue(document.fullText.contains("approved the renovation of the pier"))
    for leak in ["tracking", "secret", "<p>", "comment"] {
      XCTAssertFalse(document.fullText.contains(leak), "Kept '\(leak)': \(document.fullText)")
    }
  }

  /// A password-protected PDF says so instead of "couldn't be read".
  func testLockedPDFsSayTheyAreLocked() async throws {
    let plain = directory.appendingPathComponent("plain.pdf")
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
    try renderer.writePDF(to: plain) { context in
      context.beginPage()
      ("Confidential salary table." as NSString)
        .draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
    }
    let locked = directory.appendingPathComponent("locked.pdf")
    let pdf = try XCTUnwrap(PDFDocument(url: plain))
    XCTAssertTrue(
      pdf.write(to: locked, withOptions: [.userPasswordOption: "1234", .ownerPasswordOption: "5678"]))
    do {
      _ = try await DocumentIngestor.extract(from: locked)
      XCTFail("A locked PDF was read")
    } catch let error as IngestionError {
      XCTAssertEqual(error, .locked("locked.pdf"))
    }
  }

  func testOCRReadsRenderedText() async throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 2
    let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 160), format: format).image { ctx in
      UIColor.white.setFill()
      ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 160))
      ("Invoice total 1234 dollars" as NSString).draw(
        at: CGPoint(x: 20, y: 50),
        withAttributes: [.font: UIFont.systemFont(ofSize: 36), .foregroundColor: UIColor.black])
    }
    let document = try await DocumentIngestor.extract(scannedPages: [image.cgImage!], name: "Scan")
    XCTAssertEqual(document.kind, .scan)
    XCTAssertTrue(document.pages[0].contains("1234"), document.pages[0])
  }
}

extension IngestionTests {
  func testSubstantialPassagesEndAtPageBreaks() {
    let page = String(repeating: "A sentence of reasonable length here. ", count: 25)  // ~950 chars
    let chunks = Chunker.chunks(pages: [page, page, page], paged: true)
    XCTAssertEqual(chunks.map(\.pageStart), [1, 2, 3])
    XCTAssertEqual(chunks.map(\.pageEnd), [1, 2, 3])
  }
}
