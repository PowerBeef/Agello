import AppIntents
import SwiftUI

/// In-app Automation Gallery & Allowlist Manager for Agello's outbound Shortcuts Bridge
/// and saved multi-step Recipes.
///
/// Only Shortcuts explicitly added to the allowlist here can ever be proposed or run by
/// `run_shortcut`, and every run still requires explicit confirmation via `ToolConfirmationCard`.
struct AutomationGalleryView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss

  @State private var shortcuts: [RegisteredShortcut] = AutomationRegistry.shared.shortcuts
  @State private var showAddSheet = false
  @State private var newName = ""
  @State private var newSummary = ""
  @State private var newInputMode: RegisteredShortcut.PayloadMode = .text
  @State private var newOutputMode: RegisteredShortcut.PayloadMode = .text

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
          showAddSheet = true
        } label: {
          Label("Add Shortcut", systemImage: "plus")
        }
        .accessibilityIdentifier("automations.add")
      }
    }
    .sheet(isPresented: $showAddSheet) {
      addShortcutSheet
    }
    .onAppear { reload() }
    .onChange(of: appState.automationRegistryVersion) { _, _ in reload() }
  }

  private var allowlistSection: some View {
    Section {
      if shortcuts.isEmpty {
        Text("No Shortcuts registered yet. Add one below or pick a starter template so Agello can offer to run it after your confirmation.")
          .font(.subheadline)
          .foregroundStyle(Theme.Text.secondary)
          .padding(.vertical, Theme.Spacing.xs)
          .themedRow()
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
                  reload()
                })
            )
            .labelsHidden()
            .accessibilityLabel("Enable \(item.name)")
          }
          .themedRow()
          .accessibilityIdentifier("automations.shortcut.\(item.id)")
        }
        .onDelete { offsets in
          for index in offsets {
            AutomationRegistry.shared.removeShortcut(id: shortcuts[index].id)
          }
          reload()
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
        let isRegistered = shortcuts.contains { $0.id == template.id || $0.name == template.name }
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
          HStack(spacing: Theme.Spacing.md) {
            TintTile(symbol: template.symbol, tint: Theme.Brand.gold)
            VStack(alignment: .leading, spacing: 2) {
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
              reload()
              Haptics.selection()
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.bordered)
            .tint(isRegistered ? Theme.Status.healthy : Theme.Brand.glacier)
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
      ForEach(AutomationRegistry.shared.allRecipes) { recipe in
        Button {
          AppRouter.shared.handle(.runRecipe(recipe.id))
          dismiss()
        } label: {
          HStack(spacing: Theme.Spacing.md) {
            TintTile(symbol: recipe.symbol, tint: Theme.Brand.lavender)
            VStack(alignment: .leading, spacing: 2) {
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
        .shortcutsLinkStyle(.dark)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themedRow()
    } header: {
      Text("Apple Shortcuts").eyebrowStyle()
    }
  }

  private var addShortcutSheet: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Exact Shortcut name", text: $newName)
            .accessibilityIdentifier("automations.add.name")
          TextField("What it does (1 line for Agello)", text: $newSummary)
            .accessibilityIdentifier("automations.add.summary")
        } header: {
          Text("Shortcut Details").eyebrowStyle()
        } footer: {
          Text("The name must match the Shortcut in Apple's Shortcuts app exactly.")
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
            AutomationRegistry.shared.upsert(item)
            newName = ""
            newSummary = ""
            reload()
            showAddSheet = false
          }
          .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("automations.add.save")
        }
      }
    }
  }

  private func reload() {
    shortcuts = AutomationRegistry.shared.shortcuts
  }
}
