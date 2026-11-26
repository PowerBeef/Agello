import SwiftUI

/// Renders a markdown reply: headings, paragraphs, lists (nested, tasks),
/// code blocks with highlighting and copy, quotes, tables, display math.
struct MarkdownView: View {
  let document: MarkdownDocument
  /// Blocks from this index on are still streaming (the unfinished tail).
  private var openFrom = Int.max

  /// While `streaming`, each update parses only what it added: the finished blocks extend those
  /// of the update before (``MarkdownCache/streamingDocument(for:)``), and the unfinished rest is
  /// parsed on its own (``MarkdownStream``).
  init(_ text: String, streaming: Bool = false) {
    guard streaming else {
      document = MarkdownCache.document(for: text)
      return
    }
    let result = MarkdownCache.streamingDocument(for: text)
    document = result.document
    openFrom = result.openFrom
  }

  var body: some View {
    BlocksView(blocks: document.blocks, openFrom: openFrom)
      .foregroundStyle(Theme.Text.primary)
      .tint(Theme.Brand.glacier)
  }
}

/// Parsed documents by text, so unchanged messages aren't re-parsed on
/// every render (streaming replies change text and miss, by design).
@MainActor
enum MarkdownCache {
  private final class Box {
    let document: MarkdownDocument
    init(_ document: MarkdownDocument) { self.document = document }
  }
  private static let cache: NSCache<NSString, Box> = {
    let cache = NSCache<NSString, Box>()
    cache.countLimit = 200
    return cache
  }()

  /// The streaming reply's finished part and its latest full snapshot (one reply streams at a time).
  private static var streamed: (text: String, blocks: [MarkdownDocument.Block]) = ("", [])
  private static var streamedFull: (text: String, document: MarkdownDocument)?

  static func document(for text: String) -> MarkdownDocument {
    let key = text as NSString
    if let hit = cache.object(forKey: key) { return hit.document }
    if let full = streamedFull, full.text == text {
      cache.setObject(Box(full.document), forKey: key)
      clearStreamed()
      return full.document
    }
    if MarkdownStream.canReuseStablePrefix(streamed.text, for: text) {
      let start = text.utf8.index(text.startIndex, offsetBy: streamed.text.utf8.count)
      let tail = String(text[start...])
      let tailBlocks = tail.isEmpty ? [] : ReplyTrace.timed("markdown parse") { MarkdownDocument(parsing: tail).blocks }
      let document = MarkdownDocument(blocks: streamed.blocks + tailBlocks)
      cache.setObject(Box(document), forKey: key)
      clearStreamed()
      return document
    }
    let document = ReplyTrace.timed("markdown parse") { MarkdownDocument(parsing: text) }
    cache.setObject(Box(document), forKey: key)
    return document
  }

  /// Incrementally parses a streaming reply: only scans and parses text appended since the last
  /// committed stable cut, and records the latest snapshot so `streaming: true -> false` promotes
  /// straight into `cache` without re-parsing.
  static func streamingDocument(for text: String) -> (document: MarkdownDocument, openFrom: Int) {
    if let full = streamedFull, full.text == text {
      return (full.document, streamed.blocks.count)
    }
    let finished: [MarkdownDocument.Block]
    let tail: Substring
    if MarkdownStream.canReuseStablePrefix(streamed.text, for: text) {
      let start = text.utf8.index(text.startIndex, offsetBy: streamed.text.utf8.count)
      let remainder = String(text[start...])
      let split = MarkdownStream.stableSplit(remainder)
      if !split.prefix.isEmpty {
        let added = String(split.prefix)
        let addedBlocks = ReplyTrace.timed("markdown parse") { MarkdownDocument(parsing: added).blocks }
        streamed = (streamed.text + added, streamed.blocks + addedBlocks)
      }
      finished = streamed.blocks
      tail = split.tail
    } else {
      CodeHighlightCache.clearStreamed()
      let split = MarkdownStream.stableSplit(text)
      finished = finishedBlocks(of: String(split.prefix))
      tail = split.tail
    }
    let tailBlocks = tail.isEmpty ? [] : ReplyTrace.timed("markdown parse") { MarkdownDocument(parsing: String(tail)).blocks }
    let document = MarkdownDocument(blocks: finished + tailBlocks)
    streamedFull = (text, document)
    return (document, finished.count)
  }

  /// Blocks of a streaming reply's finished part (``MarkdownStream/stableSplit(_:)``). It only
  /// grows, at safe cuts, so the part added since the last update parses on its own.
  static func finishedBlocks(of prefix: String) -> [MarkdownDocument.Block] {
    if prefix.isEmpty {
      streamed = ("", [])
      return []
    }
    if prefix == streamed.text { return streamed.blocks }
    let blocks: [MarkdownDocument.Block]
    if !streamed.text.isEmpty, prefix.hasPrefix(streamed.text) {
      let start = prefix.utf8.index(prefix.startIndex, offsetBy: streamed.text.utf8.count)
      let added = String(prefix[start...])
      blocks = streamed.blocks + ReplyTrace.timed("markdown parse") { MarkdownDocument(parsing: added).blocks }
    } else {
      blocks = ReplyTrace.timed("markdown parse") { MarkdownDocument(parsing: prefix).blocks }
    }
    streamed = (prefix, blocks)
    return blocks
  }

  private static func clearStreamed() {
    streamed = ("", [])
    streamedFull = nil
  }
}

private struct BlocksView: View {
  let blocks: [MarkdownDocument.Block]
  /// Blocks from this index on are still streaming.
  var openFrom = Int.max

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
        // Unchanged blocks (all but the last while a reply streams) skip their bodies.
        BlockView(block: block, isOpen: index >= openFrom).equatable()
      }
    }
  }
}

private struct BlockView: View, Equatable {
  let block: MarkdownDocument.Block
  var isOpen = false

  var body: some View {
    switch block {
    case .heading(let level, let text):
      Text(text)
        .font(Self.headingFont(level))
        .padding(.top, level <= 2 ? 4 : 2)
        .accessibilityAddTraits(.isHeader)
    case .paragraph(let text):
      Text(text).lineSpacing(3)
    case .list(let ordered, let start, let items):
      ListBlockView(ordered: ordered, start: start, items: items)
    case .code(let language, let code):
      CodeBlockView(language: language, code: code, isOpen: isOpen)
    case .quote(let blocks):
      HStack(alignment: .top, spacing: Theme.Spacing.md) {
        Capsule()
          .fill(Theme.Brand.glacier.opacity(0.5))
          .frame(width: 3)
        BlocksView(blocks: blocks)
          .foregroundStyle(Theme.Text.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
    case .table(let header, let rows, let alignments):
      TableBlockView(header: header, rows: rows, alignments: alignments)
    case .math(let latex):
      MathBlockView(latex: latex)
    case .rule:
      Rectangle()
        .fill(Theme.Surface.stroke)
        .frame(height: Theme.Stroke.hairline)
        .padding(.vertical, Theme.Spacing.xs)
    }
  }

  static func headingFont(_ level: Int) -> Font {
    switch level {
    case 1: return .title2.bold()
    case 2: return .title3.bold()
    case 3: return .headline
    default: return .subheadline.bold()
    }
  }
}

private struct ListBlockView: View {
  let ordered: Bool
  let start: Int
  let items: [MarkdownDocument.ListItem]

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
          marker(index, item)
          BlocksView(blocks: item.blocks)
        }
      }
    }
  }

  @ViewBuilder
  private func marker(_ index: Int, _ item: MarkdownDocument.ListItem) -> some View {
    if let checked = item.checked {
      Image(systemName: checked ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(checked ? Theme.Status.healthy : Theme.Text.tertiary)
        .accessibilityLabel(checked ? "Done" : "Not done")
    } else {
      Text(ordered ? "\(start + index)." : "•")
        .monospacedDigit()
        .foregroundStyle(Theme.Text.tertiary)
    }
  }
}

struct CodeBlockView: View {
  let language: String?
  let code: String
  /// Still streaming: highlighted without being cached.
  var isOpen = false
  @State private var copied = false
  @State private var copyResetTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(language ?? "code")
          .font(.caption.monospaced())
          .foregroundStyle(Theme.Text.tertiary)
        Spacer()
        Button {
          Platform.copy(code)
          Haptics.complete()
          copyResetTask?.cancel()
          withAppAnimation(Theme.Motion.stateChange, kind: .dissolve) {
            copied = true
          }
          copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            withAppAnimation(Theme.Motion.stateChange, kind: .dissolve) {
              copied = false
            }
          }
        } label: {
          Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            .font(.system(.caption, weight: .medium))
            .foregroundStyle(Theme.Text.secondary)
            .contentTransition(.symbolEffect(.replace))
            .appAnimation(Theme.Motion.stateChange, value: copied, kind: .dissolve)
            .frame(minHeight: Theme.Size.glyph)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("code.copy")
      }
      .padding(.horizontal, Theme.Spacing.md)
      .padding(.vertical, Theme.Spacing.xxs)
      Rectangle().fill(Theme.Surface.hairline).frame(height: Theme.Stroke.hairline)
      ScrollView(.horizontal, showsIndicators: false) {
        // A long block is drawn in pieces: one Text past the GPU's largest texture draws nothing
        // (CodeHighlighter.linesPerPiece).
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(CodeHighlightCache.highlighted(code, language: language, keep: !isOpen).enumerated()), id: \.offset) {
            _, piece in
            // While a block streams only its last piece changes: the others keep their layout
            // and drawing instead of being laid out and drawn again ten times a second.
            CodePieceView(piece: piece).equatable()
          }
        }
        .padding(Theme.Spacing.md)
      }
    }
    .surfaceCard(radius: Theme.Radius.card, fill: Theme.Surface.card)
    .onDisappear {
      copyResetTask?.cancel()
      copyResetTask = nil
    }
    // A container keeps the Copy button's own identifier.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("message.code")
  }
}

/// One drawn piece of a code block (``CodeHighlighter/pieces(_:maxLines:)``).
private struct CodePieceView: View, Equatable {
  let piece: AttributedString

  var body: some View {
    Text(piece)
      .font(.callout.monospaced())
      .textSelection(.enabled)
      // Ideal size in both axes: inside a horizontal scroll view the
      // text would otherwise be clipped to a single line.
      .fixedSize()
  }
}

private struct TableBlockView: View {
  let header: [AttributedString]
  let rows: [[AttributedString]]
  let alignments: [MarkdownDocument.Alignment]
  @ScaledMetric(relativeTo: .callout) private var maxCellWidth: CGFloat = 240

  private var cappedCellWidth: CGFloat {
    min(maxCellWidth, 320)
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.lg, verticalSpacing: Theme.Spacing.sm) {
        GridRow {
          ForEach(Array(header.enumerated()), id: \.offset) { column, cell in
            Text(cell)
              .bold()
              .multilineTextAlignment(textAlignment(column))
              .frame(maxWidth: cappedCellWidth, alignment: frameAlignment(column))
              .fixedSize(horizontal: false, vertical: true)
              .gridColumnAlignment(alignment(column))
          }
        }
        Rectangle().fill(Theme.Surface.stroke).frame(height: Theme.Stroke.hairline)
          .gridCellUnsizedAxes(.horizontal)
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
          GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
              Text(cell)
                .multilineTextAlignment(textAlignment(column))
                .frame(maxWidth: cappedCellWidth, alignment: frameAlignment(column))
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
      .font(.callout)
      .padding(Theme.Spacing.md)
    }
    .surfaceCard(radius: Theme.Radius.card, fill: Theme.Surface.card)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("message.table")
  }

  private func alignment(_ column: Int) -> HorizontalAlignment {
    guard column < alignments.count else { return .leading }
    switch alignments[column] {
    case .leading: return .leading
    case .center: return .center
    case .trailing: return .trailing
    }
  }

  private func frameAlignment(_ column: Int) -> Alignment {
    guard column < alignments.count else { return .leading }
    switch alignments[column] {
    case .leading: return .leading
    case .center: return .center
    case .trailing: return .trailing
    }
  }

  private func textAlignment(_ column: Int) -> TextAlignment {
    guard column < alignments.count else { return .leading }
    switch alignments[column] {
    case .leading: return .leading
    case .center: return .center
    case .trailing: return .trailing
    }
  }
}

/// Display math typeset with SwiftMath; falls back to the LaTeX source.
private struct MathBlockView: View {
  let latex: String

  var body: some View {
    if MathLabel.canRender(latex) {
      ScrollView(.horizontal, showsIndicators: false) {
        MathLabel(latex: latex)
          .padding(.vertical, 4)
      }
      .accessibilityLabel(LaTeXText.unicode(latex))
      .accessibilityIdentifier("message.math")
    } else {
      Text(latex)
        .font(.callout.monospaced())
        .foregroundStyle(.secondary)
    }
  }
}
