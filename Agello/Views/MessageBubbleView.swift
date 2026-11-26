import SwiftData
import SwiftUI
import UIKit

/// One chat message. The user's turns sit on a raised warm surface; the
/// model's are full-width text with quiet accessories (reasoning, sources,
/// tools, actions). Color stays in the content layer: no glass here.
struct MessageBubbleView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  @Environment(\.modelContext) private var modelContext
  @Environment(AppState.self) private var appState
  let turn: ChatTurn
  let thread: ChatThread?
  var isStreaming: Bool = false
  /// All versions of this turn (edits / regenerations), oldest first.
  var versions: [ChatTurn] = []
  var canRegenerate = false
  /// Time to first token, speed and backend under the reply.
  var showsStats = false
  let reader: SpeechReader
  let composerBridge: ComposerBridge
  @State private var copied = false
  @State private var copyResetTask: Task<Void, Never>?
  @State private var showsThought = false
  @State private var showsSources = false

  var body: some View {
    Group {
      if turn.isUser {
        userBubble
      } else {
        modelBlock
      }
    }
    .onChange(of: turn.id) { _, _ in
      copyResetTask?.cancel()
      copyResetTask = nil
      copied = false
      showsThought = false
      showsSources = false
    }
    .onDisappear {
      copyResetTask?.cancel()
      copyResetTask = nil
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
        if let data = turn.imageData {
          TurnPhotoView(turnID: turn.id, data: data)
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
              UserEditMenuButton(turn: turn, composerBridge: composerBridge)
            }
            // The long-press menu as actions VoiceOver and Switch Control can reach.
            .accessibilityAction(named: "Copy") { copy(turn.text) }
            .accessibilityAction(named: "Edit") {
              if !appState.isBusy { composerBridge.send(.edit(turn)) }
            }
        }
        if versions.count > 1 {
          VersionSwitcherView(turn: turn, thread: thread, versions: versions)
        }
      }
    }
  }

  // MARK: - Model

  private var modelBlock: some View {
    let parts = turn.parts
    return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      if isStreaming {
        LiveToolStatusRow()
      }
      if !turn.thought.isEmpty {
        thoughtCard
          .onAppear { ReplyTrace.onScreen(turn.id, "reasoning") }
      }
      if !turn.text.isEmpty {
        VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
          MarkdownView(
            WebContext.linkCitations(turn.text, sources: parts.sources), streaming: isStreaming)
            .textSelection(.enabled)
          if isStreaming {
            streamingCursor
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        // While a reply streams, the spoken form runs only when VoiceOver reads it;
        // completed replies hit the bounded spoken-text cache.
        .accessibilityLabel(
          Text(
            isStreaming && !voiceOverEnabled
              ? turn.text : Self.cachedSpokenText(for: turn.id, markdown: turn.text)))
        .accessibilityIdentifier("message.model")
        .onAppear { ReplyTrace.onScreen(turn.id) }
      } else if isStreaming {
        thinkingDots
      }
      if !turn.toolNames.isEmpty {
        toolChips
      }
      if !isStreaming {
        postStreamFooter(parts: parts)
          .transition(.opacity)
      }
      if showsStats, let stats = turn.stats {
        Text(stats.footerLine)
          .font(.caption2)
          .monospacedDigit()
          .foregroundStyle(Theme.Text.tertiary)
          .accessibilityIdentifier("message.stats")
      }
    }
    .appAnimation(Theme.Motion.stateChange, value: isStreaming, kind: .dissolve)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func postStreamFooter(parts: MessageParts) -> some View {
    let hasWeatherCard = parts.actionCards.contains {
      if case .weather = $0.payload { return true }
      return false
    }
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      if !parts.actionCards.isEmpty {
        ActionCardStack(cards: parts.actionCards) { updated in
          persistCardUpdate(updated)
        }
      }
      if !turn.text.isEmpty || !parts.actionCards.isEmpty {
        if !parts.sources.isEmpty {
          sourcesCard(parts.sources)
          if !hasWeatherCard, parts.sources.contains(where: { WeatherLookup.isAttribution($0.url) }) {
            WeatherAttributionMark()
          }
        }
        if parts.incomplete {
          Label("Incomplete reply", systemImage: "exclamationmark.circle")
            .font(.footnote)
            .foregroundStyle(Theme.Text.tertiary)
            .accessibilityIdentifier("message.incomplete")
        }
        if let memory = parts.toolActivity.last(where: { $0.name == "memory" }) {
          Label("Memory updated", systemImage: "brain.head.profile")
            .font(.footnote)
            .foregroundStyle(Theme.Text.tertiary)
            .accessibilityValue(memory.summary)
            .accessibilityIdentifier("message.memory")
        }
        if !turn.text.isEmpty || versions.count > 1 || canRegenerate {
          actionRow
        }
      }
    }
  }

  private static let headingRegex = try? NSRegularExpression(pattern: #"(?m)^#{1,6}\s+"#)
  private static let citationRegex = try? NSRegularExpression(pattern: WebContext.citationMarker)

  private final class SpokenTextEntry {
    let source: String
    let spoken: String
    init(source: String, spoken: String) {
      self.source = source
      self.spoken = spoken
    }
  }

  private static let spokenTextCache: NSCache<NSString, SpokenTextEntry> = {
    let cache = NSCache<NSString, SpokenTextEntry>()
    cache.countLimit = 200
    cache.totalCostLimit = 2 * 1024 * 1024
    return cache
  }()

  private static func cachedSpokenText(for turnID: UUID, markdown: String) -> String {
    let key = "\(turnID.uuidString)|\(markdown.count)" as NSString
    if let hit = spokenTextCache.object(forKey: key), hit.source == markdown {
      return hit.spoken
    }
    let spoken = spokenText(markdown)
    spokenTextCache.setObject(
      SpokenTextEntry(source: markdown, spoken: spoken), forKey: key, cost: spoken.utf8.count)
    return spoken
  }

  /// VoiceOver reads the reply, not its markdown syntax: emphasis and code marks, heading marks
  /// at the start of a line, citation numbers. A "#" inside text (C#, issue #42) stays.
  static func spokenText(_ markdown: String) -> String {
    var text = markdown
    if text.contains("**") { text = text.replacingOccurrences(of: "**", with: "") }
    if text.contains("__") { text = text.replacingOccurrences(of: "__", with: "") }
    if text.contains("`") { text = text.replacingOccurrences(of: "`", with: "") }
    if text.contains("#"), let regex = headingRegex {
      let range = NSRange(text.startIndex..., in: text)
      text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
    if text.contains("["), let regex = citationRegex {
      let range = NSRange(text.startIndex..., in: text)
      text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
    return text
  }

  // MARK: - Reasoning

  private var isThoughtExpandable: Bool {
    if showsThought { return true }
    return turn.thought.count >= 110 || turn.thought.components(separatedBy: .newlines).count > 2
  }

  /// Quiet card above the answer; collapsed to two lines of the thought.
  private var thoughtCard: some View {
    let tint = Theme.Mode.think.tint
    let isActivelyThinking = isStreaming && turn.text.isEmpty
    let shouldPulseHeader = isActivelyThinking && !showsThought && !reduceMotion
    return Button {
      withAppAnimation(Theme.Motion.easeOut) { showsThought.toggle() }
      Haptics.selection()
    } label: {
      VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
        HStack(spacing: Theme.Spacing.tight) {
          thoughtHeaderTitle(
            tint: tint,
            isActivelyThinking: isActivelyThinking,
            shouldPulse: shouldPulseHeader)
          Spacer()
          if isThoughtExpandable {
            Image(systemName: "chevron.down")
              .font(.caption2.weight(.semibold))
              .rotationEffect(.degrees(showsThought ? 180 : 0))
              .accessibilityHidden(true)
          }
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
    .accessibilityValue(showsThought ? "Expanded" : "Collapsed")
    .accessibilityHint(showsThought ? "Collapses the reasoning" : "Shows all of the reasoning")
    .accessibilityIdentifier("message.reasoning")
  }

  @ViewBuilder
  private func thoughtHeaderTitle(
    tint: Color, isActivelyThinking: Bool, shouldPulse: Bool
  ) -> some View {
    let header = HStack(spacing: Theme.Spacing.tight) {
      Image(systemName: "lightbulb.fill")
        .font(.caption2)
        .symbolEffect(.pulse, isActive: shouldPulse)
      Text(isActivelyThinking ? "Thinking…" : "Reasoning")
        .eyebrowStyle(tint)
        .contentTransition(.opacity)
        .appAnimation(Theme.Motion.stateChange, value: isActivelyThinking, kind: .dissolve)
    }
    if shouldPulse {
      header.phaseAnimator([1.0, 0.48]) { view, opacity in
        view.opacity(opacity)
      } animation: { _ in
        .easeInOut(duration: 0.85)
      }
    } else {
      header
    }
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
            .accessibilityHidden(true)
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
      .accessibilityValue(showsSources ? "Expanded" : "Collapsed")
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
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
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
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
        if let host = source.url.flatMap(URL.init(string:))?.host() {
          Text(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
            .font(.caption2)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let snippet = source.snippet {
          Text(snippet)
            .font(.caption)
            .foregroundStyle(Theme.Text.tertiary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(Theme.Spacing.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    if let link = source.url.flatMap(URL.init(string:)),
      let scheme = link.scheme?.lowercased(), scheme == "http" || scheme == "https"
    {
      Link(destination: link) { row }
        .accessibilityIdentifier("message.source")
    } else {
      row
    }
  }

  // MARK: - Tools

  private var toolChips: some View {
    WrapFlowLayout(horizontalSpacing: Theme.Spacing.tight, verticalSpacing: Theme.Spacing.tight) {
      ForEach(turn.toolNames, id: \.self) { name in
        Label(Self.toolLabel(name), systemImage: Self.toolSymbol(name))
          .font(.system(.caption, weight: .medium))
          .foregroundStyle(Theme.Text.secondary)
          .lineLimit(1)
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
    case "convert_units": String(localized: "Converted units")
    case "query_table_or_json": String(localized: "Analyzed data")
    case "search_files": String(localized: "Searched files")
    case "read_document_pages": String(localized: "Read document")
    case "search_past_chats": String(localized: "Searched past chats")
    case "search_places": String(localized: "Searched Apple Maps")
    case "estimate_travel_time": String(localized: "Checked directions")
    case "read_calendar", "search_calendar_events": String(localized: "Checked calendar")
    case "find_free_slots": String(localized: "Checked free time")
    case "manage_calendar_event": String(localized: "Updated calendar")
    case "create_calendar_event": String(localized: "Created event")
    case "list_reminders": String(localized: "Checked reminders")
    case "manage_reminder": String(localized: "Updated reminder")
    case "create_reminder": String(localized: "Created reminder")
    case "search_contacts": String(localized: "Searched contacts")
    case "prepare_message": String(localized: "Drafted message")
    case "get_weather": String(localized: "Checked weather")
    case "list_alarms": String(localized: "Checked alarms")
    case "manage_alarm": String(localized: "Updated alarm")
    case "search_photos": String(localized: "Searched photos")
    case "run_shortcut": String(localized: "Ran shortcut")
    case "web_search": String(localized: "Searched the web")
    case "memory": String(localized: "Updated memory")
    default: String(localized: "Used \(name.replacingOccurrences(of: "_", with: " "))")
    }
  }

  static func toolSymbol(_ name: String) -> String {
    switch name {
    case "calculate": "plus.forwardslash.minus"
    case "get_current_date_time": "clock"
    case "convert_units": "arrow.left.arrow.right"
    case "query_table_or_json": "tablecells"
    case "search_files": "doc.text.magnifyingglass"
    case "read_document_pages": "book.pages"
    case "search_past_chats": "clock.arrow.trianglehead.counterclockwise.rotate.90"
    case "search_places": "mappin.and.ellipse"
    case "estimate_travel_time": "car.fill"
    case "read_calendar", "search_calendar_events": "calendar"
    case "find_free_slots": "calendar.badge.clock"
    case "manage_calendar_event", "create_calendar_event": "calendar.badge.plus"
    case "list_reminders": "checklist"
    case "manage_reminder", "create_reminder": "checklist.checked"
    case "search_contacts": "person.crop.circle"
    case "prepare_message": "paperplane"
    case "get_weather": "cloud.sun.fill"
    case "list_alarms", "manage_alarm": "alarm.fill"
    case "search_photos": "photo.on.rectangle.angled"
    case "run_shortcut": "bolt.fill"
    case "web_search": "globe"
    case "memory": "brain.head.profile"
    default: "wrench.and.screwdriver"
    }
  }

  // MARK: - Actions

  private var isError: Bool { turn.text.hasPrefix(ChatTurn.errorPrefix) }

  private var actionRow: some View {
    HStack(spacing: 0) {
      if versions.count > 1 {
        VersionSwitcherView(turn: turn, thread: thread, versions: versions)
      }
      if !isError, !turn.text.isEmpty {
        actionButton(
          copied ? "checkmark" : "doc.on.doc", copied ? "Copied" : "Copy", id: "message.copy"
        ) {
          copy(turn.text)
        }
        SpeakActionButton(turnID: turn.id, text: turn.text, reader: reader)
      }
      if canRegenerate, let thread {
        RegenerateActionButton(turn: turn, thread: thread, isError: isError, reader: reader)
      }
      if !isError, !turn.text.isEmpty {
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
        .appAnimation(Theme.Motion.stateChange, value: symbol, kind: .dissolve)
        .frame(width: Theme.Size.target, height: Theme.Size.target)
    }
    .accessibilityLabel(label)
    .accessibilityIdentifier(id)
  }

  private func persistCardUpdate(_ updatedCard: ActionCardRecord) {
    guard !turn.isDeleted else { return }
    var parts = turn.parts
    let key = updatedCard.deduplicationKey
    if let index = parts.actionCards.firstIndex(where: { $0.deduplicationKey == key || $0.id == updatedCard.id }) {
      parts.actionCards[index] = updatedCard
    } else {
      parts.actionCards.append(updatedCard)
    }
    turn.parts = parts
    try? (turn.modelContext ?? modelContext).save()
  }

  private func copy(_ text: String) {
    Platform.copy(text)
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

  @ViewBuilder
  private var thinkingDots: some View {
    Group {
      if reduceMotion {
        thinkingDotsRow(activePhase: nil)
      } else {
        PhaseAnimator([0, 1, 2]) { phase in
          thinkingDotsRow(activePhase: phase)
        } animation: { _ in
          .easeInOut(duration: 0.38)
        }
      }
    }
    .padding(.vertical, Theme.Spacing.tight)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Thinking")
  }

  private func thinkingDotsRow(activePhase: Int?) -> some View {
    HStack(spacing: Theme.Spacing.tight) {
      ForEach(0..<3, id: \.self) { index in
        let isActive = activePhase == index
        Circle()
          .fill(Theme.Text.tertiary)
          .frame(width: 7, height: 7)
          .opacity(activePhase == nil ? 0.7 : (isActive ? 1.0 : 0.3))
          .scaleEffect(activePhase == nil ? 1.0 : (isActive ? 1.0 : 0.85))
      }
    }
  }
}

/// Isolated live tool status row mounted solely inside the streaming reply bubble so historical
/// rows never subscribe to `appState.toolStatus`.
private struct LiveToolStatusRow: View {
  @Environment(AppState.self) private var appState

  var body: some View {
    if let toolStatus = appState.toolStatus {
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
  }
}

/// Isolated Speak / Stop reading button observing `reader.speakingID` without re-evaluating its
/// parent `MessageBubbleView` or `MarkdownView`.
private struct SpeakActionButton: View {
  let turnID: UUID
  let text: String
  let reader: SpeechReader

  var body: some View {
    let isSpeaking = reader.speakingID == turnID
    Button {
      withAppAnimation(Theme.Motion.stateChange, kind: .dissolve) {
        reader.toggle(text, id: turnID)
      }
    } label: {
      Image(systemName: isSpeaking ? "stop.circle" : "speaker.wave.2")
        .foregroundStyle(isSpeaking ? Theme.Mode.voice.tint : Theme.Text.tertiary)
        .contentTransition(.symbolEffect(.replace))
        .frame(width: Theme.Size.target, height: Theme.Size.target)
    }
    .appAnimation(Theme.Motion.stateChange, value: isSpeaking, kind: .dissolve)
    .accessibilityLabel(isSpeaking ? "Stop reading" : "Read aloud")
    .accessibilityIdentifier("message.speak")
  }
}

private struct RegenerateActionButton: View {
  @Environment(AppState.self) private var appState
  let turn: ChatTurn
  let thread: ChatThread
  let isError: Bool
  let reader: SpeechReader

  var body: some View {
    Button {
      reader.stop()
      Haptics.send()
      Task { await appState.regenerate(turn, in: thread) }
    } label: {
      Image(systemName: "arrow.clockwise")
        .contentTransition(.symbolEffect(.replace))
        .frame(width: Theme.Size.target, height: Theme.Size.target)
    }
    .disabled(appState.isBusy)
    .accessibilityLabel(isError ? "Retry" : "Regenerate")
    .accessibilityIdentifier("message.regenerate")
  }
}

private struct UserEditMenuButton: View {
  @Environment(AppState.self) private var appState
  let turn: ChatTurn
  let composerBridge: ComposerBridge

  var body: some View {
    Button("Edit", systemImage: "pencil") {
      composerBridge.send(.edit(turn))
    }
    .disabled(appState.isBusy)
  }
}

private struct VersionSwitcherView: View {
  @Environment(AppState.self) private var appState
  let turn: ChatTurn
  let thread: ChatThread?
  let versions: [ChatTurn]
  @State private var countingDown = false

  var body: some View {
    let index = versions.firstIndex { $0.id == turn.id } ?? 0
    let isBusy = appState.isBusy
    HStack(spacing: 0) {
      Button {
        guard let thread, index > 0, versions.indices.contains(index - 1) else { return }
        countingDown = true
        Haptics.selection()
        withAppAnimation(Theme.Motion.stateChange, kind: .dissolve) {
          appState.selectVersion(versions[index - 1], in: thread)
        }
      } label: {
        Image(systemName: "chevron.left")
          .frame(width: Theme.Size.glyph, height: Theme.Size.target)
      }
      .disabled(index == 0 || isBusy)
      .accessibilityLabel("Previous version")
      .accessibilityIdentifier("message.version.previous")
      Text("\(index + 1)/\(versions.count)")
        .font(.caption)
        .monospacedDigit()
        .contentTransition(.numericText(countsDown: countingDown))
        .appAnimation(Theme.Motion.stateChange, value: index, kind: .dissolve)
        .accessibilityLabel("Version \(index + 1) of \(versions.count)")
        .accessibilityIdentifier("message.version")
      Button {
        guard let thread, versions.indices.contains(index + 1) else { return }
        countingDown = false
        Haptics.selection()
        withAppAnimation(Theme.Motion.stateChange, kind: .dissolve) {
          appState.selectVersion(versions[index + 1], in: thread)
        }
      } label: {
        Image(systemName: "chevron.right")
          .frame(width: Theme.Size.glyph, height: Theme.Size.target)
      }
      .disabled(index + 1 >= versions.count || isBusy)
      .accessibilityLabel("Next version")
      .accessibilityIdentifier("message.version.next")
    }
    .font(.system(.footnote, weight: .medium))
    .foregroundStyle(Theme.Text.tertiary)
    .buttonStyle(.borderless)
  }
}

@MainActor
private enum TurnPhotoCache {
  private static let cache: NSCache<NSUUID, CGImage> = {
    let cache = NSCache<NSUUID, CGImage>()
    cache.countLimit = 40
    cache.totalCostLimit = 24 * 1024 * 1024
    return cache
  }()

  static func image(for id: UUID) -> CGImage? {
    cache.object(forKey: id as NSUUID)
  }

  static func store(_ image: CGImage, for id: UUID) {
    let cost = max(1, image.bytesPerRow * image.height)
    cache.setObject(image, forKey: id as NSUUID, cost: cost)
  }
}

/// Decodes attached chat photos off MainActor and caches them in a cost-bounded `NSCache`
/// so scrolling and streaming never run synchronous ImageIO decoding in `body`.
private struct TurnPhotoView: View {
  let turnID: UUID
  let data: Data
  @State private var image: CGImage?
  @State private var loadedTurnID: UUID?

  init(turnID: UUID, data: Data) {
    self.turnID = turnID
    self.data = data
    let hit = TurnPhotoCache.image(for: turnID)
    _image = State(initialValue: hit)
    _loadedTurnID = State(initialValue: hit == nil ? nil : turnID)
  }

  var body: some View {
    Group {
      if let image {
        Image(image, scale: 1, label: Text("Attached photo"))
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 220)
          .clipShape(.rect(cornerRadius: Theme.Radius.group, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
              .stroke(Theme.Surface.stroke, lineWidth: Theme.Stroke.hairline)
          }
      } else {
        RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
          .fill(Theme.Surface.stage)
          .frame(width: 180, height: 140)
          .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.group, style: .continuous)
              .stroke(Theme.Surface.stroke, lineWidth: Theme.Stroke.hairline)
          }
          .accessibilityLabel("Attached photo")
      }
    }
    .task(id: turnID) {
      if loadedTurnID == turnID, image != nil { return }
      if let hit = TurnPhotoCache.image(for: turnID) {
        image = hit
        loadedTurnID = turnID
        return
      }
      image = nil
      loadedTurnID = nil
      let payload = data
      // 1,024 pixels fill the bubble's width at 3x.
      let decoded = await Task.detached(priority: .userInitiated) {
        ImageDownsampler.cgImage(from: payload, maxPixels: 1_024)
      }.value
      guard !Task.isCancelled, let decoded else { return }
      TurnPhotoCache.store(decoded, for: turnID)
      image = decoded
      loadedTurnID = turnID
    }
  }
}

/// Leading-aligned wrapping flow layout for tool pills and action card buttons. Clamps every
/// child to the proposed width so it can never widen an enclosing vertical `ScrollView`.
struct WrapFlowLayout: Layout {
  var horizontalSpacing: CGFloat = 6
  var verticalSpacing: CGFloat = 6

  struct Cache {
    var proposedWidth: CGFloat?
    var sizes: [CGSize] = []
  }

  func makeCache(subviews: Subviews) -> Cache {
    Cache()
  }

  func updateCache(_ cache: inout Cache, subviews: Subviews) {
    cache.proposedWidth = nil
    cache.sizes.removeAll(keepingCapacity: true)
  }

  private func measuredSizes(
    for subviews: Subviews, maxWidth: CGFloat, cache: inout Cache
  ) -> [CGSize] {
    let keyWidth: CGFloat? = maxWidth.isFinite ? maxWidth : nil
    if cache.sizes.count == subviews.count, cache.proposedWidth == keyWidth {
      return cache.sizes
    }
    let childProposal = ProposedViewSize(width: keyWidth, height: nil)
    let sizes = subviews.map { $0.sizeThatFits(childProposal) }
    cache.proposedWidth = keyWidth
    cache.sizes = sizes
    return sizes
  }

  func sizeThatFits(
    proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
  ) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    let sizes = measuredSizes(for: subviews, maxWidth: maxWidth, cache: &cache)
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var usedWidth: CGFloat = 0
    for size in sizes {
      let width = maxWidth.isFinite ? min(size.width, maxWidth) : size.width
      if x > 0, x + width > maxWidth {
        x = 0
        y += rowHeight + verticalSpacing
        rowHeight = 0
      }
      usedWidth = max(usedWidth, x + width)
      x += width + horizontalSpacing
      rowHeight = max(rowHeight, size.height)
    }
    return CGSize(width: maxWidth.isFinite ? maxWidth : usedWidth, height: y + rowHeight)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
  ) {
    let maxWidth = bounds.width
    let sizes = measuredSizes(for: subviews, maxWidth: maxWidth, cache: &cache)
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    for (subview, size) in zip(subviews, sizes) {
      let width = min(size.width, maxWidth)
      if x > bounds.minX, x + width > bounds.maxX + 0.5 {
        x = bounds.minX
        y += rowHeight + verticalSpacing
        rowHeight = 0
      }
      subview.place(
        at: CGPoint(x: x, y: y),
        proposal: ProposedViewSize(width: width, height: size.height))
      x += width + horizontalSpacing
      rowHeight = max(rowHeight, size.height)
    }
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

@MainActor
private enum WeatherAttributionCache {
  private static var cachedMark: WeatherLookup.Mark?
  private static var cachedImage: UIImage?
  private static var cachedImageURL: URL?
  private static var inFlight: Task<(WeatherLookup.Mark?, UIImage?), Never>?

  static var current: (mark: WeatherLookup.Mark?, image: UIImage?) {
    (cachedMark, cachedImage)
  }

  static func load() async -> (mark: WeatherLookup.Mark?, image: UIImage?) {
    if let mark = cachedMark, let image = cachedImage, cachedImageURL == mark.image {
      return (mark, image)
    }
    if let existing = inFlight {
      return await existing.value
    }
    let task = Task<(WeatherLookup.Mark?, UIImage?), Never> { @MainActor in
      defer { inFlight = nil }
      let mark: WeatherLookup.Mark?
      if let existingMark = cachedMark {
        mark = existingMark
      } else if let fetched = await WeatherLookup.mark() {
        cachedMark = fetched
        mark = fetched
      } else {
        mark = nil
      }
      guard let mark else { return (nil, nil) }
      if cachedImageURL == mark.image, let existingImage = cachedImage {
        return (mark, existingImage)
      }
      let imageURL = mark.image
      let fetchedImage: UIImage? = await Task.detached(priority: .utility) {
        guard let (data, response) = try? await URLSession.shared.data(from: imageURL) else {
          return nil
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
          return nil
        }
        return UIImage(data: data)
      }.value
      if let fetchedImage {
        cachedImage = fetchedImage
        cachedImageURL = imageURL
      }
      return (mark, fetchedImage ?? cachedImage)
    }
    inFlight = task
    return await task.value
  }
}

/// Apple Weather's mark, linked to its legal page, under a reply that used its data: shown, not
/// tucked in the collapsed sources, as WeatherKit's terms and App Review require.
struct WeatherAttributionMark: View {
  @State private var mark: WeatherLookup.Mark?
  @State private var image: UIImage?
  @ScaledMetric(relativeTo: .caption2) private var height = Theme.Size.attributionMark

  init() {
    let cached = WeatherAttributionCache.current
    _mark = State(initialValue: cached.mark)
    _image = State(initialValue: cached.image)
  }

  var body: some View {
    let legalURL = mark?.legal ?? WeatherLookup.fallbackLegalURL
    let serviceName = mark?.name ?? String(localized: "Apple Weather")
    Link(destination: legalURL) {
      Group {
        if let image {
          Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(height: height)
        } else {
          fallbackLabel(serviceName)
        }
      }
      .frame(minHeight: Theme.Size.target, alignment: .leading)
    }
    .accessibilityLabel("\(serviceName), legal attribution")
    .accessibilityIdentifier("message.weatherAttribution")
    .task {
      guard image == nil else { return }
      let resolved = await WeatherAttributionCache.load()
      if let resolvedMark = resolved.mark { mark = resolvedMark }
      if let resolvedImage = resolved.image { image = resolvedImage }
    }
  }

  private func fallbackLabel(_ name: String) -> some View {
    Text(name)
      .font(.caption2)
      .foregroundStyle(Theme.Text.tertiary)
  }
}
