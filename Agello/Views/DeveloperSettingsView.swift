import SwiftUI

/// What only development needs, out of the user's way: the stats line under replies, the
/// benchmark, and what the engine loaded. Opened by tapping the version line in Settings five
/// times. Nothing here changes how Agello answers: the engine's choices (speculative decoding,
/// the reasoning budget, sampling, vision and audio, the system prompt) are the app's own since
/// 2026-11-11, and Advanced, the screen that offered them, is gone.
struct DeveloperSettingsView: View {
  @Environment(AppState.self) private var appState
  @AppStorage("showPerformanceDetails") private var showStats = false

  var body: some View {
    Form {
      performanceSection
      benchmarkSection
      deviceSection
    }
    .themedList()
    .navigationTitle("Developer")
    .inlineTitleDisplay()
  }

  private var performanceSection: some View {
    Section {
      Toggle("Show performance details", isOn: $showStats)
        .themedRow()
        .accessibilityIdentifier("settings.showStats")
    } header: {
      Text("Replies").eyebrowStyle()
    } footer: {
      Text("Time to first token and speed under each reply.")
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
        "1,024 prefill and 256 decode tokens on the GPU, without speculative decoding."
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

  private func resolvedSummary(_ resolved: ResolvedInference) -> String {
    var parts = [resolved.backendLabel, "KV \(resolved.maxNumTokens)"]
    parts.append(resolved.thinkingBudget == nil ? "thinking off" : "thinking on")
    parts.append(resolved.enableSpeculativeDecoding ? "MTP" : "no MTP")
    let mm =
      resolved.enableVision && resolved.enableAudio ? "vision+audio"
      : resolved.enableVision ? "vision" : resolved.enableAudio ? "audio" : "text-only"
    parts.append(mm)
    if let budget = resolved.visualTokenBudget { parts.append("\(budget) tokens per image") }
    return parts.joined(separator: " · ")
  }
}
