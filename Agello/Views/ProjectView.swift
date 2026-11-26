import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// A project: its name, instructions shared by its chats, shared files, and
/// its chats. Edits are saved when the screen closes.
struct ProjectView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.modelContext) private var context
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var typeSize
  @Query private var threads: [ChatThread]

  let project: Project
  var onOpenChat: (ChatThread) -> Void
  var onNewChat: () -> Void
  var onDelete: () -> Void

  init(
    project: Project,
    onOpenChat: @escaping (ChatThread) -> Void,
    onNewChat: @escaping () -> Void,
    onDelete: @escaping () -> Void
  ) {
    self.project = project
    self.onOpenChat = onOpenChat
    self.onNewChat = onNewChat
    self.onDelete = onDelete
    let projectID = project.id
    _threads = Query(
      filter: #Predicate<ChatThread> { $0.projectID == projectID },
      sort: [SortDescriptor(\ChatThread.updatedAt, order: .reverse)])
  }

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
  @State private var syncProgress: (completed: Int, total: Int)?
  @State private var confirmDelete = false
  @State private var files: [ChatDocument] = []
  @State private var inlineError: String?
  @State private var syncStatus: String?
  @State private var activeTasks: [UUID: Task<Void, Never>] = [:]

  private var chats: [ChatThread] {
    threads.filter {
      !$0.isDeleted && $0.modelContext != nil && ($0.activeLeafID != nil || !$0.turns.isEmpty)
    }
  }

  var body: some View {
    let projectChats = chats
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
            .foregroundStyle(Theme.Text.tertiary)
        }
        .themedRow()

        filesSection
        chatsSection(projectChats)

        Section {
          Button("Delete project", role: .destructive) {
            Haptics.warning()
            confirmDelete = true
          }
          .disabled(readingFiles > 0)
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
        Button(deleteTitle(chatCount: projectChats.count), role: .destructive) {
          Haptics.warning()
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
        guard !appState.isBusy, readingFiles == 0 else { return }
        Haptics.warning()
        for index in offsets {
          let doc = files[index]
          FolderBookmarks.forgetSyncedFile(doc.name, for: project.id)
          appState.knowledge.delete(doc)
        }
        linkedFolder = FolderBookmarks.folder(for: project.id)
        reloadFiles()
      }
      .deleteDisabled(appState.isBusy || readingFiles > 0)
      if readingFiles > 0 {
        HStack(spacing: Theme.Spacing.sm) {
          ProgressView().controlSize(.small)
          if let syncProgress {
            Text("Syncing \(syncProgress.completed) of \(syncProgress.total)…")
              .foregroundStyle(Theme.Text.secondary)
              .monospacedDigit()
              .contentTransition(.numericText())
              .accessibilityIdentifier("project.syncProgress")
          } else {
            Text("Reading…").foregroundStyle(Theme.Text.secondary)
          }
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
        .foregroundStyle(Theme.Text.tertiary)
    }
    .themedRow()
  }

  func fileRow(_ file: ChatDocument) -> some View {
    HStack(spacing: Theme.Spacing.md) {
      TintTile(symbol: (DocumentKind(rawValue: file.kindRaw) ?? .text).symbol)
      VStack(alignment: .leading) {
        Text(file.name)
          .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
          .foregroundStyle(Theme.Text.primary)
        if file.pageCount > 0 {
          Text("\(file.pageCount) pages").font(.caption).foregroundStyle(Theme.Text.tertiary)
        }
        if appState.knowledge.searchesByKeywords(file) {
          HStack(spacing: Theme.Spacing.sm) {
            Text("Keyword search").font(.caption).foregroundStyle(Theme.Text.tertiary)
              .accessibilityIdentifier("project.file.keywordSearch")
            // Indexing failed once; it's not retried on its own.
            Button {
              appState.knowledge.reindex(file)
              reloadFiles()
            } label: {
              Text("Index again")
                .font(.caption)
                .foregroundStyle(Theme.Brand.glacier)
                .frame(minHeight: Theme.Size.target)
                .contentShape(.rect)
            }
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
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
          Text(folder.folderName)
            .font(.subheadline)
            .foregroundStyle(Theme.Text.primary)
            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
          if let synced = folder.lastSyncedAt {
            Text("Synced \(synced.formatted(date: .abbreviated, time: .shortened))")
              .font(.caption2)
              .foregroundStyle(Theme.Text.tertiary)
          }
        }
        Spacer(minLength: Theme.Spacing.xs)
        Button {
          Haptics.selection()
          syncLinkedFolder()
        } label: {
          Text("Sync")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.Brand.teal)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(minHeight: Theme.Size.pill)
            .background { QuietBackground(shape: Capsule()) }
            .frame(minWidth: Theme.Size.target, minHeight: Theme.Size.target)
            .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .opacity(readingFiles > 0 ? 0.42 : 1)
        .disabled(readingFiles > 0)
        .accessibilityIdentifier("project.syncFolder")
        Button {
          Haptics.warning()
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
  func chatsSection(_ projectChats: [ChatThread]) -> some View {
    if !projectChats.isEmpty {
      Section {
        ForEach(projectChats) { thread in
          Button {
            save()
            onOpenChat(thread)
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(thread.title)
                  .font(.rowTitle)
                  .foregroundStyle(Theme.Text.primary)
                  .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                Text(thread.updatedAt.formatted(date: .abbreviated, time: .omitted))
                  .font(.caption)
                  .foregroundStyle(Theme.Text.tertiary)
              }
              Spacer()
              Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.Text.tertiary)
                .accessibilityHidden(true)
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

  func deleteTitle(chatCount: Int) -> String {
    chatCount == 0
      ? String(localized: "Delete project")
      : String(localized: "Delete project and \(chatCount) chats")
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
    syncProgress = nil
    readingFiles += 1
    let (progressStream, progressContinuation) = AsyncStream<(Int, Int)>.makeStream()
    let task = Task {
      let progressObserver = Task {
        for await step in progressStream {
          guard !Task.isCancelled else { break }
          syncProgress = step
        }
      }
      defer {
        progressContinuation.finish()
        progressObserver.cancel()
        syncProgress = nil
        readingFiles = max(0, readingFiles - 1)
        activeTasks.removeValue(forKey: taskID)
        if !project.isDeleted { linkedFolder = FolderBookmarks.folder(for: projectID) }
      }
      let extraction = Task.detached(priority: .utility) {
        defer { progressContinuation.finish() }
        return try await Self.extractLinkedFolderChanges(
          projectID: projectID, existingSizes: existingSizes, priorFingerprints: priorFingerprints,
          onProgress: { completed, total in progressContinuation.yield((completed, total)) })
      }
      do {
        guard
          let outcome = try await withTaskCancellationHandler(
            operation: { try await extraction.value },
            onCancel: {
              extraction.cancel()
              progressContinuation.finish()
            })
        else { return }
        guard !Task.isCancelled, !project.isDeleted, project.modelContext != nil else { return }
        applySyncOutcome(outcome, projectID: projectID)
      } catch {
        guard !Task.isCancelled, !(error is CancellationError), !project.isDeleted else { return }
        inlineError = error.localizedDescription
        Haptics.error()
      }
    }
    activeTasks[taskID] = task
  }

  nonisolated static func extractLinkedFolderChanges(
    projectID: UUID,
    existingSizes: [String: Int64],
    priorFingerprints: [String: FolderBookmarks.FileFingerprint],
    onProgress: @escaping @Sendable (Int, Int) -> Void
  ) async throws -> FolderBookmarks.SyncOutcome? {
    try await FolderBookmarks.withSupportedFiles(
      for: projectID, markSyncedOnReturn: false
    ) { urls -> FolderBookmarks.SyncOutcome in
      var unchanged: [String: FolderBookmarks.FileFingerprint] = [:]
      var pending: [(url: URL, fingerprint: FolderBookmarks.FileFingerprint)] = []
      for url in urls {
        try Task.checkCancellation()
        let fileName = url.lastPathComponent
        let fingerprint = FolderBookmarks.fingerprint(for: url)
        let unchangedKnown =
          priorFingerprints[fileName] == fingerprint && existingSizes[fileName] != nil
        let unchangedLegacy =
          priorFingerprints[fileName] == nil && existingSizes[fileName] == fingerprint.byteCount
        if unchangedKnown || unchangedLegacy {
          unchanged[fileName] = fingerprint
        } else {
          pending.append((url: url, fingerprint: fingerprint))
        }
      }
      var synced: [FolderBookmarks.SyncedFile] = []
      var failed: [(name: String, reason: String)] = []
      let total = pending.count
      for (index, item) in pending.enumerated() {
        try Task.checkCancellation()
        onProgress(index + 1, total)
        do {
          let doc = try await DocumentIngestor.extract(from: item.url)
          synced.append(.init(document: doc, fingerprint: item.fingerprint))
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          failed.append((name: item.url.lastPathComponent, reason: error.localizedDescription))
        }
      }
      return FolderBookmarks.SyncOutcome(
        synced: synced, unchangedFingerprints: unchanged, failed: failed,
        hitLimit: urls.count >= FolderBookmarks.maxFilesPerSync)
    }
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
    syncStatus = detailedSyncSummary(for: outcome)
    if !outcome.failed.isEmpty {
      Haptics.error()
    } else if !outcome.synced.isEmpty {
      Haptics.success()
    }
  }

  func detailedSyncSummary(for outcome: FolderBookmarks.SyncOutcome) -> String? {
    let syncedCount = outcome.synced.count
    let skippedCount = outcome.unchangedFingerprints.count
    var parts: [String] = []
    if syncedCount > 0 {
      parts.append(
        syncedCount == 1
          ? String(localized: "Synced 1 file")
          : String(localized: "Synced \(syncedCount) files"))
    }
    if skippedCount > 0 {
      parts.append(
        skippedCount == 1
          ? String(localized: "1 skipped")
          : String(localized: "\(skippedCount) skipped"))
    }
    if outcome.hitLimit {
      parts.append(String(localized: "hit \(FolderBookmarks.maxFilesPerSync)-file cap"))
    }
    if parts.isEmpty {
      return outcome.failed.isEmpty ? String(localized: "Folder is up to date.") : nil
    }
    return parts.joined(separator: ", ") + "."
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
