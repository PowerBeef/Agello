import AppIntents
import SwiftUI

/// In-app Automation Gallery & Allowlist Manager for Agello's outbound Shortcuts Bridge
/// and saved multi-step Recipes.
///
/// Only Shortcuts explicitly added to the allowlist here can ever be proposed or run by
/// `run_shortcut`, and every run still requires explicit confirmation via `ToolConfirmationCard`.
struct AutomationGalleryView: View {
  @Environment(AppState.self) private var appState

  @State private var shortcuts: [RegisteredShortcut] = AutomationRegistry.shared.shortcuts
  @State private var recipes: [AutomationRecipe] = AutomationRegistry.shared.allRecipes
  @State private var showAddSheet = false
  @State private var newName = ""
  @State private var newSummary = ""
  @State private var newInputMode: RegisteredShortcut.PayloadMode = .text
  @State private var newOutputMode: RegisteredShortcut.PayloadMode = .text
  @State private var addError: String?

  var body: some View {
    Form {
      allowlistSection
      starterTemplatesSection
      recipesSection
      shortcutsAppSection
    }
    .themedList(Theme.Brand.glacier)
    .navigationTitle("Automations & Shortcuts")
    .inlineTitleDisplay()
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          resetAddSheet()
          showAddSheet = true
        } label: {
          Label("Add Shortcut", systemImage: "plus")
        }
        .accessibilityIdentifier("automations.add")
      }
    }
    .sheet(isPresented: $showAddSheet, onDismiss: resetAddSheet) {
      addShortcutSheet
    }
    .onAppear { reload() }
    .onChange(of: appState.automationRegistryVersion) { _, _ in reload() }
  }

  private var allowlistNotice: String? {
    if !appState.enableTools {
      return String(
        localized: "On-device tools are off in Settings. Turn them on so Agello can offer to run allowed Shortcuts; Recipes below still work.")
    }
    if appState.focusFilter.hidePersonalTools {
      return String(
        localized: "Your current Focus hides personal tools and allowed Shortcuts from the assistant.")
    }
    return nil
  }

  private var allowlistSection: some View {
    Section {
      if let allowlistNotice {
        Label(allowlistNotice, systemImage: "info.circle")
          .font(.footnote)
          .foregroundStyle(Theme.Status.guarded)
          .padding(.vertical, Theme.Spacing.xxs)
          .themedRow()
          .accessibilityIdentifier("automations.allowlist.notice")
      }
      if shortcuts.isEmpty {
        EmptyStateView(
          symbol: "bolt.shield",
          title: "No Shortcuts allowed yet",
          message: "Add a Shortcut above or pick a starter template so Agello can offer to run it after your confirmation.",
          tint: Theme.Brand.glacier
        )
        .listRowBackground(Color.clear)
        .listRowInsets(
          EdgeInsets(top: Theme.Spacing.xs, leading: 0, bottom: Theme.Spacing.xs, trailing: 0))
      } else {
        ForEach(shortcuts) { item in
          HStack(spacing: Theme.Spacing.md) {
            TintTile(symbol: item.symbol, tint: Theme.Brand.glacier)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
              Text(item.name)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.Text.primary)
              if !item.summary.isEmpty {
                Text(item.summary)
                  .font(.caption)
                  .foregroundStyle(Theme.Text.secondary)
                  .lineLimit(2)
              }
              Text("id: \(item.id)")
                .font(.caption2.monospaced())
                .foregroundStyle(Theme.Text.tertiary)
            }
            Spacer(minLength: Theme.Spacing.xs)
            Toggle(
              "",
              isOn: Binding(
                get: { item.enabled },
                set: { enabled in
                  var updated = item
                  updated.enabled = enabled
                  AutomationRegistry.shared.upsert(updated)
                  Haptics.selection()
                })
            )
            .labelsHidden()
            .tint(Theme.Brand.glacier)
            .accessibilityLabel("Enable \(item.name)")
          }
          .themedRow()
          .accessibilityIdentifier("automations.shortcut.\(item.id)")
        }
        .onDelete { offsets in
          Haptics.warning()
          let ids = offsets.map { shortcuts[$0].id }
          for id in ids {
            AutomationRegistry.shared.removeShortcut(id: id)
          }
        }
      }
    } header: {
      Text("Allowed Shortcuts").eyebrowStyle()
    } footer: {
      Text("Agello can only suggest Shortcuts listed here and always asks for your confirmation before launching Apple Shortcuts.")
        .foregroundStyle(Theme.Text.tertiary)
    }
  }

  private var starterTemplatesSection: some View {
    Section {
      ForEach(StarterShortcutTemplate.curated) { template in
        let isRegistered = shortcuts.contains {
          $0.id == template.id || $0.name.caseInsensitiveCompare(template.name) == .orderedSame
        }
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
          HStack(spacing: Theme.Spacing.md) {
            TintTile(symbol: template.symbol, tint: Theme.Brand.gold)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
              Text(template.name)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.Text.primary)
              Text(template.summary)
                .font(.caption)
                .foregroundStyle(Theme.Text.secondary)
            }
            Spacer(minLength: Theme.Spacing.xs)
            Button(isRegistered ? "Added" : "Register") {
              AutomationRegistry.shared.upsert(template.asRegisteredShortcut())
              Haptics.success()
            }
            .buttonStyle(
              QuietCapsuleButtonStyle(tint: isRegistered ? Theme.Status.healthy : Theme.Brand.glacier)
            )
            .disabled(isRegistered)
            .accessibilityIdentifier("automations.starter.\(template.id)")
          }
          Text(template.setupHint)
            .font(.caption2)
            .foregroundStyle(Theme.Text.tertiary)
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .themedRow()
      }
    } header: {
      Text("Starter Templates").eyebrowStyle()
    } footer: {
      Text("Create a matching Shortcut in Apple Shortcuts first, then register its exact name here.")
        .foregroundStyle(Theme.Text.tertiary)
    }
  }

  private var recipesSection: some View {
    Section {
      ForEach(recipes) { recipe in
        Button {
          Haptics.selection()
          AppRouter.shared.handle(.runRecipe(recipe.id))
        } label: {
          HStack(spacing: Theme.Spacing.md) {
            TintTile(symbol: recipe.symbol, tint: Theme.Brand.lavender)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
              Text(recipe.name)
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(Theme.Text.primary)
              Text(recipe.summary)
                .font(.caption)
                .foregroundStyle(Theme.Text.secondary)
                .lineLimit(2)
            }
            Spacer(minLength: Theme.Spacing.xs)
            Image(systemName: "play.circle.fill")
              .font(.title3)
              .foregroundStyle(Theme.Brand.lavender)
              .accessibilityHidden(true)
          }
        }
        .themedRow()
        .accessibilityIdentifier("automations.recipe.\(recipe.id)")
      }
    } header: {
      Text("Multi-Step Recipes").eyebrowStyle()
    } footer: {
      Text("Recipes load into a new chat ready to run, and can also be triggered from Siri or iOS Personal Automations.")
        .foregroundStyle(Theme.Text.tertiary)
    }
  }

  private var shortcutsAppSection: some View {
    Section {
      ShortcutsLink()
        .shortcutsLinkStyle(.darkOutline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowBackground(Color.clear)
        .listRowInsets(
          EdgeInsets(top: Theme.Spacing.xs, leading: 0, bottom: Theme.Spacing.xs, trailing: 0))
        .accessibilityIdentifier("automations.shortcutsLink")
    } header: {
      Text("Apple Shortcuts").eyebrowStyle()
    }
  }

  private var addShortcutSheet: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Exact Shortcut name", text: $newName)
            .onChange(of: newName) { _, _ in
              if addError != nil { addError = nil }
            }
            .accessibilityIdentifier("automations.add.name")
          TextField("What it does (1 line for Agello)", text: $newSummary)
            .accessibilityIdentifier("automations.add.summary")
          if let addError {
            Text(addError)
              .font(.footnote)
              .foregroundStyle(Theme.Status.critical)
              .accessibilityIdentifier("automations.add.error")
          }
        } header: {
          Text("Shortcut Details").eyebrowStyle()
        } footer: {
          Text("The name must match the Shortcut in Apple's Shortcuts app exactly.")
            .foregroundStyle(Theme.Text.tertiary)
        }
        .themedRow()

        Section {
          Picker("Input", selection: $newInputMode) {
            ForEach(RegisteredShortcut.PayloadMode.allCases, id: \.self) { mode in
              Text(mode.displayName).tag(mode)
            }
          }
          Picker("Output", selection: $newOutputMode) {
            ForEach(RegisteredShortcut.PayloadMode.allCases, id: \.self) { mode in
              Text(mode.displayName).tag(mode)
            }
          }
        } header: {
          Text("Data").eyebrowStyle()
        }
        .themedRow()
      }
      .themedList(Theme.Brand.glacier)
      .navigationTitle("Add Shortcut")
      .inlineTitleDisplay()
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { showAddSheet = false }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            let item = RegisteredShortcut(
              name: newName, summary: newSummary,
              inputMode: newInputMode, outputMode: newOutputMode)
            do {
              try AutomationRegistry.shared.register(item)
              Haptics.success()
              showAddSheet = false
            } catch {
              addError = error.localizedDescription
              Haptics.error()
            }
          }
          .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("automations.add.save")
        }
      }
    }
  }

  private func resetAddSheet() {
    newName = ""
    newSummary = ""
    newInputMode = .text
    newOutputMode = .text
    addError = nil
  }

  private func reload() {
    let latestShortcuts = AutomationRegistry.shared.shortcuts
    if shortcuts != latestShortcuts { shortcuts = latestShortcuts }
    let latestRecipes = AutomationRegistry.shared.allRecipes
    if recipes != latestRecipes { recipes = latestRecipes }
  }
}
