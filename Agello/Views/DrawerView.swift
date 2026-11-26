import SwiftData
import SwiftUI

/// The side drawer: the wordmark, search, projects, chats grouped by date,
/// and Settings, on a warm panel.
struct DrawerView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dynamicTypeSize) private var typeSize
  @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]
  @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
  @State private var query = ""
  /// The search the list shows: `query` once typing pauses. Matching reads every message of
  /// every chat, too much to redo at each keystroke.
  @State private var appliedQuery = ""
  /// IDs of chats related in meaning to the search, resolved against live `@Query threads` so
  /// deleted models are never retained across renders.
  @State private var relatedIDs: [UUID] = []
  @State private var showAllProjects = false
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
  var onSearchFocusChanged: ((Bool) -> Void)?

  private struct Row: Identifiable {
    var thread: ChatThread
    var snippet: String?
    var id: UUID { thread.id }
  }

  /// Saved chats (empty ones are never shown), filtered by the search.
  /// Project chats live in their project, but search finds them too.
  private var rows: [Row] {
    threads.compactMap { thread in
      guard !thread.isDeleted, thread.modelContext != nil, !thread.turns.isEmpty else { return nil }
      if appliedQuery.isEmpty { return thread.projectID == nil ? Row(thread: thread) : nil }
      let messages = thread.orderedTurns.map(\.text)
      return ThreadGrouping.match(query: appliedQuery, title: thread.title, messages: messages)
        .map { Row(thread: thread, snippet: $0.snippet) }
    }
  }

  /// Projects matching the active search query so projects beyond the collapsed preview remain
  /// discoverable via search as well as "Show all".
  private var matchingProjects: [Project] {
    guard !appliedQuery.isEmpty else { return [] }
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    return projects.filter { project in
      guard !project.isDeleted, project.modelContext != nil else { return false }
      return project.name.range(of: appliedQuery, options: options) != nil
        || project.instructions.range(of: appliedQuery, options: options) != nil
    }
  }

  private func isBusy(_ thread: ChatThread) -> Bool {
    appState.generatingThreadID == thread.id || appState.preparingThreadID == thread.id
  }

  var body: some View {
    let rows = rows
    let rowIDs = Set(rows.map(\.id))
    let liveThreadsByID = Dictionary(
      uniqueKeysWithValues: threads.compactMap { thread -> (UUID, ChatThread)? in
        guard !thread.isDeleted, thread.modelContext != nil, !thread.turns.isEmpty else { return nil }
        return (thread.id, thread)
      })
    let relatedRows: [Row] = appliedQuery.isEmpty
      ? []
      : relatedIDs.compactMap { id in
        guard !rowIDs.contains(id), let thread = liveThreadsByID[id] else { return nil }
        return Row(thread: thread)
      }
    let matchedProjects = matchingProjects
    VStack(spacing: 0) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
          if appliedQuery.isEmpty {
            projectsSection
          } else if !matchedProjects.isEmpty {
            matchedProjectsSection(matchedProjects)
          }
          if rows.isEmpty, relatedRows.isEmpty, matchedProjects.isEmpty {
            Group {
              if appliedQuery.isEmpty {
                EmptyStateView(
                  symbol: "bubble.left.and.bubble.right", title: "No chats yet",
                  message: "Your conversations stay on this \(Platform.deviceName).")
              } else {
                EmptyStateView(
                  symbol: "magnifyingglass", title: "No results",
                  message: "Nothing matches \u{201C}\(appliedQuery)\u{201D}.")
              }
            }
            .padding(.top, Theme.Spacing.sm)
          } else if !rows.isEmpty || !relatedRows.isEmpty {
            chatGroups(rows, related: relatedRows)
          }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.lg)
      }
      .scrollDismissesKeyboard(.immediately)
      footer
    }
    .onChange(of: searchFocused) { _, focused in
      onSearchFocusChanged?(focused)
    }
    .onAppear {
      // Ready for search by meaning by the time the user types.
      appState.knowledge.indexChats(
        threads.filter { !$0.isDeleted && $0.modelContext != nil && !$0.turns.isEmpty })
    }
    .task(id: query) {
      // Results for the previous query must not linger while typing.
      relatedIDs = []
      let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
      // Clearing the search shows every chat at once; typing filters when it pauses.
      guard !text.isEmpty else {
        appliedQuery = ""
        return
      }
      try? await Task.sleep(for: .milliseconds(200))
      guard !Task.isCancelled else { return }
      appliedQuery = text
      guard text.count >= 3 else { return }
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled else { return }
      let liveChats = threads.filter { !$0.isDeleted && $0.modelContext != nil && !$0.turns.isEmpty }
      let hits = await appState.knowledge.relatedChats(text, in: liveChats, limit: 6)
      guard !Task.isCancelled else { return }
      relatedIDs = hits.map(\.thread.id)
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
              .frame(width: Theme.Size.target, height: Theme.Size.target)
              .contentShape(.rect)
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

  private static let collapsedProjectLimit = 6

  private var projectsSection: some View {
    let visibleProjects = showAllProjects ? projects : Array(projects.prefix(Self.collapsedProjectLimit))
    return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
      HStack {
        Text("Projects").eyebrowStyle().accessibilityAddTraits(.isHeader)
        Spacer()
        Button(action: onNewProject) {
          Image(systemName: "plus")
            .font(.system(.footnote, weight: .semibold))
            .foregroundStyle(Theme.Brand.glacier)
            .frame(width: Theme.Size.target, height: Theme.Size.target)
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
      ForEach(visibleProjects) { project in
        projectRow(project)
      }
      if projects.count > Self.collapsedProjectLimit {
        Button {
          withAppAnimation(Theme.Motion.easeOut) { showAllProjects.toggle() }
        } label: {
          HStack(spacing: Theme.Spacing.xs) {
            Text(
              showAllProjects
                ? String(localized: "Show fewer")
                : String(localized: "Show all (\(projects.count))"))
              .font(.footnote.weight(.medium))
              .foregroundStyle(Theme.Brand.glacier)
            Image(systemName: showAllProjects ? "chevron.up" : "chevron.down")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(Theme.Brand.glacier)
          }
          .padding(.horizontal, Theme.Spacing.sm)
          .frame(maxWidth: .infinity, minHeight: Theme.Size.target, alignment: .leading)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drawer.projects.toggle")
      }
    }
  }

  private func matchedProjectsSection(_ matched: [Project]) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
      Text("Projects")
        .eyebrowStyle()
        .accessibilityAddTraits(.isHeader)
        .padding(.horizontal, Theme.Spacing.sm)
      ForEach(matched) { project in
        projectRow(project)
      }
    }
  }

  private func projectRow(_ project: Project) -> some View {
    Button {
      searchFocused = false
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
            // At accessibility sizes one line holds only a word or two.
            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
          if isBusy(thread) {
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
        // Its reply is still being prepared or written into this chat.
        .disabled(isBusy(thread))
    }
    // The long-press menu as actions VoiceOver and Switch Control can reach.
    .accessibilityAction(named: thread.isPinned ? "Unpin" : "Pin") { onTogglePin(thread) }
    .accessibilityAction(named: "Rename") { onRename(thread) }
    .accessibilityAction(named: "Delete") {
      if !isBusy(thread) { onDelete(thread) }
    }
    .accessibilityIdentifier("drawer.row")
  }

  // MARK: - Footer

  private var footer: some View {
    VStack(spacing: 0) {
      Rectangle().fill(Theme.Surface.hairline).frame(height: Theme.Stroke.hairline)
      Button {
        searchFocused = false
        onSettings()
      } label: {
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
