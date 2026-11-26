import SwiftData
import SwiftUI

/// Saved memories: on/off, search, review, edit, add, delete. Changes reach the
/// open chat before its next message.
struct MemoryView: View {
  private enum EditorMode: Identifiable {
    case add
    case edit(MemoryItem)

    var id: String {
      switch self {
      case .add: return "add"
      case .edit(let item): return item.id.uuidString
      }
    }

    var title: String {
      switch self {
      case .add: return String(localized: "Add memory")
      case .edit: return String(localized: "Edit memory")
      }
    }

    var fieldIdentifier: String {
      switch self {
      case .add: return "memory.field"
      case .edit: return "memory.edit.field"
      }
    }
  }

  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var context
  @Query(sort: \MemoryItem.updatedAt, order: .reverse) private var memories: [MemoryItem]

  @State private var editorMode: EditorMode?
  @State private var draft = ""
  @State private var searchText = ""
  @State private var confirmDeleteAll = false
  @FocusState private var editorFocused: Bool

  private var trimmedSearch: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var filteredMemories: [MemoryItem] {
    guard !trimmedSearch.isEmpty else { return memories }
    return memories.filter {
      $0.text.range(of: trimmedSearch, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
  }

  var body: some View {
    @Bindable var appState = appState
    let visibleMemories = filteredMemories
    Form {
      Section {
        Toggle("Use memory", isOn: $appState.memoryEnabled)
          .tint(Theme.Mode.think.tint)
          .accessibilityIdentifier("memory.enabled")
      } footer: {
        Text(
          "Agello remembers lasting facts you share, like preferences or where you live, and uses them in new chats. Memories stay on this \(Platform.deviceName)."
        )
        .foregroundStyle(Theme.Text.tertiary)
      }
      .themedRow()

      Section {
        if memories.isEmpty {
          Text("Nothing saved yet.")
            .foregroundStyle(Theme.Text.tertiary)
        } else if visibleMemories.isEmpty {
          Text("No memories match \u{201C}\(trimmedSearch)\u{201D}.")
            .foregroundStyle(Theme.Text.tertiary)
        }
        ForEach(visibleMemories) { memory in
          Button {
            draft = String(memory.text.prefix(HelperTasks.maxMemoryLength))
            editorMode = .edit(memory)
          } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
              TintTile(symbol: "brain.head.profile", tint: Theme.Mode.think.tint)
              Text(memory.text)
                .foregroundStyle(Theme.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .accessibilityIdentifier("memory.row")
        }
        .onDelete { offsets in
          Haptics.warning()
          for index in offsets { context.delete(visibleMemories[index]) }
          save()
        }
        Button {
          draft = ""
          editorMode = .add
        } label: {
          Label("Add memory", systemImage: "plus")
            .foregroundStyle(Theme.Mode.think.tint)
        }
        .accessibilityIdentifier("memory.add")
      } header: {
        Text("Saved memories").eyebrowStyle()
      } footer: {
        if memories.count > SystemPrompt.memoryLimit {
          Text(
            "Each chat uses the \(SystemPrompt.recentMemories) most recent memories and the \(SystemPrompt.memoryLimit - SystemPrompt.recentMemories) closest to what it's about."
          )
          .foregroundStyle(Theme.Text.tertiary)
        }
      }
      .themedRow()

      if !memories.isEmpty {
        Section {
          Button("Delete all memories", role: .destructive) {
            Haptics.warning()
            confirmDeleteAll = true
          }
          .accessibilityIdentifier("memory.deleteAll")
        }
        .themedRow()
      }
    }
    .searchable(text: $searchText, prompt: Text("Search memories"))
    .themedList(Theme.Mode.think.tint)
    .navigationTitle("Memory")
    .inlineTitleDisplay()
    .onChange(of: appState.memoryEnabled) { _, _ in Haptics.selection() }
    .onChange(of: draft) { _, value in
      if value.count > HelperTasks.maxMemoryLength {
        draft = String(value.prefix(HelperTasks.maxMemoryLength))
      }
    }
    .sheet(item: $editorMode, onDismiss: { draft = "" }) { mode in
      memoryEditorSheet(mode: mode)
    }
    .confirmationDialog(
      deleteAllTitle, isPresented: $confirmDeleteAll, titleVisibility: .visible
    ) {
      Button(deleteAllActionLabel, role: .destructive) {
        Haptics.warning()
        for memory in memories { context.delete(memory) }
        save()
      }
    } message: {
      Text("All saved memories will be removed from this \(Platform.deviceName).")
    }
  }

  private func memoryEditorSheet(mode: EditorMode) -> some View {
    NavigationStack {
      Form {
        Section {
          TextEditor(text: $draft)
            .scrollContentBackground(.hidden)
            .foregroundStyle(Theme.Text.primary)
            .frame(minHeight: 110)
            .focused($editorFocused)
            .overlay(alignment: .topLeading) {
              if draft.isEmpty {
                Text("e.g. Prefers metric units")
                  .foregroundStyle(Theme.Text.placeholder)
                  .padding(.top, Theme.Spacing.sm)
                  .padding(.leading, Theme.Spacing.xs)
                  .allowsHitTesting(false)
                  .accessibilityHidden(true)
              }
            }
            .accessibilityLabel(mode.title)
            .accessibilityIdentifier(mode.fieldIdentifier)
        } header: {
          Text("Memory").eyebrowStyle()
        } footer: {
          Text(draftCounter)
            .monospacedDigit()
            .foregroundStyle(
              draft.count >= HelperTasks.maxMemoryLength - 15
                ? Theme.Status.guarded : Theme.Text.tertiary)
        }
        .themedRow()
      }
      .scrollDismissesKeyboard(.interactively)
      .themedList(Theme.Mode.think.tint)
      .navigationTitle(mode.title)
      .inlineTitleDisplay()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { editorMode = nil }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { commit(mode) }
            .disabled(cleanedDraft.isEmpty)
            .accessibilityIdentifier("memory.save")
        }
      }
      .onAppear { editorFocused = true }
    }
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
  }

  private var deleteAllTitle: String {
    memories.count == 1
      ? String(localized: "Delete 1 memory?")
      : String(localized: "Delete all \(memories.count) memories?")
  }

  private var deleteAllActionLabel: String {
    memories.count == 1
      ? String(localized: "Delete 1 memory")
      : String(localized: "Delete all (\(memories.count))")
  }

  private var draftCounter: String {
    String(localized: "\(draft.count)/\(HelperTasks.maxMemoryLength)")
  }

  private var cleanedDraft: String {
    String(
      draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(HelperTasks.maxMemoryLength))
  }

  private func commit(_ mode: EditorMode) {
    guard !cleanedDraft.isEmpty else { return }
    switch mode {
    case .add:
      context.insert(MemoryItem(text: cleanedDraft))
    case .edit(let memory):
      memory.text = cleanedDraft
      memory.updatedAt = Date()
    }
    editorMode = nil
    draft = ""
    save()
    Haptics.success()
  }

  private func save() {
    try? context.save()
    appState.memoriesChanged()
  }
}
