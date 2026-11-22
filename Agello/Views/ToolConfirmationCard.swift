import SwiftUI

/// Deterministic pre-execution confirmation card shown inline in the chat stream before any
/// mutating tool (`isReadOnly == false`) executes. Displays exact tool name and parameters.
struct ToolConfirmationCard: View {
  let request: ToolConfirmationRequest
  let onApprove: () -> Void
  let onDeny: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      HStack(spacing: Theme.Spacing.sm) {
        Image(systemName: "checkmark.shield.fill")
          .font(.title3)
          .foregroundStyle(Theme.Brand.gold)
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
        StatusBadge(text: String(localized: "Confirm"), tone: Theme.Status.guarded)
      }

      Text(request.summary)
        .font(.subheadline)
        .foregroundStyle(Theme.Text.secondary)

      if !request.parameters.isEmpty {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
          ForEach(request.parameters) { param in
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

      HStack(spacing: Theme.Spacing.sm) {
        Button {
          Haptics.selection()
          onDeny()
        } label: {
          Text("Deny")
            .font(.headline)
            .foregroundStyle(Theme.Text.secondary)
            .frame(maxWidth: .infinity, minHeight: Theme.Size.target)
            .surfaceCard(radius: Theme.Radius.row)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tool.confirm.deny")

        Button {
          Haptics.selection()
          onApprove()
        } label: {
          Text("Approve")
        }
        .buttonStyle(LitButtonStyle(tint: Theme.Brand.gold))
        .accessibilityIdentifier("tool.confirm.approve")
      }
    }
    .padding(Theme.Spacing.lg)
    .surfaceCard(radius: Theme.Radius.card)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("tool.confirm.card")
  }
}
