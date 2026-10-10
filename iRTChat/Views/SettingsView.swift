import SwiftUI

/// Premium grouped settings: a live status hero on top, icon-led sections,
/// explanations as footers, and full-width action buttons. Everything applies
/// live (via `onChange`); the system prompt applies through its button.
struct SettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dismiss) private var dismiss
  @State private var systemDraft = ""
  @State private var draftLoaded = false

  private var bindable: Bindable<AppState> { Bindable(appState) }

  var body: some View {
    NavigationStack {
      Form {
        statusSection
        personalizationSection
        modelSection
        performanceSection
        reasoningSection
        samplingSection
        multimodalSection
        systemPromptSection
        benchmarkSection
        toolsSection
        deviceSection
      }
      .navigationTitle("Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("settings.done")
        }
      }
      .onAppear {
        if !draftLoaded {
          systemDraft = appState.options.systemPrompt
          draftLoaded = true
        }
      }
      .onChange(of: appState.options) {
        appState.scheduleApplyOptions()
      }
      .onChange(of: appState.enableTools) {
        appState.scheduleApplyOptions()
      }
    }
  }

  // MARK: - Status hero

  private var statusSection: some View {
    Section {
      HStack(spacing: DS.spaceMD) {
        Image(systemName: "sparkles")
          .font(.callout)
          .frame(width: DS.iconLG, height: DS.iconLG)
          .glassEffect(.regular.tint(.accentColor), in: .circle)
        VStack(alignment: .leading, spacing: 2) {
          Text(activeSpec.displayName)
            .font(.headline)
          Text(statusLine)
            .font(.caption)
            .accessibilityIdentifier("settings.status")
            .foregroundStyle(.secondary)
        }
        Spacer()
        Circle()
          .fill(statusColor)
          .frame(width: 10, height: 10)
      }
      .padding(.vertical, 4)
    }
  }

  private var activeSpec: ModelSpec { appState.store.activeSpec }

  private var statusLine: String {
    switch appState.engineState {
    case .ready:
      if let resolved = appState.resolved { return "Ready · \(resolvedSummary(resolved))" }
      return "Ready"
    case .generating: return "Generating…"
    case .loading(let progress): return progress
    case .failed: return "Engine error — see the chat for details"
    case .idle:
      return appState.store.isDownloaded(appState.store.activeSpec)
        ? "Downloaded — loads on your next chat"
        : "Not downloaded — get it in Models below"
    }
  }

  private var statusColor: Color {
    switch appState.engineState {
    case .ready, .generating: return .green
    case .loading: return .orange
    case .failed: return .red
    case .idle:
      return appState.store.isDownloaded(appState.store.activeSpec) ? .secondary : .orange
    }
  }

  // MARK: - Sections

  private var personalizationSection: some View {
    Section {
      NavigationLink {
        PersonalizationView()
      } label: {
        LabeledContent {
          Text(personalizationSummary)
        } label: {
          Label("Personalization", systemImage: "person.crop.circle")
        }
      }
      .accessibilityIdentifier("settings.personalization")
      NavigationLink {
        MemoryView()
      } label: {
        LabeledContent {
          Text(appState.memoryEnabled ? String(localized: "On") : String(localized: "Off"))
        } label: {
          Label("Memory", systemImage: "brain.head.profile")
        }
      }
      .accessibilityIdentifier("settings.memory")
      NavigationLink {
        WebSearchSettingsView()
      } label: {
        LabeledContent {
          Text(webSummary)
        } label: {
          Label("Web search", systemImage: "globe")
        }
      }
      .accessibilityIdentifier("settings.web")
    }
  }

  private var webSummary: String {
    let web = appState.webSettings
    guard web.allowed else { return String(localized: "Off") }
    return web.automatic ? String(localized: "Automatic") : web.provider.displayName
  }

  private var personalizationSummary: String {
    let p = appState.personalization
    guard p.enabled else { return String(localized: "Off") }
    let customized = !p.name.isEmpty || !p.aboutYou.isEmpty || !p.instructions.isEmpty
    return customized ? p.style.displayName : String(localized: "Not set")
  }

  private var modelSection: some View {
    Section {
      NavigationLink {
        ModelLibraryView()
      } label: {
        LabeledContent("Models", value: activeSpec.displayName)
      }
      .accessibilityIdentifier("settings.models")
    } header: {
      Label("Model", systemImage: "cube")
    } footer: {
      if let resolved = appState.resolved {
        Text(resolvedSummary(resolved)).monospacedDigit()
      } else {
        Text("Download the model in Models to start chatting.")
      }
    }
  }

  private var performanceSection: some View {
    Section {
      Picker("Backend", selection: bindable.options.backendPreference) {
        Text("GPU (Metal)").tag(BackendPreference.gpu)
        Text("CPU").tag(BackendPreference.cpu)
      }
      .pickerStyle(.segmented)
      Toggle(
        "Speculative decoding (MTP)",
        isOn: bindable.options.enableSpeculativeDecoding)
      Toggle(
        "Compact reasoning cache",
        isOn: bindable.options.compactReasoningCache)
    } header: {
      Label("Performance", systemImage: "gauge")
    } footer: {
      Text(
        "GPU decode is ~2x faster and falls back to CPU automatically. "
          + "Speculative decoding doubles GPU decode speed with no quality change when the model file supports it. "
          + "Compact cache keeps thought tokens out of the KV cache for longer effective context."
      )
    }
  }

  private var reasoningSection: some View {
    Section {
      Toggle("Enable reasoning", isOn: bindable.options.enableThinking)
      if appState.options.enableThinking {
        Stepper(
          "Budget: \(appState.options.thinkingBudget) tokens",
          value: bindable.options.thinkingBudget, in: 128...4096, step: 128)
      }
      Toggle("Automatic context", isOn: autoContextBinding)
      if appState.options.maxNumTokensOverride != nil {
        Stepper(
          "KV cache: \(appState.options.maxNumTokensOverride ?? 2048) tokens",
          value: contextBinding,
          in: 256...DeviceProfile.current.maxContextTokens(model: appState.store.activeModelID),
          step: 1024)
      }
    } header: {
      Label("Reasoning & Memory", systemImage: "brain")
    } footer: {
      Text(
        "Reasoning shows its work in a Reasoning card under each reply. "
          + "Automatic context picks the largest KV cache safe for this device "
          + "(\(DeviceProfile.current.defaultMaxTokens(model: appState.store.activeModelID)) tokens)."
      )
    }
  }

  private var samplingSection: some View {
    Section {
      Picker("Preset", selection: bindable.options.samplerPreset) {
        ForEach(SamplerPreset.allCases, id: \.self) { preset in
          Text(preset.displayName).tag(preset)
        }
      }
      .pickerStyle(.segmented)
    } header: {
      Label("Sampling", systemImage: "dice")
    } footer: {
      Text("Precise is factual (temp 0.2), Balanced the default (0.7), Creative the most varied (1.0).")
    }
  }

  private var multimodalSection: some View {
    Section {
      Toggle("Vision (images)", isOn: bindable.options.enableVision)
      Toggle("Audio (voice)", isOn: bindable.options.enableAudio)
      if appState.options.enableVision {
        Picker("Image detail", selection: bindable.options.visualDetail) {
          ForEach(VisualDetail.allCases, id: \.self) { detail in
            Text(detail.displayName).tag(detail)
          }
        }
      }
    } header: {
      Label("Voice & Vision", systemImage: "eye")
    } footer: {
      Text("Images and voice are processed on-device. Higher detail answers better but uses more context.")
    }
  }

  private var systemPromptSection: some View {
    Section {
      TextEditor(text: $systemDraft)
        .frame(minHeight: 80)
      Button(action: {
        // Applied through the `options` onChange above.
        appState.options.systemPrompt = systemDraft
      }) {
        Text("Apply system prompt")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.glass)
      .controlSize(.regular)
      .disabled(systemDraft == appState.options.systemPrompt)
    } header: {
      Label("System Prompt", systemImage: "text.quote")
    } footer: {
      Text("Applies immediately to the active conversation.")
    }
  }

  private var benchmarkSection: some View {
    Section {
      if appState.isBenchmarking {
        HStack {
          ProgressView().controlSize(.small)
          Text("Benchmarking 1024 prefill / 256 decode…")
            .font(.caption)
        }
      } else {
        Button(action: { Task { await appState.runBenchmark() } }) {
          Text("Run benchmark")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.regular)
        .disabled(!appState.store.isDownloaded(appState.store.activeSpec))
        .accessibilityIdentifier("settings.benchmark")
      }
      if let report = appState.benchmarkReport {
        benchmarkStats(report)
      }
    } header: {
      Label("Benchmark", systemImage: "speedometer")
    } footer: {
      Text(
        "1024 prefill / 256 decode tokens. Google reports 1189 prefill / 25 decode tok/s for E4B on iPhone 17 Pro GPU (without speculative decoding)."
      )
    }
  }

  private func benchmarkStats(_ report: BenchmarkReport) -> some View {
    VStack(alignment: .leading, spacing: DS.spaceSM) {
      HStack(spacing: DS.spaceLG) {
        benchmarkStat(
          value: String(format: "%.0f", report.prefillTokensPerSecond), label: "prefill tok/s")
        benchmarkStat(
          value: String(format: "%.0f", report.decodeTokensPerSecond), label: "decode tok/s")
        benchmarkStat(
          value: String(format: "%.1fs", report.timeToFirstToken), label: "first token")
        Spacer()
      }
      Text(
        "\(ModelCatalog.spec(for: report.modelID).displayName) · \(report.backend) · \(report.date.formatted(date: .abbreviated, time: .omitted))"
      )
      .font(.caption2)
      .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 4)
  }

  private func benchmarkStat(value: String, label: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value)
        .font(.title3)
        .bold()
        .monospacedDigit()
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }

  private var toolsSection: some View {
    Section {
      Toggle("On-device tools", isOn: bindable.enableTools)
    } header: {
      Label("Tools", systemImage: "wrench.and.screwdriver")
    } footer: {
      Text("The assistant can check the time and calculate, fully on-device.")
    }
  }

  private var deviceSection: some View {
    Section {
      LabeledContent("This device", value: DeviceProfile.current.summary)
      LabeledContent("Engine", value: appState.isMock ? "Mock" : "LiteRT-LM")
      if appState.isMock {
        Text("Mock engine active (--mock-engine). No model required.")
          .font(.caption)
          .foregroundStyle(.orange)
      }
    } header: {
      Label("Device", systemImage: "iphone")
    } footer: {
      Text("\(appVersion) · Gemma 4 on-device via LiteRT-LM")
    }
  }

  private var appVersion: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
    let build = info?["CFBundleVersion"] as? String ?? "1"
    return "iRTChat \(version) (\(build))"
  }

  // MARK: - Bindings


  private var autoContextBinding: Binding<Bool> {
    Binding(
      get: { appState.options.maxNumTokensOverride == nil },
      set: { auto in
        appState.options.maxNumTokensOverride = auto
          ? nil
          : DeviceProfile.current.defaultMaxTokens(model: appState.store.activeModelID)
      }
    )
  }

  private var contextBinding: Binding<Int> {
    Binding(
      get: { appState.options.maxNumTokensOverride ?? 2048 },
      set: { appState.options.maxNumTokensOverride = $0 }
    )
  }

  private func resolvedSummary(_ resolved: ResolvedInference) -> String {
    var parts = ["Backend: \(resolved.backendLabel)", "KV: \(resolved.maxNumTokens)"]
    parts.append(resolved.thinkingBudget == nil ? "Thinking: off" : "Thinking: on")
    parts.append(resolved.enableSpeculativeDecoding ? "MTP: on" : "MTP: off")
    let mm =
      resolved.enableVision && resolved.enableAudio ? "Vision+Audio"
      : resolved.enableVision ? "Vision" : resolved.enableAudio ? "Audio" : "Text-only"
    parts.append(mm)
    return parts.joined(separator: " · ")
  }
}
