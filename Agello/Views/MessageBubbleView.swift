import SwiftUI

/// What a message can do. Closures are supplied by the chat screen.
struct MessageActions {
  /// A reply is being generated in this chat: branch-changing actions wait.
  var isBusy = false
  var isSpeaking = false
  var canRegenerate = false
  var regenerate: () -> Void = {}
  var edit: () -> Void = {}
  var speak: () -> Void = {}
  var selectVersion: (ChatTurn) -> Void = { _ in }
}

/// One chat message. The user's turns sit on a raised warm surface; the
/// model's are full-width text with quiet accessories (reasoning, sources,
/// tools, actions). Color stays in the content layer: no glass here.
struct MessageBubbleView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let turn: ChatTurn
  var isStreaming: Bool = false
  /// What a tool is doing right now (live reply only).
  var toolStatus: String? = nil
  /// All versions of this turn (edits / regenerations), oldest first.
  var versions: [ChatTurn] = []
  /// Time to first token, speed and backend under the reply.
  var showsStats = false
  var actions = MessageActions()
  @State private var copied = false
  @State private var showsThought = false
  @State private var showsSources = false

  var body: some View {
    if turn.isUser {
      userBubble
    } else {
      modelBlock
    }
  }

  // MARK: - User

  private var userBubble: some View {
    HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
      Spacer(minLength: Theme.Spacing.xxxl + Theme.Spacing.lg)
      VStack(alignment: .trailing, spacing: Theme.Spacing.tight) {
        ForEach(turn.parts.files) { file in
          FileChip(record: file)
        }
        if let data = turn.imageData, let image = UIImage(data: data) {
          Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 220)
            .clipShape(.rect(cornerRadius: Theme.Radius.group, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
                .stroke(Theme.Surface.stroke, lineWidth: Theme.Stroke.hairline)
            }
            .accessibilityLabel("Photo")
        }
        if turn.hasAudio {
          Label("Voice message", systemImage: "waveform")
            .font(.callout)
            .foregroundStyle(Theme.Text.primary)
            .bubbleChrome()
            .accessibilityIdentifier("message.voice")
        }
        if !turn.text.isEmpty {
          Text(turn.text)
            .foregroundStyle(Theme.Text.primary)
            .bubbleChrome()
            .accessibilityIdentifier("message.user")
            .contextMenu {
              Button("Copy", systemImage: "doc.on.doc") { copy(turn.text) }
              Button("Edit", systemImage: "pencil", action: actions.edit)
                .disabled(actions.isBusy)
            }
        }
        if versions.count > 1 {
          versionSwitcher
        }
      }
    }
  }

  // MARK: - Model

  private var modelBlock: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      if isStreaming, let toolStatus {
        HStack(spacing: Theme.Spacing.tight) {
          ProgressView().controlSize(.mini)
          Text(toolStatus)
            .font(.footnote)
            .foregroundStyle(Theme.Text.secondary)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("message.toolStatus")
      }
      if !turn.thought.isEmpty {
        thoughtCard
      }
      if !turn.text.isEmpty {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
          MarkdownView(
            WebContext.linkCitations(turn.text, sources: turn.parts.sources), streaming: isStreaming)
            .textSelection(.enabled)
          if isStreaming {
            streamingCursor
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(Self.spokenText(turn.text)))
        .accessibilityIdentifier("message.model")
      } else if isStreaming {
        thinkingDots
      }
      if !turn.toolNames.isEmpty {
        toolChips
      }
      if !isStreaming, !turn.text.isEmpty {
        let parts = turn.parts
        if !parts.sources.isEmpty {
          sourcesCard(parts.sources)
        }
        if let memory = parts.toolActivity.last(where: { $0.name == "memory" }) {
          Label("Memory updated", systemImage: "brain.head.profile")
            .font(.footnote)
            .foregroundStyle(Theme.Text.tertiary)
            .accessibilityValue(memory.summary)
            .accessibilityIdentifier("message.memory")
        }
        actionRow
      }
      if showsStats, let stats = turn.stats {
        Text(stats.footerLine)
          .font(.caption2)
          .monospacedDigit()
          .foregroundStyle(Theme.Text.tertiary)
          .accessibilityIdentifier("message.stats")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// VoiceOver reads the reply, not its markdown syntax.
  static func spokenText(_ markdown: String) -> String {
    var text = markdown
    for token in ["**", "__", "`", "#"] {
      text = text.replacingOccurrences(of: token, with: "")
    }
    return text.replacingOccurrences(of: #"\[(\d+)\]"#, with: "", options: .regularExpression)
  }

  // MARK: - Reasoning

  /// Quiet card above the answer; collapsed to two lines of the thought.
  private var thoughtCard: some View {
    let tint = Theme.Mode.think.tint
    return Button {
      withAppAnimation(Theme.Motion.easeOut) { showsThought.toggle() }
      Haptics.selection()
    } label: {
      VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
        HStack(spacing: Theme.Spacing.tight) {
          Image(systemName: "lightbulb.fill").font(.caption2)
          Text("Reasoning").eyebrowStyle(tint)
          Spacer()
          Image(systemName: "chevron.down")
            .font(.caption2.weight(.semibold))
            .rotationEffect(.degrees(showsThought ? 180 : 0))
        }
        .foregroundStyle(tint)
        Text(turn.thought)
          .font(.footnote)
          .foregroundStyle(Theme.Text.secondary)
          .lineLimit(showsThought ? nil : 2)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("message.reasoning.text")
      }
      .padding(Theme.Spacing.md)
      .surfaceCard(
        radius: Theme.Radius.card, fill: Theme.accentSurface(tint).opacity(0.6),
        stroke: tint.opacity(0.18))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .accessibilityElement(children: .contain)
    .accessibilityHint(showsThought ? "Collapses the reasoning" : "Shows all of the reasoning")
    .accessibilityIdentifier("message.reasoning")
  }

  // MARK: - Sources

  private func sourcesCard(_ sources: [SourceRecord]) -> some View {
    let tint = Theme.Mode.search.tint
    return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      Button {
        withAppAnimation(Theme.Motion.easeOut) { showsSources.toggle() }
        Haptics.selection()
      } label: {
        HStack(spacing: Theme.Spacing.tight) {
          Image(systemName: "doc.text.magnifyingglass")
          Text(sources.count == 1 ? "1 source" : "\(sources.count) sources")
          Image(systemName: "chevron.down")
            .font(.caption2.weight(.semibold))
            .rotationEffect(.degrees(showsSources ? 180 : 0))
        }
        .font(.system(.footnote, weight: .medium))
        .foregroundStyle(Theme.Text.secondary)
        .padding(.horizontal, Theme.Spacing.md)
        .frame(minHeight: Theme.Size.pill)
        .background { QuietBackground(shape: Capsule()) }
        .contentShape(Capsule())
      }
      .buttonStyle(.plain)
      .frame(minHeight: Theme.Size.target)
      if showsSources {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(sources) { source in
            sourceRow(source, tint: tint)
            if source.id != sources.last?.id {
              Rectangle().fill(Theme.Surface.hairline).frame(height: Theme.Stroke.hairline)
                .padding(.leading, Theme.Spacing.md)
            }
          }
        }
        .surfaceCard(radius: Theme.Radius.card)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("message.sources")
  }

  @ViewBuilder
  private func sourceRow(_ source: SourceRecord, tint: Color) -> some View {
    let row = HStack(alignment: .top, spacing: Theme.Spacing.snug) {
      Text("\(source.index)")
        .font(.system(.caption2, weight: .bold))
        .monospacedDigit()
        .foregroundStyle(tint)
        .frame(width: 20, height: 20)
        .background { Circle().fill(tint.opacity(0.14)) }
      VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
        Text(source.title)
          .font(.system(.footnote, weight: .semibold))
          .foregroundStyle(Theme.Text.primary)
          .lineLimit(2)
        if let host = source.url.flatMap(URL.init(string:))?.host() {
          Text(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
            .font(.caption2)
            .foregroundStyle(tint)
        }
        if let snippet = source.snippet {
          Text(snippet)
            .font(.caption)
            .foregroundStyle(Theme.Text.tertiary)
            .lineLimit(2)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(Theme.Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    if let link = source.url.flatMap(URL.init(string:)) {
      Link(destination: link) { row }
        .accessibilityIdentifier("message.source")
    } else {
      row
    }
  }

  // MARK: - Tools

  private var toolChips: some View {
    HStack(spacing: Theme.Spacing.tight) {
      ForEach(turn.toolNames, id: \.self) { name in
        Label(Self.toolLabel(name), systemImage: Self.toolSymbol(name))
          .font(.system(.caption, weight: .medium))
          .foregroundStyle(Theme.Text.secondary)
          .padding(.horizontal, Theme.Spacing.snug)
          .padding(.vertical, Theme.Spacing.xs)
          .background { QuietBackground(shape: Capsule()) }
          .accessibilityIdentifier("message.tool")
      }
    }
  }

  static func toolLabel(_ name: String) -> String {
    switch name {
    case "calculate": String(localized: "Used the calculator")
    case "get_current_date_time": String(localized: "Checked the date")
    case "web_search": String(localized: "Searched the web")
    case "memory": String(localized: "Updated memory")
    default: String(localized: "Used \(name.replacingOccurrences(of: "_", with: " "))")
    }
  }

  private static func toolSymbol(_ name: String) -> String {
    switch name {
    case "calculate": "plus.forwardslash.minus"
    case "web_search": "globe"
    case "memory": "brain.head.profile"
    default: name.contains("date") || name.contains("time") ? "calendar" : "wrench.and.screwdriver"
    }
  }

  // MARK: - Actions

  private var isError: Bool { turn.text.hasPrefix(ChatTurn.errorPrefix) }

  private var actionRow: some View {
    HStack(spacing: 0) {
      if versions.count > 1 {
        versionSwitcher
      }
      if !isError {
        actionButton(
          copied ? "checkmark" : "doc.on.doc", copied ? "Copied" : "Copy", id: "message.copy"
        ) {
          copy(turn.text)
        }
        actionButton(
          actions.isSpeaking ? "stop.circle" : "speaker.wave.2",
          actions.isSpeaking ? "Stop reading" : "Read aloud", id: "message.speak",
          action: actions.speak)
      }
      if actions.canRegenerate {
        actionButton(
          "arrow.clockwise", isError ? "Retry" : "Regenerate", id: "message.regenerate",
          action: actions.regenerate
        )
        .disabled(actions.isBusy)
      }
      if !isError {
        ShareLink(item: turn.text) {
          Image(systemName: "square.and.arrow.up")
            .frame(width: Theme.Size.target, height: Theme.Size.target)
        }
        .accessibilityLabel("Share")
        .accessibilityIdentifier("message.share")
      }
    }
    .font(.system(.footnote, weight: .medium))
    .foregroundStyle(Theme.Text.tertiary)
    .buttonStyle(.borderless)
    // Optical alignment: the first glyph lines up with the reply's text.
    .padding(.leading, -(Theme.Size.target - 18) / 2)
  }

  private func actionButton(
    _ symbol: String, _ label: String, id: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: Theme.Size.target, height: Theme.Size.target)
    }
    .accessibilityLabel(label)
    .accessibilityIdentifier(id)
  }

  private var versionSwitcher: some View {
    let index = versions.firstIndex { $0.id == turn.id } ?? 0
    return HStack(spacing: 0) {
      Button {
        Haptics.selection()
        actions.selectVersion(versions[index - 1])
      } label: {
        Image(systemName: "chevron.left")
          .frame(width: Theme.Size.glyph, height: Theme.Size.target)
      }
      .disabled(index == 0 || actions.isBusy)
      .accessibilityLabel("Previous version")
      .accessibilityIdentifier("message.version.previous")
      Text("\(index + 1)/\(versions.count)")
        .font(.caption)
        .monospacedDigit()
        .contentTransition(.numericText())
        .accessibilityLabel("Version \(index + 1) of \(versions.count)")
        .accessibilityIdentifier("message.version")
      Button {
        Haptics.selection()
        actions.selectVersion(versions[index + 1])
      } label: {
        Image(systemName: "chevron.right")
          .frame(width: Theme.Size.glyph, height: Theme.Size.target)
      }
      .disabled(index + 1 >= versions.count || actions.isBusy)
      .accessibilityLabel("Next version")
      .accessibilityIdentifier("message.version.next")
    }
    .font(.system(.footnote, weight: .medium))
    .foregroundStyle(Theme.Text.tertiary)
    .buttonStyle(.borderless)
  }

  private func copy(_ text: String) {
    UIPasteboard.general.string = text
    Haptics.complete()
    copied = true
    Task {
      try? await Task.sleep(for: .seconds(1.5))
      copied = false
    }
  }

  // MARK: - Live indicators

  @ViewBuilder
  private var streamingCursor: some View {
    let cursor = Capsule()
      .fill(Theme.Brand.glacier)
      .frame(width: 3, height: 17)
      .accessibilityHidden(true)
    if reduceMotion {
      cursor
    } else {
      cursor.phaseAnimator([1.0, 0.25]) { view, value in
        view.opacity(value)
      } animation: { _ in
        .easeInOut(duration: 0.6)
      }
    }
  }

  private var thinkingDots: some View {
    HStack(spacing: Theme.Spacing.tight) {
      ForEach(0..<3) { index in
        let dot = Circle()
          .fill(Theme.Text.tertiary)
          .frame(width: 7, height: 7)
        if reduceMotion {
          dot
        } else {
          dot.phaseAnimator([false, true]) { view, active in
            view.opacity(active ? 0.25 : 1.0)
          } animation: { _ in
            .easeInOut(duration: 0.6).delay(Double(index) * 0.2)
          }
        }
      }
    }
    .padding(.vertical, Theme.Spacing.tight)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Thinking")
  }
}

private extension View {
  /// The user's bubble: a raised warm surface with a glacier hint.
  func bubbleChrome() -> some View {
    self
      .padding(.horizontal, Theme.Spacing.lg - 2)
      .padding(.vertical, Theme.Spacing.snug)
      .background {
        RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
          .fill(Theme.Surface.stage)
          .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
              .fill(Theme.Brand.glacier.opacity(0.08))
          }
      }
      .overlay {
        RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
          .stroke(Theme.Surface.stroke, lineWidth: Theme.Stroke.hairline)
      }
  }
}
