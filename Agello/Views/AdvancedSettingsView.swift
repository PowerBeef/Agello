import SwiftUI

/// The engine's developer controls: backend, speculative decoding, the KV
/// cache, reasoning, sampling, voice and vision, the system prompt, the
/// benchmark, and this device. Option changes apply through
/// `SettingsView`'s `onChange` (this screen is pushed on its stack).
struct AdvancedSettingsView: View {
  @Environment(AppState.self) private var appState
  @AppStorage("showPerformanceDetails") private var showStats = false
  @State private var systemDraft = ""
  @State private var draftLoaded = false

  private var bindable: Bindable<AppState> { Bindable(appState) }

  var body: some View {
    Form {
      performanceSection
      reasoningSection
      samplingSection
      multimodalSection
      systemPromptSection
      benchmarkSection
      deviceSection
    }
    .themedList()
    .navigationTitle("Advanced")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      if !draftLoaded {
        systemDraft = appState.options.systemPrompt
        draftLoaded = true
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
      .themedRow()
      Toggle("Speculative decoding (MTP)", isOn: bindable.options.enableSpeculativeDecoding)
        .themedRow()
      Toggle("Show performance details", isOn: $showStats)
        .themedRow()
        .accessibilityIdentifier("settings.showStats")
    } header: {
      Text("Performance").eyebrowStyle()
    } footer: {
      Text(
        "The GPU decodes about twice as fast and falls back to the CPU automatically. "
          + "Speculative decoding doubles GPU decode speed with no quality change. "
          + "Performance details show time to first token, speed and backend under each reply."
      )
      .foregroundStyle(Theme.Text.tertiary)
    }
  }

  private var reasoningSection: some View {
    Section {
      Toggle("Enable reasoning", isOn: bindable.options.enableThinking)
        .themedRow()
      if appState.options.enableThinking {
        Stepper(
          "Budget: \(appState.options.thinkingBudget) tokens",
          value: bindable.options.thinkingBudget, in: 128...4096, step: 128
        )
        .monospacedDigit()
        .themedRow()
      }
      Toggle("Automatic context", isOn: autoContextBinding)
        .themedRow()
      if appState.options.maxNumTokensOverride != nil {
        Stepper(
          "KV cache: \(contextBinding.wrappedValue) tokens",
          value: contextBinding,
          in: 256...DeviceProfile.current.maxContextTokens(model: appState.store.activeModelID),
          step: 1024
        )
        .monospacedDigit()
        .themedRow()
      }
    } header: {
      Text("Reasoning & Memory").eyebrowStyle()
    } footer: {
      Text(
        "Reasoning streams into a card above each reply, then leaves the model's memory, so it doesn't use up the context. "
          + "Automatic context uses \(DeviceProfile.current.defaultMaxTokens(model: appState.store.activeModelID)) tokens; "
          + "a bigger cache fits longer messages but slows every reply."
      )
      .foregroundStyle(Theme.Text.tertiary)
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
      .themedRow()
    } header: {
      Text("Sampling").eyebrowStyle()
    } footer: {
      Text("Precise is factual (temperature 0.2), Balanced the default (0.7), Creative the most varied (1.0).")
        .foregroundStyle(Theme.Text.tertiary)
    }
  }

  private var multimodalSection: some View {
    Section {
      Toggle("Vision (images)", isOn: bindable.options.enableVision)
        .themedRow()
      Toggle("Audio (voice)", isOn: bindable.options.enableAudio)
        .themedRow()
      if appState.options.enableVision {
        Picker("Image detail", selection: bindable.options.visualDetail) {
          ForEach(VisualDetail.allCases, id: \.self) { detail in
            Text(detail.displayName).tag(detail)
          }
        }
        .themedRow()
      }
    } header: {
      Text("Voice & Vision").eyebrowStyle()
    } footer: {
      Text("Images and voice are processed on this iPhone. Higher detail answers better but uses more context.")
        .foregroundStyle(Theme.Text.tertiary)
    }
  }

  private var systemPromptSection: some View {
    Section {
      TextEditor(text: $systemDraft)
        .frame(minHeight: 96)
        .scrollContentBackground(.hidden)
        .foregroundStyle(Theme.Text.primary)
        .themedRow()
      Button {
        // Applied through SettingsView's `options` onChange.
        appState.options.systemPrompt = systemDraft
        Haptics.complete()
      } label: {
        Text("Apply system prompt")
          .font(.system(.body, weight: .semibold))
          .frame(maxWidth: .infinity)
      }
      .foregroundStyle(systemDraft == appState.options.systemPrompt ? Theme.Text.tertiary : Theme.Brand.glacier)
      .disabled(systemDraft == appState.options.systemPrompt)
      .themedRow()
    } header: {
      Text("System prompt").eyebrowStyle()
    } footer: {
      Text("Applies to the active conversation before its next message.")
        .foregroundStyle(Theme.Text.tertiary)
    }
  }

  private var benchmarkSection: some View {
    Section {
      if appState.isBenchmarking {
        HStack(spacing: Theme.Spacing.sm) {
          ProgressView().controlSize(.small)
          Text("Benchmarking 1,024 prefill and 256 decode tokens…")
            .font(.footnote)
            .foregroundStyle(Theme.Text.secondary)
        }
        .themedRow()
      } else {
        Button {
          Task { await appState.runBenchmark() }
        } label: {
          Label("Run benchmark", systemImage: "speedometer")
        }
        .buttonStyle(LitButtonStyle(tint: Theme.Brand.glacier))
        .disabled(!appState.store.isDownloaded(appState.store.activeSpec))
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .accessibilityIdentifier("settings.benchmark")
      }
      if let report = appState.benchmarkReport {
        benchmarkStats(report)
          .themedRow()
      }
    } header: {
      Text("Benchmark").eyebrowStyle()
    } footer: {
      Text(
        "1,024 prefill and 256 decode tokens. Google reports 1,189 prefill and 25 decode tokens per second for E4B on the iPhone 17 Pro GPU, without speculative decoding."
      )
      .foregroundStyle(Theme.Text.tertiary)
    }
  }

  private func benchmarkStats(_ report: BenchmarkReport) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      HStack(spacing: Theme.Spacing.xl) {
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
      .foregroundStyle(Theme.Text.tertiary)
    }
    .padding(.vertical, Theme.Spacing.xs)
  }

  private func benchmarkStat(value: String, label: LocalizedStringKey) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value)
        .font(.system(.title3, weight: .bold))
        .monospacedDigit()
        .foregroundStyle(Theme.Text.primary)
      Text(label)
        .font(.caption2)
        .foregroundStyle(Theme.Text.tertiary)
    }
  }

  private var deviceSection: some View {
    Section {
      LabeledContent("This device", value: DeviceProfile.current.summary)
        .themedRow()
      LabeledContent("Engine", value: appState.isMock ? "Mock" : "LiteRT-LM")
        .themedRow()
      if let resolved = appState.resolved {
        LabeledContent("Loaded", value: resolvedSummary(resolved))
          .monospacedDigit()
          .themedRow()
      }
      if appState.isMock {
        Text("Mock engine active (--mock-engine). No model required.")
          .font(.caption)
          .foregroundStyle(Theme.Status.guarded)
          .themedRow()
      }
    } header: {
      Text("Device").eyebrowStyle()
    }
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
      get: {
        min(
          appState.options.maxNumTokensOverride ?? 2048,
          DeviceProfile.current.maxContextTokens(model: appState.store.activeModelID))
      },
      set: { appState.options.maxNumTokensOverride = $0 }
    )
  }

  private func resolvedSummary(_ resolved: ResolvedInference) -> String {
    var parts = [resolved.backendLabel, "KV \(resolved.maxNumTokens)"]
    parts.append(resolved.thinkingBudget == nil ? "thinking off" : "thinking on")
    parts.append(resolved.enableSpeculativeDecoding ? "MTP" : "no MTP")
    let mm =
      resolved.enableVision && resolved.enableAudio ? "vision+audio"
      : resolved.enableVision ? "vision" : resolved.enableAudio ? "audio" : "text-only"
    parts.append(mm)
    return parts.joined(separator: " · ")
  }
}
