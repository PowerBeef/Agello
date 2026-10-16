import SwiftData
import SwiftUI

/// The side drawer: the wordmark, search, projects, chats grouped by date,
/// and Settings, on a warm panel.
struct DrawerView: View {
  @Environment(AppState.self) private var appState
  @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]
  @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
  @State private var query = ""
  /// The search the list shows: `query` once typing pauses. Matching reads every message of
  /// every chat, too much to redo at each keystroke.
  @State private var appliedQuery = ""
  /// Chats related in meaning to the search (beyond the text matches).
  @State private var related: [Row] = []
  @FocusState private var searchFocused: Bool

  var onSelect: (ChatThread) -> Void
  var onNewChat: () -> Void
  var onRename: (ChatThread) -> Void
  var onTogglePin: (ChatThread) -> Void
  var onDelete: (ChatThread) -> Void
  var onSettings: () -> Void
  var onOpenProject: (Project) -> Void
  var onNewProject: () -> Void
  var onMove: (ChatThread, UUID?) -> Void

  private struct Row: Identifiable {
    var thread: ChatThread
    var snippet: String?
    var id: UUID { thread.id }
  }

  /// Saved chats (empty ones are never shown), filtered by the search.
  /// Project chats live in their project, but search finds them too.
  private var rows: [Row] {
    threads.compactMap { thread in
      guard !thread.turns.isEmpty else { return nil }
      if appliedQuery.isEmpty { return thread.projectID == nil ? Row(thread: thread) : nil }
      let messages = thread.orderedTurns.map(\.text)
      return ThreadGrouping.match(query: appliedQuery, title: thread.title, messages: messages)
        .map { Row(thread: thread, snippet: $0.snippet) }
    }
  }

  var body: some View {
    let rows = rows
    let relatedRows = appliedQuery.isEmpty ? [] : related.filter { hit in !rows.contains { $0.id == hit.id } }
    VStack(spacing: 0) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
          if appliedQuery.isEmpty {
            projectsSection
          }
          if rows.isEmpty, relatedRows.isEmpty {
            Group {
              if appliedQuery.isEmpty {
                EmptyStateView(
                  symbol: "bubble.left.and.bubble.right", title: "No chats yet",
                  message: "Your conversations stay on this iPhone.")
              } else {
                EmptyStateView(
                  symbol: "magnifyingglass", title: "No results",
                  message: "Nothing matches \u{201C}\(appliedQuery)\u{201D}.")
              }
            }
            .padding(.top, Theme.Spacing.sm)
          } else {
            chatGroups(rows, related: relatedRows)
          }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.lg)
      }
      .scrollDismissesKeyboard(.immediately)
      footer
    }
    .onAppear {
      // Ready for search by meaning by the time the user types.
      appState.knowledge.indexChats(threads.filter { !$0.turns.isEmpty })
    }
    .task(id: query) {
      // Results for the previous query must not linger while typing.
      related = []
      let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
      // Clearing the search shows every chat at once; typing filters when it pauses.
      guard !query.isEmpty else {
        appliedQuery = ""
        return
      }
      try? await Task.sleep(for: .milliseconds(200))
      guard !Task.isCancelled else { return }
      appliedQuery = query
      guard text.count >= 3 else { return }
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      let hits = await appState.knowledge.relatedChats(
        text, in: threads.filter { !$0.turns.isEmpty }, limit: 6)
      guard !Task.isCancelled else { return }
      related = hits.map { Row(thread: $0.thread) }
    }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      HStack(spacing: Theme.Spacing.sm) {
        Image(systemName: "sparkles")
          .font(.system(.subheadline, weight: .semibold))
          .foregroundStyle(Theme.Brand.glacier)
          .accessibilityHidden(true)
        Text("Agello")
          .font(.wordmark)
          .foregroundStyle(Theme.Text.primary)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Button(action: onNewChat) {
          Image(systemName: "square.and.pencil")
        }
        .buttonStyle(QuietCircleButtonStyle())
        .accessibilityLabel("New chat")
        .accessibilityIdentifier("drawer.new")
      }
      HStack(spacing: Theme.Spacing.sm) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(Theme.Text.tertiary)
          .accessibilityHidden(true)
        TextField(
          "Search chats", text: $query,
          prompt: Text("Search chats").foregroundStyle(Theme.Text.placeholder)
        )
        .foregroundStyle(Theme.Text.primary)
        .focused($searchFocused)
        .submitLabel(.search)
        .accessibilityIdentifier("drawer.search")
        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(Theme.Text.tertiary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Clear search")
        }
      }
      .padding(.horizontal, Theme.Spacing.md)
      .frame(minHeight: Theme.Size.target)
      .background {
        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
          .fill(Color.white.opacity(0.06))
      }
      .overlay {
        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
          .stroke(Theme.Surface.hairline, lineWidth: Theme.Stroke.hairline)
      }
    }
    .padding(.horizontal, Theme.Spacing.lg)
    .padding(.top, Theme.Spacing.sm)
    .padding(.bottom, Theme.Spacing.md)
  }

  // MARK: - Projects

  private var projectsSection: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
      HStack {
        Text("Projects").eyebrowStyle().accessibilityAddTraits(.isHeader)
        Spacer()
        Button(action: onNewProject) {
          Image(systemName: "plus")
            .font(.system(.footnote, weight: .semibold))
            .foregroundStyle(Theme.Brand.glacier)
            .frame(width: Theme.Size.target, height: Theme.Size.glyph)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New project")
        .accessibilityIdentifier("drawer.newProject")
      }
      .padding(.leading, Theme.Spacing.sm)
      if projects.isEmpty {
        Text("Group chats with shared instructions and files.")
          .font(.footnote)
          .foregroundStyle(Theme.Text.tertiary)
          .padding(.horizontal, Theme.Spacing.sm)
      }
      ForEach(projects.prefix(6)) { project in
        Button {
          onOpenProject(project)
        } label: {
          HStack(spacing: Theme.Spacing.md) {
            TintTile(symbol: "folder.fill", tint: Theme.Brand.glacier)
            Text(project.name)
              .font(.rowTitle)
              .foregroundStyle(Theme.Text.primary)
              .lineLimit(1)
            Spacer(minLength: 0)
          }
          .drawerRow(selected: false)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drawer.project")
      }
    }
  }

  // MARK: - Chats

  private func chatGroups(_ rows: [Row], related: [Row] = []) -> some View {
    var groups = ThreadGrouping.groups(
      rows, date: { $0.thread.updatedAt }, pinned: { $0.thread.isPinned })
    if !related.isEmpty {
      groups.append(.init(title: String(localized: "Related chats"), items: related))
    }
    return LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
      ForEach(groups) { group in
        Text(group.title)
          .eyebrowStyle()
          // Tests and VoiceOver read the title as written ("Pinned").
          .accessibilityLabel(group.title)
          .accessibilityAddTraits(.isHeader)
          .padding(.horizontal, Theme.Spacing.sm)
          .padding(.top, Theme.Spacing.md)
          .padding(.bottom, Theme.Spacing.xs)
        ForEach(group.items) { row in
          rowView(row)
        }
      }
    }
  }

  private func rowView(_ row: Row) -> some View {
    let thread = row.thread
    let selected = thread.id == appState.selectedThreadID
    return Button {
      searchFocused = false
      onSelect(thread)
    } label: {
      VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
        HStack(spacing: Theme.Spacing.tight) {
          Text(thread.title)
            .font(.rowTitle)
            .foregroundStyle(selected ? Theme.Text.primary : Theme.Text.secondary)
            .lineLimit(1)
          if appState.generatingThreadID == thread.id {
            ProgressView().controlSize(.mini)
          }
          if thread.isPinned {
            Spacer(minLength: Theme.Spacing.xs)
            Image(systemName: "pin.fill")
              .font(.caption2)
              .foregroundStyle(Theme.Text.tertiary)
              .accessibilityLabel("Pinned")
          }
        }
        if let snippet = row.snippet {
          Text(snippet)
            .font(.caption)
            .foregroundStyle(Theme.Text.tertiary)
            .lineLimit(2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .drawerRow(selected: selected)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .contextMenu {
      Button(
        thread.isPinned ? "Unpin" : "Pin", systemImage: thread.isPinned ? "pin.slash" : "pin"
      ) {
        onTogglePin(thread)
      }
      Button("Rename", systemImage: "pencil") { onRename(thread) }
      if !projects.isEmpty {
        Menu("Move to project", systemImage: "folder") {
          ForEach(projects) { project in
            Button(project.name) { onMove(thread, project.id) }
              .disabled(thread.projectID == project.id)
          }
          if thread.projectID != nil {
            Button("Remove from project", systemImage: "folder.badge.minus") { onMove(thread, nil) }
          }
        }
      }
      Button("Delete", systemImage: "trash", role: .destructive) { onDelete(thread) }
        // Its reply is still being written into this chat.
        .disabled(appState.generatingThreadID == thread.id)
    }
    .accessibilityIdentifier("drawer.row")
  }

  // MARK: - Footer

  private var footer: some View {
    VStack(spacing: 0) {
      Rectangle().fill(Theme.Surface.hairline).frame(height: Theme.Stroke.hairline)
      Button(action: onSettings) {
        HStack(spacing: Theme.Spacing.md) {
          TintTile(symbol: "gearshape.fill", tint: Theme.Brand.silver)
          Text("Settings")
            .font(.rowTitle)
            .foregroundStyle(Theme.Text.primary)
          Spacer()
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.Text.tertiary)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .frame(minHeight: Theme.Size.target + Theme.Spacing.md)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("drawer.settings")
    }
  }
}

private extension View {
  /// A drawer row: generous hit area; the open chat sits on a glacier pill.
  func drawerRow(selected: Bool) -> some View {
    self
      .padding(.horizontal, Theme.Spacing.sm)
      .padding(.vertical, Theme.Spacing.snug)
      .frame(minHeight: Theme.Size.target)
      .background {
        if selected {
          RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            .fill(Theme.Brand.glacier.opacity(0.12))
            .overlay {
              RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .stroke(Theme.Brand.glacier.opacity(0.22), lineWidth: Theme.Stroke.hairline)
            }
        }
      }
      .contentShape(.rect)
  }
}
