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
  /// Value-only cached drawer sections keyed by `(appliedQuery, threadFingerprint, relatedIDs)`
  /// so keystrokes, focus changes, and selection changes skip `ThreadGrouping.groups` and turn
  /// faulting without ever retaining deleted SwiftData `@Model` references.
  @State private var cachedGroupsKey: GroupsCacheKey?
  @State private var cachedGroups: [ThreadGrouping.Group<CachedRow>] = []
  @State private var showAllProjects = false
  @State private var movingThreadID: UUID?
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

  fileprivate struct CachedRow: Identifiable, Equatable {
    var id: UUID
    var snippet: String?
  }

  private struct ThreadStamp: Equatable {
    var id: UUID
    var title: String
    var updatedAt: Date
    var isPinned: Bool
    var projectID: UUID?
    var activeLeafID: UUID?
  }

  private struct GroupsCacheKey: Equatable {
    var query: String
    var stamps: [ThreadStamp]
    var relatedIDs: [UUID]
  }

  private struct MatchedRow {
    var thread: ChatThread
    var snippet: String?
  }

  private func isLiveNonEmpty(_ thread: ChatThread) -> Bool {
    guard !thread.isDeleted, thread.modelContext != nil else { return false }
    return thread.activeLeafID != nil || !thread.turns.isEmpty
  }

  private func buildGroups(
    query: String,
    liveThreads: [ChatThread],
    liveThreadsByID: [UUID: ChatThread],
    relatedIDs: [UUID]
  ) -> [ThreadGrouping.Group<CachedRow>] {
    let matched: [MatchedRow] = liveThreads.compactMap { thread in
      if query.isEmpty { return thread.projectID == nil ? MatchedRow(thread: thread) : nil }
      // Check title match before faulting `thread.orderedTurns`.
      return ThreadGrouping.match(query: query, title: thread.title) {
        thread.orderedTurns.map(\.text)
      }
      .map { MatchedRow(thread: thread, snippet: $0.snippet) }
    }
    var groups = ThreadGrouping.groups(
      matched, date: { $0.thread.updatedAt }, pinned: { $0.thread.isPinned }
    ).map { group in
      ThreadGrouping.Group(
        title: group.title,
        items: group.items.map { CachedRow(id: $0.thread.id, snippet: $0.snippet) })
    }
    if !query.isEmpty, !relatedIDs.isEmpty {
      let matchedIDs = Set(matched.map(\.thread.id))
      let relatedRows = relatedIDs.compactMap { id -> CachedRow? in
        guard !matchedIDs.contains(id), liveThreadsByID[id] != nil else { return nil }
        return CachedRow(id: id)
      }
      if !relatedRows.isEmpty {
        groups.append(.init(title: String(localized: "Related chats"), items: relatedRows))
      }
    }
    return groups
  }

  /// Projects matching the active search query so projects beyond the collapsed preview remain
  /// discoverable via search as well as "Show all".
  private var matchingProjects: [Project] {
    let trimmed = appliedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    return projects.filter { project in
      guard !project.isDeleted, project.modelContext != nil else { return false }
      return project.name.range(of: trimmed, options: options) != nil
        || project.instructions.range(of: trimmed, options: options) != nil
    }
  }

  private func isBusy(_ thread: ChatThread) -> Bool {
    appState.generatingThreadID == thread.id || appState.preparingThreadID == thread.id
  }

  var body: some View {
    let liveThreads = threads.filter(isLiveNonEmpty)
    let liveThreadsByID = Dictionary(
      liveThreads.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let stamps = liveThreads.map {
      ThreadStamp(
        id: $0.id, title: $0.title, updatedAt: $0.updatedAt,
        isPinned: $0.isPinned, projectID: $0.projectID, activeLeafID: $0.activeLeafID)
    }
    let trimmedQuery = appliedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let currentKey = GroupsCacheKey(query: trimmedQuery, stamps: stamps, relatedIDs: relatedIDs)
    let groups =
      cachedGroupsKey == currentKey
      ? cachedGroups
      : buildGroups(
        query: trimmedQuery, liveThreads: liveThreads,
        liveThreadsByID: liveThreadsByID, relatedIDs: relatedIDs)
    let hasChatRows = groups.contains { group in
      group.items.contains { liveThreadsByID[$0.id] != nil }
    }
    let matchedProjects = matchingProjects
    ScrollView {
      VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
        if trimmedQuery.isEmpty {
          projectsSection
        } else if !matchedProjects.isEmpty {
          matchedProjectsSection(matchedProjects)
        }
        if !hasChatRows, matchedProjects.isEmpty {
          Group {
            if trimmedQuery.isEmpty {
              EmptyStateView(
                symbol: "bubble.left.and.bubble.right", title: "No chats yet",
                message: "Your conversations stay on this \(Platform.deviceName).")
            } else {
              EmptyStateView(
                symbol: "magnifyingglass", title: "No results",
                message: "Nothing matches \u{201C}\(trimmedQuery)\u{201D}.")
            }
          }
          .padding(.top, Theme.Spacing.sm)
        } else if hasChatRows {
          chatGroups(groups, threadsByID: liveThreadsByID)
        }
      }
      .padding(.horizontal, Theme.Spacing.md)
      .padding(.top, Theme.Spacing.xs)
      .padding(.bottom, Theme.Spacing.lg)
    }
    .scrollDismissesKeyboard(.immediately)
    .scrollEdgeEffectStyle(.soft, for: .vertical)
    .safeAreaBar(edge: .top, spacing: 0) {
      header
    }
    .safeAreaBar(edge: .bottom, spacing: 0) {
      footer
    }
    .onChange(of: currentKey, initial: true) { _, key in
      guard cachedGroupsKey != key else { return }
      cachedGroups = buildGroups(
        query: key.query, liveThreads: liveThreads,
        liveThreadsByID: liveThreadsByID, relatedIDs: key.relatedIDs)
      cachedGroupsKey = key
    }
    .onChange(of: searchFocused) { _, focused in
      onSearchFocusChanged?(focused)
    }
    .onAppear {
      // Ready for search by meaning by the time the user types.
      appState.knowledge.indexChats(threads.filter(isLiveNonEmpty))
    }
    .confirmationDialog(
      "Move to project",
      isPresented: Binding(
        get: { movingThreadID != nil },
        set: { if !$0 { movingThreadID = nil } }),
      titleVisibility: .visible
    ) {
      if let threadID = movingThreadID, let thread = liveThreadsByID[threadID] {
        ForEach(projects.filter { !$0.isDeleted && $0.modelContext != nil }) { project in
          Button(project.name) {
            onMove(thread, project.id)
            movingThreadID = nil
          }
          .disabled(thread.projectID == project.id)
        }
        if thread.projectID != nil {
          Button("Remove from project") {
            onMove(thread, nil)
            movingThreadID = nil
          }
        }
      }
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
      let liveChats = threads.filter(isLiveNonEmpty)
      let hits = await appState.knowledge.relatedChats(text, in: liveChats, limit: 6)
      guard !Task.isCancelled else { return }
      relatedIDs = hits.map(\.thread.id)
    }
  }
}

private extension DrawerView {
  // MARK: - Header

  var header: some View {
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

  static let collapsedProjectLimit = 6

  var projectsSection: some View {
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
          Haptics.selection()
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
              .accessibilityHidden(true)
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

  func matchedProjectsSection(_ matched: [Project]) -> some View {
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

  func projectRow(_ project: Project) -> some View {
    Button {
      searchFocused = false
      onOpenProject(project)
    } label: {
      HStack(spacing: Theme.Spacing.md) {
        TintTile(symbol: "folder.fill", tint: Theme.Brand.glacier)
        Text(project.name)
          .font(.rowTitle)
          .foregroundStyle(Theme.Text.primary)
          .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
        Spacer(minLength: 0)
      }
      .drawerRow(selected: false)
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("drawer.project")
  }

  // MARK: - Chats

  func chatGroups(
    _ groups: [ThreadGrouping.Group<CachedRow>], threadsByID: [UUID: ChatThread]
  ) -> some View {
    LazyVStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
      ForEach(groups) { group in
        let resolved: [(thread: ChatThread, snippet: String?)] = group.items.compactMap { row in
          guard let thread = threadsByID[row.id] else { return nil }
          return (thread, row.snippet)
        }
        if !resolved.isEmpty {
          Text(group.title)
            .eyebrowStyle()
            // Tests and VoiceOver read the title as written ("Pinned").
            .accessibilityLabel(group.title)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.top, Theme.Spacing.md)
            .padding(.bottom, Theme.Spacing.xs)
          ForEach(resolved, id: \.thread.id) { entry in
            rowView(thread: entry.thread, snippet: entry.snippet)
          }
        }
      }
    }
  }

  func rowView(thread: ChatThread, snippet: String?) -> some View {
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
        if let snippet {
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
    .modifier(MoveToProjectAccessibilityAction(enabled: !projects.isEmpty) { movingThreadID = thread.id })
    .accessibilityAction(named: "Delete") {
      if !isBusy(thread) { onDelete(thread) }
    }
    .accessibilityIdentifier("drawer.row")
  }

  // MARK: - Footer

  var footer: some View {
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
            .accessibilityHidden(true)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .frame(minHeight: Theme.Size.target + Theme.Spacing.md)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .keyboardShortcut(",", modifiers: .command)
      .accessibilityIdentifier("drawer.settings")
    }
  }
}

private struct MoveToProjectAccessibilityAction: ViewModifier {
  let enabled: Bool
  let action: () -> Void

  func body(content: Content) -> some View {
    if enabled {
      content.accessibilityAction(named: String(localized: "Move to project"), action)
    } else {
      content
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
