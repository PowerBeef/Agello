import SwiftUI

/// Shown instead of the app on an iPhone below the hardware floor (``Platform/minimumMemoryBytes``,
/// 12 GB): Agello's model, at the context it's given, doesn't fit in less. Nothing is loaded or
/// downloaded behind it.
struct UnsupportedDeviceView: View {
  private var deviceMemory: String {
    let bytes = ProcessInfo.processInfo.environment["AGELLO_SIMULATE_MEMORY_GB"].flatMap(Double.init)
      .map { $0 * 1_000_000_000 } ?? Double(ProcessInfo.processInfo.physicalMemory)
    return String(format: "%.0f", bytes / 1_000_000_000)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
      Spacer()
      Image(systemName: "memorychip")
        .font(.system(.title, weight: .semibold))
        .foregroundStyle(Theme.Text.primary)
        .frame(width: Theme.Size.hero, height: Theme.Size.hero)
        .background {
          LitTintBackground(
            shape: RoundedRectangle(cornerRadius: Theme.Radius.group + 2, style: .continuous),
            tint: Theme.Brand.glacier)
        }
        .accessibilityHidden(true)
        .padding(.bottom, Theme.Spacing.xs)
      Text("Agello")
        .font(.wordmark)
        .foregroundStyle(Theme.Brand.glacier)
      Text("Agello needs an iPhone with 12 GB of memory.")
        .font(.system(.largeTitle, weight: .bold))
        .tracking(-0.6)
        .foregroundStyle(Theme.Text.primary)
        .accessibilityIdentifier("unsupported.title")
      Text(
        "Agello runs its AI model entirely on your iPhone, and the model needs 12 GB of memory, as on iPhone 17 Pro. This iPhone has \(deviceMemory) GB."
      )
      .font(.body)
      .foregroundStyle(Theme.Text.secondary)
      .accessibilityIdentifier("unsupported.detail")
      Spacer()
      Spacer()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Theme.Spacing.xxl)
    .ambientBackdrop(Theme.Brand.glacier, intensity: .loud)
  }
}
