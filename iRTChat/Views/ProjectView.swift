import SwiftData
import SwiftUI

/// A project: its name, instructions shared by its chats, shared files, and
/// its chats. Edits are saved when the screen closes.
struct ProjectView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss
  @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]

  let project: Project
  var onOpenChat: (ChatThread) -> Void
  var onNewChat: () -> Void
  var onDelete: () -> Void

  @State private var name = ""
  @State private var instructions = ""
  @State private var loaded = false
  @State private var showFiles = false
  @State private var readingFiles = 0
  @State private var confirmDelete = false
  @State private var files: [ChatDocument] = []

  private var chats: [ChatThread] {
    threads.filter { $0.projectID == project.id && !$0.turns.isEmpty }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Project name", text: $name)
            .font(.headline)
            .accessibilityIdentifier("project.name")
          Button {
            save()
            onNewChat()
          } label: {
            Label("New chat in this project", systemImage: "square.and.pencil")
          }
          .accessibilityIdentifier("project.newChat")
        }

        Section {
          TextEditor(text: $instructions)
            .frame(minHeight: 100)
            .accessibilityIdentifier("project.instructions")
        } header: {
          Text("Instructions")
        } footer: {
          Text("Every chat in this project follows these, e.g. \"Answer as a travel planner; I prefer trains.\"")
        }

        Section {
          ForEach(files) { file in
            HStack {
              Image(systemName: (DocumentKind(rawValue: file.kindRaw) ?? .text).symbol)
                .foregroundStyle(Color.accentColor)
              VStack(alignment: .leading) {
                Text(file.name).lineLimit(1)
                if file.pageCount > 0 {
                  Text("\(file.pageCount) pages").font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              if appState.knowledge.indexing.contains(file.id) {
                ProgressView().controlSize(.small)
              }
            }
            .accessibilityIdentifier("project.file")
          }
          .onDelete { offsets in
            for index in offsets { appState.knowledge.delete(files[index]) }
            reloadFiles()
          }
          if readingFiles > 0 {
            HStack {
              ProgressView().controlSize(.small)
              Text("Reading…").foregroundStyle(.secondary)
            }
          }
          Button {
            showFiles = true
          } label: {
            Label("Add files", systemImage: "plus")
          }
          .accessibilityIdentifier("project.addFiles")
        } header: {
          Text("Files")
        } footer: {
          Text("Shared by every chat in this project.")
        }

        if !chats.isEmpty {
          Section("Chats") {
            ForEach(chats) { thread in
              Button {
                save()
                onOpenChat(thread)
              } label: {
                VStack(alignment: .leading, spacing: 2) {
                  Text(thread.title).foregroundStyle(.primary).lineLimit(1)
                  Text(thread.updatedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .accessibilityIdentifier("project.chat")
            }
          }
        }

        Section {
          Button("Delete project", role: .destructive) { confirmDelete = true }
            .accessibilityIdentifier("project.delete")
        }
      }
      .navigationTitle(name.isEmpty ? String(localized: "Project") : name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            save()
            dismiss()
          }
          .accessibilityIdentifier("project.done")
        }
      }
      .fileImporter(
        isPresented: $showFiles, allowedContentTypes: DocumentIngestor.supportedTypes,
        allowsMultipleSelection: true
      ) { result in
        guard case .success(let urls) = result else { return }
        for url in urls { read(url) }
      }
      .confirmationDialog(
        "Delete \"\(name)\"?", isPresented: $confirmDelete, titleVisibility: .visible
      ) {
        Button(deleteTitle, role: .destructive) {
          onDelete()
          dismiss()
        }
      } message: {
        Text("Its chats and files will be removed from this iPhone.")
      }
      .onAppear {
        guard !loaded else { return }
        name = project.name
        instructions = project.instructions
        loaded = true
        reloadFiles()
      }
      .onDisappear(perform: save)
    }
  }

  private var deleteTitle: String {
    chats.isEmpty
      ? String(localized: "Delete project")
      : String(localized: "Delete project and \(chats.count) chats")
  }

  private func reloadFiles() {
    files = appState.knowledge.documents(projectID: project.id)
  }

  private func read(_ url: URL) {
    readingFiles += 1
    Task {
      defer { readingFiles -= 1 }
      do {
        let extracted = try await Task.detached(priority: .userInitiated) {
          try await DocumentIngestor.extract(from: url)
        }.value
        appState.knowledge.add(extracted, projectID: project.id)
        reloadFiles()
      } catch {
        appState.generationError = error.localizedDescription
      }
    }
  }

  private func save() {
    guard loaded, project.modelContext != nil else { return }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let changedInstructions = instructions != project.instructions
    if !trimmedName.isEmpty, trimmedName != project.name { project.name = trimmedName }
    if changedInstructions { project.instructions = instructions }
    project.updatedAt = Date()
    try? context.save()
    if changedInstructions { appState.projectInstructionsChanged(project.id) }
  }
}
