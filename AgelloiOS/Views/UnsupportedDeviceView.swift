import SwiftUI

/// Shown instead of the app on an iPhone below the hardware floor (``Platform/minimumMemoryBytes``,
/// 12 GB): Agello's model, at the context it's given, doesn't fit in less. Nothing is loaded or
/// downloaded behind it.
struct UnsupportedDeviceView: View {
  private var deviceMemory: String {
    #if DEBUG || BENCH
      if let simulated = ProcessInfo.processInfo.environment["AGELLO_SIMULATE_MEMORY_GB"].flatMap(Double.init) {
        return String(format: "%.0f", simulated)
      }
    #endif
    let bytes = Double(ProcessInfo.processInfo.physicalMemory)
    return String(format: "%.0f", bytes / 1_073_741_824)
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
          Spacer(minLength: Theme.Spacing.lg)
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
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("unsupported.title")
          Text(
            "Agello runs its AI model entirely on your iPhone, and the model needs 12 GB of memory, as on iPhone 17 Pro. This iPhone has \(deviceMemory) GB."
          )
          .font(.body)
          .foregroundStyle(Theme.Text.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("unsupported.detail")
          Spacer(minLength: Theme.Spacing.lg)
          Spacer(minLength: Theme.Spacing.lg)
        }
        .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.lg)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .ambientBackdrop(Theme.Brand.glacier, intensity: .loud)
  }
}
