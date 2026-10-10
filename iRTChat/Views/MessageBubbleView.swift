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

/// One chat message. User turns are tinted glass (tint = authorship);
/// model turns are calm full-width text with glass accents.
struct MessageBubbleView: View {
  let turn: ChatTurn
  var isStreaming: Bool = false
  /// What a tool is doing right now (live reply only).
  var toolStatus: String? = nil
  /// All versions of this turn (edits / regenerations), oldest first.
  var versions: [ChatTurn] = []
  var actions = MessageActions()
  @State private var copied = false

  var body: some View {
    if turn.isUser {
      userBubble
    } else {
      modelBlock
    }
  }

  // MARK: - User

  private var userBubble: some View {
    HStack(alignment: .bottom, spacing: 8) {
      Spacer(minLength: 56)
      VStack(alignment: .trailing, spacing: 6) {
        ForEach(turn.parts.files) { file in
          FileChip(record: file)
        }
        if let data = turn.imageData, let image = UIImage(data: data) {
          Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxHeight: 220)
            .clipShape(.rect(cornerRadius: DS.radiusBanner))
        }
        if turn.hasAudio {
          Label("Voice message", systemImage: "waveform")
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(.accentColor), in: .rect(cornerRadius: DS.radiusBubble))
            .accessibilityIdentifier("message.voice")
        }
        if !turn.text.isEmpty {
          Text(turn.text)
            .accessibilityIdentifier("message.user")
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular.tint(.accentColor), in: .rect(cornerRadius: DS.radiusBubble))
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
    HStack(alignment: .top, spacing: DS.spaceMD) {
      Image(systemName: "sparkles")
        .font(.footnote)
        .frame(width: DS.iconSM, height: DS.iconSM)
        .glassEffect(.regular, in: .circle)
      VStack(alignment: .leading, spacing: 8) {
        if isStreaming, let toolStatus {
          HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(toolStatus)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("message.toolStatus")
        }
        if !turn.thought.isEmpty {
          thoughtCard
        }
        if !turn.text.isEmpty {
          VStack(alignment: .leading, spacing: 6) {
            MarkdownView(WebContext.linkCitations(turn.text, sources: turn.parts.sources))
              .textSelection(.enabled)
            if isStreaming {
              RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3, height: 17)
                .phaseAnimator([1.0, 0.25]) { view, value in
                  view.opacity(value)
                } animation: { _ in
                  .easeInOut(duration: 0.6).repeatForever()
                }
                .accessibilityHidden(true)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityElement(children: .contain)
          .accessibilityLabel(Text(turn.text))
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
              .font(.caption)
              .foregroundStyle(.secondary)
              .accessibilityValue(memory.summary)
              .accessibilityIdentifier("message.memory")
          }
          actionRow
        }
        if let stats = turn.stats {
          Text(stats.footerLine)
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .accessibilityIdentifier("message.stats")
        }
      }
      Spacer(minLength: 4)
    }
  }

  // MARK: - Sources

  private func sourcesCard(_ sources: [SourceRecord]) -> some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(sources) { source in
          let row = VStack(alignment: .leading, spacing: 2) {
            Text("\(source.index). \(source.title)")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.primary)
            if let host = source.url.flatMap(URL.init(string:))?.host() {
              Text(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
            }
            if let snippet = source.snippet {
              Text(snippet)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          if let link = source.url.flatMap(URL.init(string:)) {
            Link(destination: link) { row }
              .accessibilityIdentifier("message.source")
          } else {
            row
          }
        }
      }
      .padding(.top, 6)
    } label: {
      Label(
        sources.count == 1 ? "1 source" : "\(sources.count) sources",
        systemImage: "doc.text.magnifyingglass"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(DS.padMD)
    .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusInner))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("message.sources")
  }

  // MARK: - Actions

  private var isError: Bool { turn.text.hasPrefix(ChatTurn.errorPrefix) }

  private var actionRow: some View {
    HStack(spacing: 2) {
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
            .frame(width: DS.controlTarget, height: DS.controlTarget)
        }
        .accessibilityLabel("Share")
        .accessibilityIdentifier("message.share")
      }
    }
    .font(.subheadline)
    .foregroundStyle(.secondary)
    .buttonStyle(.borderless)
    .padding(.leading, -12)
  }

  private func actionButton(
    _ symbol: String, _ label: String, id: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: DS.controlTarget, height: DS.controlTarget)
    }
    .accessibilityLabel(label)
    .accessibilityIdentifier(id)
  }

  private var versionSwitcher: some View {
    let index = versions.firstIndex { $0.id == turn.id } ?? 0
    return HStack(spacing: 0) {
      Button {
        actions.selectVersion(versions[index - 1])
      } label: {
        Image(systemName: "chevron.left")
          .frame(width: 32, height: DS.controlTarget)
      }
      .disabled(index == 0 || actions.isBusy)
      .accessibilityLabel("Previous version")
      .accessibilityIdentifier("message.version.previous")
      Text("\(index + 1)/\(versions.count)")
        .font(.caption)
        .monospacedDigit()
        .accessibilityLabel("Version \(index + 1) of \(versions.count)")
        .accessibilityIdentifier("message.version")
      Button {
        actions.selectVersion(versions[index + 1])
      } label: {
        Image(systemName: "chevron.right")
          .frame(width: 32, height: DS.controlTarget)
      }
      .disabled(index + 1 >= versions.count || actions.isBusy)
      .accessibilityLabel("Next version")
      .accessibilityIdentifier("message.version.next")
    }
    .font(.subheadline)
    .foregroundStyle(.secondary)
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

  private var thinkingDots: some View {
    HStack(spacing: 6) {
      ForEach(0..<3) { index in
        Circle()
          .fill(Color.secondary)
          .frame(width: 7, height: 7)
          .phaseAnimator([false, true]) { dot, active in
            dot.opacity(active ? 0.25 : 1.0)
          } animation: { _ in
            .easeInOut(duration: 0.6).delay(Double(index) * 0.2).repeatForever()
          }
      }
    }
    .padding(.vertical, 6)
    .accessibilityLabel("Thinking")
  }

  private var thoughtCard: some View {
    DisclosureGroup {
      Text(turn.thought)
        .font(.callout)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("message.reasoning.text")
    } label: {
      Label("Reasoning", systemImage: "brain")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(DS.padMD)
    .glassEffect(.regular, in: .rect(cornerRadius: DS.radiusInner))
    // A container keeps the reasoning text's own identifier.
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("message.reasoning")
  }

  private var toolChips: some View {
    GlassEffectContainer(spacing: 6) {
      HStack(spacing: 6) {
        ForEach(turn.toolNames, id: \.self) { name in
          Label(name, systemImage: "wrench.and.screwdriver")
            .font(.caption2)
            .padding(.horizontal, 10)
            .padding(.vertical, DS.spaceXS)
            .glassEffect(.regular, in: .capsule)
            .accessibilityIdentifier("message.tool")
        }
      }
    }
  }
}
