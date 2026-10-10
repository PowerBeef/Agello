import SwiftData
import SwiftUI

/// The side drawer: search, new chat, chats grouped by date, settings.
struct DrawerView: View {
  @Environment(AppState.self) private var appState
  @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]
  @Query(sort: \Project.updatedAt, order: .reverse) private var projects: [Project]
  @State private var query = ""
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
      if query.isEmpty { return thread.projectID == nil ? Row(thread: thread) : nil }
      let messages = thread.orderedTurns.map(\.text)
      return ThreadGrouping.match(query: query, title: thread.title, messages: messages)
        .map { Row(thread: thread, snippet: $0.snippet) }
    }
  }

  var body: some View {
    let rows = rows
    let relatedRows = query.isEmpty ? [] : related.filter { hit in !rows.contains { $0.id == hit.id } }
    VStack(spacing: 0) {
      header
      if query.isEmpty {
        projectsSection
      }
      if rows.isEmpty, relatedRows.isEmpty {
        Spacer()
        if query.isEmpty {
          ContentUnavailableView(
            "No chats yet", systemImage: "bubble.left.and.bubble.right",
            description: Text("Your conversations stay on this iPhone."))
        } else {
          ContentUnavailableView.search(text: query)
        }
        Spacer()
      } else {
        list(rows, related: relatedRows)
      }
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
      guard text.count >= 3 else { return }
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      let hits = await appState.knowledge.relatedChats(
        text, in: threads.filter { !$0.turns.isEmpty }, limit: 6)
      guard !Task.isCancelled else { return }
      related = hits.map { Row(thread: $0.thread) }
    }
  }

  private var header: some View {
    HStack(spacing: DS.spaceMD) {
      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
        TextField("Search chats", text: $query)
          .focused($searchFocused)
          .submitLabel(.search)
          .accessibilityIdentifier("drawer.search")
        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .foregroundStyle(.tertiary)
          }
          .accessibilityLabel("Clear search")
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .glassEffect(.regular, in: .capsule)
      Button(action: onNewChat) {
        Image(systemName: "square.and.pencil")
          .frame(width: DS.controlTarget, height: DS.controlTarget)
          .glassEffect(.regular.interactive(), in: .circle)
      }
      .accessibilityLabel("New chat")
      .accessibilityIdentifier("drawer.new")
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
  }

  private var projectsSection: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text("Projects")
          .font(.footnote.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button(action: onNewProject) {
          Image(systemName: "folder.badge.plus")
        }
        .accessibilityLabel("New project")
        .accessibilityIdentifier("drawer.newProject")
      }
      .padding(.horizontal, 12)
      .padding(.top, 6)
      .padding(.bottom, 4)
      ForEach(projects.prefix(6)) { project in
        Button {
          onOpenProject(project)
        } label: {
          Label(project.name, systemImage: "folder")
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("drawer.project")
      }
    }
    .padding(.horizontal, 8)
  }

  private func list(_ rows: [Row], related: [Row] = []) -> some View {
    var groups = ThreadGrouping.groups(
      rows, date: { $0.thread.updatedAt }, pinned: { $0.thread.isPinned })
    if !related.isEmpty {
      groups.append(.init(title: String(localized: "Related chats"), items: related))
    }
    return ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        ForEach(groups) { group in
          Text(group.title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 4)
          ForEach(group.items) { row in
            rowView(row)
          }
        }
      }
      .padding(.horizontal, 8)
      .padding(.bottom)
    }
    .scrollDismissesKeyboard(.immediately)
  }

  private func rowView(_ row: Row) -> some View {
    let thread = row.thread
    let selected = thread.id == appState.selectedThreadID
    return Button {
      searchFocused = false
      onSelect(thread)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(thread.title)
            .lineLimit(1)
          if appState.generatingThreadID == thread.id {
            ProgressView().controlSize(.mini)
          }
          if thread.isPinned {
            Spacer(minLength: 4)
            Image(systemName: "pin.fill")
              .font(.caption2)
              .foregroundStyle(.tertiary)
              .accessibilityLabel("Pinned")
          }
        }
        if let snippet = row.snippet {
          Text(snippet)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .background(
        selected ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: DS.radiusInner)
      )
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
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

  private var footer: some View {
    VStack(spacing: 0) {
      Divider()
      Button(action: onSettings) {
        HStack(spacing: DS.spaceMD) {
          Image(systemName: "gearshape")
            .frame(width: DS.iconLG, height: DS.iconLG)
            .glassEffect(.regular, in: .circle)
          Text("Settings")
          Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .contentShape(.rect)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("drawer.settings")
    }
  }
}
