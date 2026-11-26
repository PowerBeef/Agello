import SwiftUI

/// Deterministic pre-execution confirmation card shown inline in the chat stream (and Voice Mode)
/// before any mutating tool (`isReadOnly == false`) executes.
///
/// Supports both single-action confirmation and grouped multi-step `PlanConfirmationCard` batches
/// (with per-step checkboxes, risk badges, and zero-TOCTOU execution), plus an amber provenance
/// warning banner whenever external/untrusted content entered the active turn.
struct ToolConfirmationCard: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  let request: ToolConfirmationRequest
  let isCompact: Bool
  let onApprove: () -> Void
  let onApproveSteps: ((Set<Int>) -> Void)?
  let onDeny: () -> Void

  @State private var selectedSteps: Set<Int>

  init(
    request: ToolConfirmationRequest,
    isCompact: Bool = false,
    onApprove: @escaping () -> Void,
    onApproveSteps: ((Set<Int>) -> Void)? = nil,
    onDeny: @escaping () -> Void
  ) {
    self.request = request
    self.isCompact = isCompact
    self.onApprove = onApprove
    self.onApproveSteps = onApproveSteps
    self.onDeny = onDeny
    _selectedSteps = State(initialValue: Set(request.steps.map(\.index)))
  }

  private var usesCompactLayout: Bool {
    isCompact || verticalSizeClass == .compact
  }

  private var validStepIndices: Set<Int> {
    Set(request.steps.map(\.index))
  }

  private var activeSelectedSteps: Set<Int> {
    selectedSteps.intersection(validStepIndices)
  }

  private var effectiveRisk: ToolConfirmationRequest.RiskTier {
    guard request.isPlanBatch else { return request.risk }
    let active = request.steps.filter { activeSelectedSteps.contains($0.index) }
    if active.contains(where: { $0.risk == .destructive }) { return .destructive }
    if active.contains(where: { $0.risk == .external }) { return .external }
    return .standard
  }

  private var accentTint: Color {
    switch effectiveRisk {
    case .standard: Theme.Brand.gold
    case .destructive: Theme.Status.critical
    case .external: Theme.Brand.glacier
    }
  }

  private var shieldSymbol: String {
    if request.isPlanBatch { return "checklist.checked" }
    switch request.risk {
    case .standard: return "checkmark.shield.fill"
    case .destructive: return "exclamationmark.triangle.fill"
    case .external: return "arrow.up.forward.app.fill"
    }
  }

  private var badgeText: String {
    switch effectiveRisk {
    case .standard:
      return request.isPlanBatch ? String(localized: "Plan") : String(localized: "Confirm")
    case .destructive:
      return String(localized: "Destructive")
    case .external:
      return String(localized: "External")
    }
  }

  private var approveLabel: String {
    if request.isPlanBatch {
      let count = activeSelectedSteps.count
      if count == 0 {
        return String(localized: "Select Actions")
      }
      return count == 1
        ? String(localized: "Run 1 Action")
        : String(localized: "Run \(count) Actions")
    }
    switch request.risk {
    case .destructive: return String(localized: "Delete")
    case .external: return String(localized: "Run")
    case .standard: return String(localized: "Approve")
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: usesCompactLayout ? Theme.Spacing.sm : Theme.Spacing.md) {
      header

      if usesCompactLayout {
        ScrollView {
          detailsContent
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: 200)
      } else {
        detailsContent
      }

      actionButtons
    }
    .padding(usesCompactLayout ? Theme.Spacing.md : Theme.Spacing.lg)
    .surfaceCard(
      radius: Theme.Radius.card,
      stroke: effectiveRisk == .destructive ? Theme.Status.critical.opacity(0.35) : Theme.Surface.hairline)
    .appAnimation(Theme.Motion.stateChange, value: effectiveRisk, kind: .dissolve)
    .transition(reduceMotion ? .opacity : .scale(scale: 0.96).combined(with: .opacity))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier(request.isPlanBatch ? "tool.plan.card" : "tool.confirm.card")
    .onChange(of: request.id) { _, _ in
      selectedSteps = Set(request.steps.map(\.index))
    }
  }

  @ViewBuilder
  private var detailsContent: some View {
    VStack(alignment: .leading, spacing: usesCompactLayout ? Theme.Spacing.sm : Theme.Spacing.md) {
      if !request.untrustedSources.isEmpty {
        taintBanner
      }

      Text(request.summary)
        .font(.subheadline)
        .foregroundStyle(Theme.Text.secondary)

      if request.isPlanBatch {
        planStepsList
      } else if !request.parameters.isEmpty {
        parameterList(request.parameters)
      }
    }
  }

  private var header: some View {
    HStack(spacing: Theme.Spacing.sm) {
      Image(systemName: shieldSymbol)
        .font(.title3)
        .foregroundStyle(accentTint)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
        Text(request.title)
          .font(.headline)
          .foregroundStyle(Theme.Text.primary)
        Text(request.toolName)
          .font(.caption.monospaced())
          .foregroundStyle(Theme.Text.tertiary)
          .accessibilityIdentifier("tool.confirm.name")
      }
      Spacer(minLength: Theme.Spacing.xs)
      StatusBadge(text: badgeText, tone: accentTint)
    }
  }

  private var taintBanner: some View {
    let sourceList = request.untrustedSources.prefix(3).joined(separator: ", ")
    return HStack(alignment: .top, spacing: Theme.Spacing.sm) {
      Image(systemName: "exclamationmark.shield.fill")
        .font(.subheadline)
        .foregroundStyle(Theme.Status.guarded)
      Text("Triggered after reading external content (\(sourceList)). Verify all details carefully.")
        .font(.caption)
        .foregroundStyle(Theme.Text.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(Theme.Spacing.sm)
    .background(Theme.Status.guarded.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
        .stroke(Theme.Status.guarded.opacity(0.35), lineWidth: Theme.Stroke.hairline)
    }
    .accessibilityIdentifier("tool.confirm.taintBanner")
  }

  private var planStepsList: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
      ForEach(request.steps) { step in
        let isSelected = activeSelectedSteps.contains(step.index)
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
          Button {
            Haptics.selection()
            withAppAnimation(Theme.Motion.stateChange) {
              if isSelected {
                selectedSteps.remove(step.index)
              } else {
                selectedSteps.insert(step.index)
              }
            }
          } label: {
            HStack(alignment: .center, spacing: Theme.Spacing.sm) {
              Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isSelected ? tint(for: step.risk) : Theme.Text.tertiary)
                .contentTransition(.symbolEffect(.replace))
                .appAnimation(Theme.Motion.stateChange, value: isSelected, kind: .dissolve)
                .frame(width: 28, height: Theme.Size.target)
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                  .font(.system(.subheadline, weight: .semibold))
                  .foregroundStyle(isSelected ? Theme.Text.primary : Theme.Text.tertiary)
                Text(step.summary)
                  .font(.caption)
                  .foregroundStyle(Theme.Text.secondary)
                  .lineLimit(2)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              if step.risk != .standard {
                StatusBadge(
                  text: step.risk == .destructive ? String(localized: "Destructive") : String(localized: "External"),
                  tone: tint(for: step.risk))
              }
            }
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(stepAccessibilityLabel(for: step))
          .accessibilityValue(isSelected ? String(localized: "Selected") : String(localized: "Not selected"))
          .accessibilityAddTraits(.isToggle)
          .accessibilityIdentifier("tool.plan.step.\(step.index)")

          if isSelected, !step.parameters.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
              ForEach(step.parameters) { param in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                  Text(param.name)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.Text.tertiary)
                    .frame(minWidth: 58, alignment: .leading)
                  Text(param.value)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
              }
            }
            .padding(.leading, 36)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
          }
        }
        .padding(Theme.Spacing.sm)
        .surfaceCard(radius: Theme.Radius.row)
      }
    }
  }

  private func parameterList(_ parameters: [ToolConfirmationRequest.Parameter]) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
      ForEach(parameters) { param in
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
          Text(param.name)
            .font(.caption.monospaced())
            .foregroundStyle(Theme.Text.tertiary)
            .frame(minWidth: 68, alignment: .leading)
          Text(param.value)
            .font(.subheadline)
            .foregroundStyle(Theme.Text.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .padding(Theme.Spacing.md)
    .surfaceCard(radius: Theme.Radius.row)
  }

  private var actionButtons: some View {
    let isApproveDisabled = request.isPlanBatch && activeSelectedSteps.isEmpty
    return HStack(spacing: Theme.Spacing.sm) {
      Button {
        Haptics.selection()
        onDeny()
      } label: {
        Text(request.isPlanBatch ? String(localized: "Cancel") : String(localized: "Deny"))
      }
      .buttonStyle(QuietConfirmDenyButtonStyle())
      .accessibilityIdentifier("tool.confirm.deny")

      Button {
        Haptics.selection()
        if request.isPlanBatch, let onApproveSteps {
          onApproveSteps(activeSelectedSteps)
        } else {
          onApprove()
        }
      } label: {
        Text(approveLabel)
          .contentTransition(.numericText())
          .opacity(isApproveDisabled ? 0.55 : 1)
      }
      .buttonStyle(LitButtonStyle(tint: accentTint))
      .disabled(isApproveDisabled)
      .appAnimation(Theme.Motion.stateChange, value: activeSelectedSteps.count, kind: .dissolve)
      .accessibilityIdentifier("tool.confirm.approve")
    }
  }

  private func stepAccessibilityLabel(for step: ToolConfirmationRequest.Step) -> String {
    var parts = [step.title, step.summary]
    switch step.risk {
    case .destructive:
      parts.append(String(localized: "Destructive"))
    case .external:
      parts.append(String(localized: "External"))
    case .standard:
      break
    }
    return parts.filter { !$0.isEmpty }.joined(separator: ". ")
  }

  private func tint(for risk: ToolConfirmationRequest.RiskTier) -> Color {
    switch risk {
    case .standard: Theme.Brand.gold
    case .destructive: Theme.Status.critical
    case .external: Theme.Brand.glacier
    }
  }
}

/// Capsule-matched Deny / Cancel button paired symmetrically with `LitButtonStyle`.
private struct QuietConfirmDenyButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ScaledMetric(relativeTo: .headline) private var height: CGFloat = 52

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .tracking(-0.17)
      .foregroundStyle(Theme.Text.secondary)
      .padding(.horizontal, Theme.Spacing.md)
      .frame(maxWidth: .infinity, minHeight: height)
      .background { QuietBackground(shape: Capsule(), isPressed: configuration.isPressed) }
      .contentShape(Capsule())
      .scaleEffect(!reduceMotion && configuration.isPressed ? 0.98 : 1)
      .appAnimation(Theme.Motion.press, value: configuration.isPressed)
  }
}
