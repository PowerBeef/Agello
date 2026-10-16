import XCTest

@testable import Agello

final class MarkdownTests: XCTestCase {
  private func blocks(_ text: String) -> [MarkdownDocument.Block] {
    MarkdownDocument(parsing: text).blocks
  }

  private func plain(_ text: AttributedString) -> String { String(text.characters) }

  // MARK: Streaming

  /// A reply as it streams: the stable part and the tail, parsed apart, give the blocks of
  /// parsing the whole text, at every point of the reply.
  func testStreamedPartsParseLikeTheWhole() {
    let reply = """
      ## Plan

      First paragraph with **bold** and `code`.

      1. One
      2. Two

      3. Three after a blank line

      - item
        - nested

      ```swift
      let a = 1

      let b = 2
      ```

      | A | B |
      |---|---|
      | 1 | 2 |

      $$
      x = 1

      y = 2
      $$

      > Quote line

      > Second quote

      Setext heading
      ==============

      Last words.
      """
    var cuts = 0
    for end in reply.indices where reply[end] == "\n" || reply[end] == " " {
      let text = String(reply[..<end])
      let (prefix, tail) = MarkdownStream.stableSplit(text)
      if !prefix.isEmpty { cuts += 1 }
      let streamed = blocks(String(prefix)) + blocks(String(tail))
      XCTAssertEqual(streamed, blocks(text), "Split at \(prefix.count) of \(text.count) changed the blocks")
    }
    XCTAssertGreaterThan(cuts, 20, "The stable part never grows")
  }

  /// The streaming view extends the finished blocks of the update before; every update shows
  /// what a whole parse of its text gives.
  @MainActor
  func testStreamingUpdatesMatchWholeParses() {
    let reply = String(
      repeating: "## Part\n\nText with **bold**.\n\n- a\n- b\n\n```\ncode\n\nmore\n```\n\n", count: 6)
    var end = reply.startIndex
    while end < reply.endIndex {
      end = reply.index(end, offsetBy: 7, limitedBy: reply.endIndex) ?? reply.endIndex
      let text = String(reply[..<end])
      XCTAssertEqual(MarkdownView(text, streaming: true).document, MarkdownDocument(parsing: text), "\(text.count)")
    }
    // Another reply starting over doesn't reuse the last one's blocks.
    XCTAssertEqual(MarkdownView("New reply\n\nok", streaming: true).document, MarkdownDocument(parsing: "New reply\n\nok"))
  }

  func testNoCutInsideFencesMathOrBeforeAContinuation() {
    XCTAssertEqual(MarkdownStream.stableSplit("```\nlet a = 1\n\nlet b").prefix, "")
    XCTAssertEqual(MarkdownStream.stableSplit("$$\nx\n\ny").prefix, "")
    XCTAssertEqual(MarkdownStream.stableSplit("1. a\n\n2. b").prefix, "")
    XCTAssertEqual(MarkdownStream.stableSplit("Para one.\n\nPara two").prefix, "Para one.\n\n")
    XCTAssertEqual(MarkdownStream.stableSplit("Para one.\n\n").prefix, "")
  }

  func testHeadingsParagraphsAndInlineStyles() {
    let result = blocks("# Title\n\nSome **bold**, *italic*, `code` and [a link](https://example.com).")
    guard case .heading(1, let title) = result.first, case .paragraph(let body) = result.last else {
      return XCTFail("\(result)")
    }
    XCTAssertEqual(plain(title), "Title")
    XCTAssertEqual(plain(body), "Some bold, italic, code and a link.")
    let bold = body.runs.first { plain(AttributedString(body[$0.range])) == "bold" }
    XCTAssertEqual(bold?.inlinePresentationIntent, .stronglyEmphasized)
    let code = body.runs.first { plain(AttributedString(body[$0.range])) == "code" }
    XCTAssertEqual(code?.inlinePresentationIntent, .code)
    let link = body.runs.first { plain(AttributedString(body[$0.range])) == "a link" }
    XCTAssertEqual(link?.link, URL(string: "https://example.com"))
  }

  func testNestedListsAndTasks() {
    let result = blocks("1. First\n2. Second\n   - nested\n\n- [x] done\n- [ ] todo")
    guard case .list(true, 1, let items) = result.first else { return XCTFail("\(result)") }
    XCTAssertEqual(items.count, 2)
    XCTAssertTrue(items[1].blocks.contains { if case .list(false, _, _) = $0 { return true }; return false })
    guard case .list(false, _, let tasks) = result.last else { return XCTFail("\(result)") }
    XCTAssertEqual(tasks.map(\.checked), [true, false])
  }

  func testCodeBlockKeepsLanguageAndContent() {
    let result = blocks("```Python\nprint(\"$5 and $x$\")\n```")
    XCTAssertEqual(result, [.code(language: "python", code: "print(\"$5 and $x$\")")])
  }

  func testTable() {
    let result = blocks("| Name | Size |\n| :--- | ---: |\n| E4B | 3.7 GB |")
    guard case .table(let header, let rows, let alignments) = result.first else {
      return XCTFail("\(result)")
    }
    XCTAssertEqual(header.map(plain), ["Name", "Size"])
    XCTAssertEqual(rows.first?.map(plain), ["E4B", "3.7 GB"])
    XCTAssertEqual(alignments, [.leading, .trailing])
  }

  func testDisplayMathIsSplitOut() {
    let result = blocks("Area:\n\n$$\nA = \\pi r^2\n$$\n\nDone.")
    XCTAssertEqual(result.count, 3)
    XCTAssertEqual(result[1], .math(latex: "A = \\pi r^2"))
    XCTAssertEqual(blocks("\\[ x^2 + y^2 = z^2 \\]"), [.math(latex: "x^2 + y^2 = z^2")])
  }

  func testDisplayMathInsideCodeFenceIsNotMath() {
    let result = blocks("```\n$$\nnot math\n$$\n```")
    guard case .code = result.first else { return XCTFail("\(result)") }
    XCTAssertEqual(result.count, 1)
  }

  func testUnclosedDisplayMathWhileStreamingStaysText() {
    let result = blocks("Let\n$$\nx = \\frac{1}{2")
    XCTAssertFalse(result.contains { if case .math = $0 { return true }; return false })
  }

  func testInlineMathBecomesReadableText() {
    guard case .paragraph(let text) = blocks("So $17 \\times 23 = 391$ and $x^2 \\le 4$.").first else {
      return XCTFail()
    }
    XCTAssertEqual(plain(text), "So 17 × 23 = 391 and x² ≤ 4.")
  }

  func testCurrencyIsNotMath() {
    guard case .paragraph(let text) = blocks("It costs $5 and $10 today.").first else { return XCTFail() }
    XCTAssertEqual(plain(text), "It costs $5 and $10 today.")
  }

  func testInlineCodeDollarIsUntouched() {
    guard case .paragraph(let text) = blocks("Use `$x$` literally.").first else { return XCTFail() }
    XCTAssertEqual(plain(text), "Use $x$ literally.")
  }

  func testLaTeXTransliteration() {
    XCTAssertEqual(LaTeXText.unicode("\\frac{a}{b}"), "a/b")
    XCTAssertEqual(LaTeXText.unicode("\\sqrt{2}"), "√(2)")
    XCTAssertEqual(LaTeXText.unicode("x_{10} + y^{n}"), "x₁₀ + yⁿ")
    XCTAssertEqual(LaTeXText.unicode("\\text{cost} = 5"), "cost = 5")
    XCTAssertEqual(LaTeXText.unicode("e^{xy}"), "e^(xy)")
  }

  func testPartialMarkdownWhileStreaming() {
    // An unclosed fence must render as code, not crash or drop text.
    let result = blocks("Here:\n```swift\nlet x = 1")
    XCTAssertEqual(result.last, .code(language: "swift", code: "let x = 1"))
  }

  // MARK: Highlighter

  func testHighlighterTokens() {
    let tokens = CodeHighlighter.tokens("let x = \"hi\" // note\nreturn 42", language: "swift")
    XCTAssertTrue(tokens.contains(.init(kind: .keyword, text: "let")))
    XCTAssertTrue(tokens.contains(.init(kind: .string, text: "\"hi\"")))
    XCTAssertTrue(tokens.contains(.init(kind: .comment, text: "// note")))
    XCTAssertTrue(tokens.contains(.init(kind: .keyword, text: "return")))
    XCTAssertTrue(tokens.contains(.init(kind: .number, text: "42")))
    XCTAssertEqual(tokens.map(\.text).joined(), "let x = \"hi\" // note\nreturn 42")
  }

  func testHighlighterPythonComments() {
    let tokens = CodeHighlighter.tokens("def f():  # comment\n    return None", language: "python")
    XCTAssertTrue(tokens.contains(.init(kind: .comment, text: "# comment")))
    XCTAssertTrue(tokens.contains(.init(kind: .keyword, text: "None")))
  }

  func testIdentifiersWithDigitsAreNotNumbers() {
    let tokens = CodeHighlighter.tokens("var1 = 2", language: nil)
    XCTAssertFalse(tokens.contains(.init(kind: .number, text: "1")))
    XCTAssertTrue(tokens.contains(.init(kind: .number, text: "2")))
  }
}

extension MarkdownTests {
  func testMockSampleCodeBlockKeepsBothLines() {
    let text = MockChatEngine.markdownSample.map(\.textDelta).joined()
    let code = MarkdownDocument(parsing: text).blocks.compactMap { block -> String? in
      if case .code(_, let code) = block { return code }
      return nil
    }.first
    XCTAssertEqual(code?.components(separatedBy: "\n").count, 2, String(describing: code))
    let rendered = String(CodeHighlighter.highlight(code ?? "", language: "swift").characters)
    XCTAssertEqual(rendered, code)
  }
}

extension MarkdownTests {
  func testPlainTextForReadingAloud() {
    let document = MarkdownDocument(
      parsing: "## Plan\n\n- **Buy** milk\n- Call [Sam](https://x.y)\n\n```swift\nlet x = 1\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |")
    XCTAssertEqual(document.plainText, "Plan\nBuy milk\nCall Sam\nA, B\n1, 2")
  }
}
