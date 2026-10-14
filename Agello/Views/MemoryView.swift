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
          "iRTChat remembers lasting facts you share, like preferences or where you live, and uses them in new chats. Memories stay on this iPhone."
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
            draft = memory.text
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
          Text("The \(SystemPrompt.memoryLimit) most recent memories are used in chats.")
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
    .alert("Add memory", isPresented: $adding) {
      TextField("e.g. Prefers metric units", text: $draft)
        .accessibilityIdentifier("memory.field")
      Button("Save") { addMemory() }
      Button("Cancel", role: .cancel) {}
    }
    .alert("Edit memory", isPresented: isEditing) {
      TextField("Memory", text: $draft)
      Button("Save") { saveEdit() }
      Button("Cancel", role: .cancel) {}
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

  private var cleanedDraft: String {
    String(
      draft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(HelperTasks.maxMemoryLength))
  }

  private func addMemory() {
    guard !cleanedDraft.isEmpty else { return }
    context.insert(MemoryItem(text: cleanedDraft))
    save()
  }

  private func saveEdit() {
    guard let memory = editing else { return }
    if cleanedDraft.isEmpty {
      context.delete(memory)
    } else {
      memory.text = cleanedDraft
      memory.updatedAt = Date()
    }
    save()
  }

  private func save() {
    try? context.save()
    appState.memoriesChanged()
  }
}
