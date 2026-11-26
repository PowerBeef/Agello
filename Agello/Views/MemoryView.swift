import SwiftData
import SwiftUI

/// Saved memories: on/off, review, edit, add, delete. Changes reach the
/// open chat before its next message.
struct MemoryView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var context
  @Query(sort: \MemoryItem.updatedAt, order: .reverse) private var memories: [MemoryItem]

  @State private var editing: MemoryItem?
  @State private var adding = false
  @State private var draft = ""
  @State private var confirmDeleteAll = false

  var body: some View {
    @Bindable var appState = appState
    Form {
      Section {
        Toggle("Use memory", isOn: $appState.memoryEnabled)
          .accessibilityIdentifier("memory.enabled")
      } footer: {
        Text(
          "Agello remembers lasting facts you share, like preferences or where you live, and uses them in new chats. Memories stay on this \(Platform.deviceName)."
        )
      }
      .themedRow()

      Section {
        if memories.isEmpty {
          Text("Nothing saved yet.")
            .foregroundStyle(Theme.Text.tertiary)
        }
        ForEach(memories) { memory in
          Button {
            draft = String(memory.text.prefix(HelperTasks.maxMemoryLength))
            editing = memory
          } label: {
            HStack(spacing: Theme.Spacing.md) {
              TintTile(symbol: "brain.head.profile", tint: Theme.Brand.lavender)
              Text(memory.text)
                .foregroundStyle(Theme.Text.primary)
            }
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .accessibilityIdentifier("memory.row")
        }
        .onDelete { offsets in
          for index in offsets { context.delete(memories[index]) }
          save()
        }
        Button {
          draft = ""
          adding = true
        } label: {
          Label("Add memory", systemImage: "plus")
            .foregroundStyle(Theme.Brand.lavender)
        }
        .accessibilityIdentifier("memory.add")
      } header: {
        Text("Saved memories")
      } footer: {
        if memories.count > SystemPrompt.memoryLimit {
          Text("Each chat uses the \(SystemPrompt.recentMemories) most recent memories and the \(SystemPrompt.memoryLimit - SystemPrompt.recentMemories) closest to what it's about.")
        }
      }
      .themedRow()

      if !memories.isEmpty {
        Section {
          Button("Delete all memories", role: .destructive) { confirmDeleteAll = true }
            .accessibilityIdentifier("memory.deleteAll")
        }
        .themedRow()
      }
    }
    .themedList(Theme.Brand.lavender)
    .navigationTitle("Memory")
    .onChange(of: draft) { _, value in
      if value.count > HelperTasks.maxMemoryLength {
        draft = String(value.prefix(HelperTasks.maxMemoryLength))
      }
    }
    .alert("Add memory", isPresented: $adding) {
      TextField("e.g. Prefers metric units", text: $draft)
        .accessibilityIdentifier("memory.field")
      Button("Save") { addMemory() }
        .disabled(cleanedDraft.isEmpty)
      Button("Cancel", role: .cancel) { draft = "" }
    } message: {
      Text(draftCounter)
    }
    .alert("Edit memory", isPresented: isEditing) {
      TextField("Memory", text: $draft)
        .accessibilityIdentifier("memory.edit.field")
      Button("Save") { saveEdit() }
        .disabled(cleanedDraft.isEmpty)
      Button("Cancel", role: .cancel) { draft = "" }
    } message: {
      Text(draftCounter)
    }
    .confirmationDialog(
      "Delete all memories?", isPresented: $confirmDeleteAll, titleVisibility: .visible
    ) {
      Button("Delete all", role: .destructive) {
        for memory in memories { context.delete(memory) }
        save()
      }
    }
  }

  private var isEditing: Binding<Bool> {
    Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })
  }

  private var draftCounter: String {
    String(localized: "\(draft.count)/\(HelperTasks.maxMemoryLength) characters")
  }

  private var cleanedDraft: String {
    String(
      draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(HelperTasks.maxMemoryLength))
  }

  private func addMemory() {
    guard !cleanedDraft.isEmpty else { return }
    context.insert(MemoryItem(text: cleanedDraft))
    draft = ""
    save()
  }

  private func saveEdit() {
    guard let memory = editing, !cleanedDraft.isEmpty else { return }
    memory.text = cleanedDraft
    memory.updatedAt = Date()
    editing = nil
    draft = ""
    save()
  }

  private func save() {
    try? context.save()
    appState.memoriesChanged()
  }
}
