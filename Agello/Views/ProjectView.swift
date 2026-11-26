import SwiftData
import SwiftUI
import UniformTypeIdentifiers

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

  fileprivate enum ImporterMode {
    case files
    case folder
  }

  @State private var name = ""
  @State private var instructions = ""
  @State private var loaded = false
  @State private var showImporter = false
  @State private var importerMode: ImporterMode = .files
  @State private var linkedFolder: FolderBookmarks.LinkedFolder?
  @State private var readingFiles = 0
  @State private var confirmDelete = false
  @State private var files: [ChatDocument] = []
  @State private var inlineError: String?
  @State private var syncStatus: String?
  @State private var activeTasks: [UUID: Task<Void, Never>] = [:]

  private var chats: [ChatThread] {
    threads.filter { $0.projectID == project.id && !$0.turns.isEmpty }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack(spacing: Theme.Spacing.md) {
            TintTile(symbol: "folder.fill", tint: Theme.Brand.glacier, size: 40)
            TextField(
              "Project name", text: $name,
              prompt: Text("Project name").foregroundStyle(Theme.Text.placeholder)
            )
            .font(.system(.title3, weight: .semibold))
            .foregroundStyle(Theme.Text.primary)
            .accessibilityIdentifier("project.name")
          }
          .padding(.vertical, Theme.Spacing.xs)
          Button {
            save()
            onNewChat()
          } label: {
            Label("New chat in this project", systemImage: "square.and.pencil")
              .foregroundStyle(Theme.Brand.glacier)
          }
          .accessibilityIdentifier("project.newChat")
        }
        .themedRow()

        Section {
          TextEditor(text: $instructions)
            .accessibilityLabel("Instructions")
            .frame(minHeight: 100)
            .scrollContentBackground(.hidden)
            .foregroundStyle(Theme.Text.primary)
            .overlay(alignment: .topLeading) {
              if instructions.isEmpty {
                Text("Answer as a travel planner; I prefer trains.")
                  .foregroundStyle(Theme.Text.placeholder)
                  .padding(.top, Theme.Spacing.sm)
                  .padding(.leading, Theme.Spacing.xs)
                  .allowsHitTesting(false)
                  .accessibilityHidden(true)
              }
            }
            .accessibilityIdentifier("project.instructions")
        } header: {
          Text("Instructions").eyebrowStyle()
        } footer: {
          Text("Every chat in this project follows these.")
        }
        .themedRow()

        filesSection
        chatsSection

        Section {
          Button("Delete project", role: .destructive) { confirmDelete = true }
            .accessibilityIdentifier("project.delete")
        }
        .themedRow()
      }
      .themedList(Theme.Brand.glacier)
      .navigationTitle(name.isEmpty ? String(localized: "Project") : name)
      .inlineTitleDisplay()
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
        isPresented: $showImporter,
        allowedContentTypes: importerMode == .folder ? [.folder] : DocumentIngestor.supportedTypes,
        allowsMultipleSelection: importerMode == .files
      ) { result in
        handleImportResult(result, mode: importerMode)
      }
      .confirmationDialog(
        "Delete \"\(name)\"?", isPresented: $confirmDelete, titleVisibility: .visible
      ) {
        Button(deleteTitle, role: .destructive) {
          cancelActiveTasks()
          FolderBookmarks.remove(for: project.id)
          onDelete()
          dismiss()
        }
      } message: {
        Text("Its chats and files will be removed from this \(Platform.deviceName).")
      }
      .onAppear {
        guard !loaded else { return }
        name = project.name
        instructions = project.instructions
        loaded = true
        linkedFolder = FolderBookmarks.folder(for: project.id)
        reloadFiles()
      }
      .onDisappear {
        cancelActiveTasks()
        save()
      }
    }
  }
}

private extension ProjectView {
  var filesSection: some View {
    Section {
      ForEach(files) { file in
        fileRow(file)
      }
      .onDelete { offsets in
        guard !appState.isBusy else { return }
        for index in offsets {
          let doc = files[index]
          FolderBookmarks.forgetSyncedFile(doc.name, for: project.id)
          appState.knowledge.delete(doc)
        }
        linkedFolder = FolderBookmarks.folder(for: project.id)
        reloadFiles()
      }
      .deleteDisabled(appState.isBusy)
      if readingFiles > 0 {
        HStack {
          ProgressView().controlSize(.small)
          Text("Reading…").foregroundStyle(Theme.Text.secondary)
        }
      }
      if let error = inlineError {
        errorRow(error)
      }
      if let status = syncStatus {
        Text(status)
          .font(.footnote)
          .foregroundStyle(Theme.Text.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("project.syncStatus")
      }
      Button {
        importerMode = .files
        showImporter = true
      } label: {
        Label("Add files", systemImage: "plus")
          .foregroundStyle(Theme.Brand.glacier)
      }
      .accessibilityIdentifier("project.addFiles")
      linkedFolderControl
    } header: {
      Text("Files").eyebrowStyle()
    } footer: {
      Text("Shared by every chat in this project.")
    }
    .themedRow()
  }

  func fileRow(_ file: ChatDocument) -> some View {
    HStack(spacing: Theme.Spacing.md) {
      TintTile(symbol: (DocumentKind(rawValue: file.kindRaw) ?? .text).symbol)
      VStack(alignment: .leading) {
        Text(file.name).lineLimit(1).foregroundStyle(Theme.Text.primary)
        if file.pageCount > 0 {
          Text("\(file.pageCount) pages").font(.caption).foregroundStyle(Theme.Text.tertiary)
        }
        if appState.knowledge.searchesByKeywords(file) {
          HStack(spacing: Theme.Spacing.sm) {
            Text("Keyword search").font(.caption).foregroundStyle(Theme.Text.tertiary)
              .accessibilityIdentifier("project.file.keywordSearch")
            // Indexing failed once; it's not retried on its own.
            Button("Index again") {
              appState.knowledge.reindex(file)
              reloadFiles()
            }
            .font(.caption)
            .foregroundStyle(Theme.Brand.glacier)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("project.file.reindex")
          }
        }
      }
      Spacer()
      if appState.knowledge.indexing.contains(file.id) {
        ProgressView().controlSize(.small)
      }
    }
    .accessibilityIdentifier("project.file")
  }

  func errorRow(_ error: String) -> some View {
    HStack(alignment: .top, spacing: Theme.Spacing.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(Theme.Status.critical)
        .accessibilityHidden(true)
      Text(error)
        .font(.footnote)
        .foregroundStyle(Theme.Status.critical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      Button {
        inlineError = nil
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(Theme.Text.tertiary)
          .frame(width: Theme.Size.target, height: Theme.Size.target)
          .contentShape(.rect)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Dismiss error")
    }
    .accessibilityIdentifier("project.error")
  }

  @ViewBuilder
  var linkedFolderControl: some View {
    if let folder = linkedFolder {
      HStack(spacing: Theme.Spacing.sm) {
        TintTile(symbol: "folder.badge.gearshape", tint: Theme.Brand.teal)
        VStack(alignment: .leading, spacing: 2) {
          Text(folder.folderName)
            .font(.subheadline)
            .foregroundStyle(Theme.Text.primary)
            .lineLimit(1)
          if let synced = folder.lastSyncedAt {
            Text("Synced \(synced.formatted(date: .abbreviated, time: .shortened))")
              .font(.caption2)
              .foregroundStyle(Theme.Text.tertiary)
          }
        }
        Spacer(minLength: Theme.Spacing.xs)
        Button("Sync") { syncLinkedFolder() }
          .font(.caption.weight(.semibold))
          .buttonStyle(.bordered)
          .tint(Theme.Brand.teal)
          .disabled(readingFiles > 0)
          .accessibilityIdentifier("project.syncFolder")
        Button {
          FolderBookmarks.remove(for: project.id)
          linkedFolder = nil
          syncStatus = nil
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(Theme.Text.tertiary)
            .frame(minWidth: Theme.Size.target, minHeight: Theme.Size.target)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Unlink folder")
        .accessibilityIdentifier("project.unlinkFolder")
      }
    } else {
      Button {
        importerMode = .folder
        showImporter = true
      } label: {
        Label("Link folder", systemImage: "folder.badge.plus")
          .foregroundStyle(Theme.Brand.teal)
      }
      .accessibilityIdentifier("project.linkFolder")
    }
  }

  @ViewBuilder
  var chatsSection: some View {
    if !chats.isEmpty {
      Section {
        ForEach(chats) { thread in
          Button {
            save()
            onOpenChat(thread)
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(thread.title)
                  .font(.rowTitle)
                  .foregroundStyle(Theme.Text.primary)
                  .lineLimit(1)
                Text(thread.updatedAt.formatted(date: .abbreviated, time: .omitted))
                  .font(.caption)
                  .foregroundStyle(Theme.Text.tertiary)
              }
              Spacer()
              Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Text.tertiary)
            }
          }
          .accessibilityIdentifier("project.chat")
        }
      } header: {
        Text("Chats").eyebrowStyle()
      }
      .themedRow()
    }
  }

  var deleteTitle: String {
    chats.isEmpty
      ? String(localized: "Delete project")
      : String(localized: "Delete project and \(chats.count) chats")
  }

  func reloadFiles() {
    guard !project.isDeleted, project.modelContext != nil else {
      files = []
      return
    }
    files = appState.knowledge.documents(projectID: project.id)
  }

  func cancelActiveTasks() {
    for task in activeTasks.values { task.cancel() }
    activeTasks.removeAll()
  }

  func handleImportResult(_ result: Result<[URL], Error>, mode: ImporterMode) {
    switch result {
    case .failure(let error):
      if !(error is CancellationError) { inlineError = error.localizedDescription }
    case .success(let urls):
      inlineError = nil
      switch mode {
      case .files:
        for url in urls { read(url) }
      case .folder:
        guard let folderURL = urls.first else { return }
        do {
          linkedFolder = try FolderBookmarks.save(folderURL: folderURL, for: project.id)
          syncStatus = nil
          syncLinkedFolder()
        } catch {
          inlineError = error.localizedDescription
        }
      }
    }
  }

  func read(_ url: URL) {
    let taskID = UUID()
    let projectID = project.id
    inlineError = nil
    readingFiles += 1
    let task = Task {
      defer {
        readingFiles = max(0, readingFiles - 1)
        activeTasks.removeValue(forKey: taskID)
      }
      let extraction = Task.detached(priority: .userInitiated) {
        try await DocumentIngestor.extract(from: url)
      }
      do {
        let extracted = try await withTaskCancellationHandler {
          try await extraction.value
        } onCancel: {
          extraction.cancel()
        }
        guard !Task.isCancelled, !project.isDeleted, project.modelContext != nil else { return }
        appState.knowledge.add(extracted, projectID: projectID)
        reloadFiles()
      } catch {
        guard !Task.isCancelled, !(error is CancellationError), !project.isDeleted else { return }
        inlineError = error.localizedDescription
      }
    }
    activeTasks[taskID] = task
  }

  func syncLinkedFolder() {
    let taskID = UUID()
    let projectID = project.id
    let existingSizes = Dictionary(
      files.map { ($0.name, $0.byteCount) }, uniquingKeysWith: { _, latest in latest })
    let priorFingerprints = linkedFolder?.syncedFiles ?? [:]
    inlineError = nil
    syncStatus = nil
    readingFiles += 1
    let task = Task {
      defer {
        readingFiles = max(0, readingFiles - 1)
        activeTasks.removeValue(forKey: taskID)
        if !project.isDeleted { linkedFolder = FolderBookmarks.folder(for: projectID) }
      }
      let extraction = Task.detached(priority: .utility) {
        try await FolderBookmarks.scanChanges(
          for: projectID, existingSizes: existingSizes, priorFingerprints: priorFingerprints)
      }
      do {
        guard
          let outcome = try await withTaskCancellationHandler(
            operation: { try await extraction.value },
            onCancel: { extraction.cancel() })
        else { return }
        guard !Task.isCancelled, !project.isDeleted, project.modelContext != nil else { return }
        applySyncOutcome(outcome, projectID: projectID)
      } catch {
        guard !Task.isCancelled, !(error is CancellationError), !project.isDeleted else { return }
        inlineError = error.localizedDescription
      }
    }
    activeTasks[taskID] = task
  }

  func applySyncOutcome(_ outcome: FolderBookmarks.SyncOutcome, projectID: UUID) {
    var fingerprints = outcome.unchangedFingerprints
    for item in outcome.synced {
      for old in files where old.name == item.document.name {
        appState.knowledge.delete(old)
      }
      if appState.knowledge.add(item.document, projectID: projectID) != nil {
        fingerprints[item.document.name] = item.fingerprint
      }
    }
    reloadFiles()
    if outcome.failed.isEmpty || !outcome.synced.isEmpty || !outcome.unchangedFingerprints.isEmpty {
      FolderBookmarks.markSynced(for: projectID, syncedFiles: fingerprints)
    }
    inlineError = outcome.errorSummary
    syncStatus = outcome.statusSummary
  }

  func save() {
    guard loaded, !project.isDeleted, project.modelContext != nil else { return }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let changedName = !trimmedName.isEmpty && trimmedName != project.name
    let changedInstructions = instructions != project.instructions
    guard changedName || changedInstructions else { return }
    if changedName { project.name = trimmedName }
    if changedInstructions { project.instructions = instructions }
    project.updatedAt = Date()
    try? context.save()
    SpotlightIndex.indexProjects([project])
    if changedInstructions { appState.projectInstructionsChanged(project.id) }
  }
}
