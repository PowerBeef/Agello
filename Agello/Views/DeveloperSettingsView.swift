import SwiftUI

/// What only development needs, out of the user's way: the stats line under replies, the
/// benchmark, and what the engine loaded. Opened by tapping the version line in Settings five
/// times. Nothing here changes how Agello answers: the engine's choices (speculative decoding,
/// the reasoning budget, sampling, vision and audio, the system prompt) are the app's own since
/// 2026-11-11, and Advanced, the screen that offered them, is gone.
struct DeveloperSettingsView: View {
  @Environment(AppState.self) private var appState
  @Environment(\.dynamicTypeSize) private var typeSize
  @AppStorage("showPerformanceDetails") private var showStats = false
  @State private var memorySnapshot: MemoryProbe.Snapshot?
  @State private var telemetrySummary: MetricsReporter.TelemetrySummary?
  @State private var telemetryRefreshToken = 0
  @State private var benchmarkError: String?

  var body: some View {
    Form {
      performanceSection
      benchmarkSection
      telemetrySection
      deviceSection
    }
    .themedList()
    .navigationTitle("Developer")
    .inlineTitleDisplay()
    .task(id: telemetryRefreshToken) {
      let snapshot = MemoryProbe.capture()
      memorySnapshot = snapshot
      let summary = await MetricsReporter.summarizeAsync()
      guard !Task.isCancelled else { return }
      telemetrySummary = summary
    }
  }

  private func refreshTelemetry() {
    Haptics.selection()
    telemetryRefreshToken &+= 1
  }

  private var performanceSection: some View {
    Section {
      Toggle("Show performance details", isOn: $showStats)
        .tint(Theme.Brand.glacier)
        .themedRow()
        .onChange(of: showStats) { _, _ in Haptics.selection() }
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
          Haptics.selection()
          benchmarkError = nil
          Task {
            appState.generationError = nil
            await appState.runBenchmark()
            if let error = appState.generationError {
              benchmarkError = error
              Haptics.error()
            } else if appState.benchmarkReport != nil {
              Haptics.success()
            }
          }
        } label: {
          Label("Run benchmark", systemImage: "speedometer")
        }
        .buttonStyle(LitButtonStyle(tint: Theme.Brand.glacier))
        .disabled(
          !appState.store.isDownloaded(appState.store.activeSpec)
            || appState.isBusy || appState.isTranscribing)
        .padding(.vertical, Theme.Spacing.md)
        .listRowBackground(Color.clear)
        .listRowInsets(
          EdgeInsets(
            top: Theme.Spacing.xs, leading: Theme.Spacing.xs,
            bottom: Theme.Spacing.xs, trailing: Theme.Spacing.xs))
        .accessibilityIdentifier("settings.benchmark")
        if appState.isBusy || appState.isTranscribing {
          Text("Finish the active reply or dictation before running the benchmark.")
            .font(.footnote)
            .foregroundStyle(Theme.Text.tertiary)
            .themedRow()
        }
      }
      if let benchmarkError {
        Text(benchmarkError)
          .font(.footnote)
          .foregroundStyle(Theme.Status.critical)
          .themedRow()
          .accessibilityIdentifier("developer.benchmark.error")
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
      if typeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
          benchmarkStat(
            value: String(format: "%.0f", report.prefillTokensPerSecond), label: "prefill tok/s")
          benchmarkStat(
            value: String(format: "%.0f", report.decodeTokensPerSecond), label: "decode tok/s")
          benchmarkStat(
            value: String(format: "%.1fs", report.timeToFirstToken), label: "first token")
        }
      } else {
        HStack(spacing: Theme.Spacing.xl) {
          benchmarkStat(
            value: String(format: "%.0f", report.prefillTokensPerSecond), label: "prefill tok/s")
          benchmarkStat(
            value: String(format: "%.0f", report.decodeTokensPerSecond), label: "decode tok/s")
          benchmarkStat(
            value: String(format: "%.1fs", report.timeToFirstToken), label: "first token")
          Spacer()
        }
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
    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
      Text(value)
        .font(.system(.title3, weight: .bold))
        .monospacedDigit()
        .foregroundStyle(Theme.Text.primary)
      Text(label)
        .font(.caption2)
        .foregroundStyle(Theme.Text.tertiary)
    }
  }

  private var telemetrySection: some View {
    Section {
      LabeledContent(
        "Footprint / Peak",
        value: memorySnapshot.map {
          String(
            format: "%.2f / %.2f GB",
            Double($0.footprintBytes) / 1e9,
            Double($0.peakFootprintBytes) / 1e9)
        } ?? "—"
      )
      .monospacedDigit()
      .themedRow()
      LabeledContent(
        "GPU / ANE ledgers",
        value: memorySnapshot.map {
          String(
            format: "%.2f / %.2f GB",
            Double($0.graphicsBytes) / 1e9,
            Double($0.neuralBytes) / 1e9)
        } ?? "—"
      )
      .monospacedDigit()
      .themedRow()
      LabeledContent(
        "Thermal",
        value: memorySnapshot.map { MemoryProbe.thermalStateLabel($0.thermalState) } ?? "—"
      )
      .themedRow()
      LabeledContent(
        "MetricKit reports",
        value: telemetrySummary.map { "\($0.reportCount)" } ?? String(localized: "Loading…")
      )
      .monospacedDigit()
      .themedRow()
      if let summary = telemetrySummary {
        LabeledContent(
          "Mem exc / crashes",
          value: "\(summary.memoryExceptionCount) / \(summary.crashCount)"
        )
        .monospacedDigit()
        .themedRow()
      }
      if let peakMB = telemetrySummary?.peakMemoryMB {
        LabeledContent("MetricKit peak", value: String(format: "%.0f MB", peakMB))
          .monospacedDigit()
          .themedRow()
      }
      if let summary = telemetrySummary, summary.gpuTimeSeconds > 0 || summary.cpuTimeSeconds > 0 {
        LabeledContent(
          "MetricKit compute",
          value: String(
            format: "GPU %.1fs · CPU %.1fs",
            summary.gpuTimeSeconds, summary.cpuTimeSeconds)
        )
        .monospacedDigit()
        .themedRow()
      }
      Button("Refresh telemetry", action: refreshTelemetry)
        .foregroundStyle(Theme.Brand.glacier)
        .themedRow()
    } header: {
      Text("Telemetry").eyebrowStyle()
    } footer: {
      Text("Live kernel physical footprint, peak (`ledger_phys_footprint_peak`), Metal/ANE ledgers, and on-device MetricKit reports.")
        .foregroundStyle(Theme.Text.tertiary)
    }
  }

  private var deviceSection: some View {
    Section {
      LabeledContent("This device", value: DeviceProfile.current.summary)
        .themedRow()
      LabeledContent("Engine", value: appState.engineDisplayName)
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
