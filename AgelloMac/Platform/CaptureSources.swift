import SwiftUI

/// The attach menu's Camera and Scan document on the Mac: not yet (a capture sheet and
/// Continuity Camera come in M5, docs/MAC.md), so both show as unavailable.
enum CaptureSources {
  static var cameraAvailable: Bool { false }
  static var scannerAvailable: Bool { false }
}

extension View {
  func captureSources(
    camera: Binding<Bool>, scanner: Binding<Bool>, onPhoto: @escaping (Data) -> Void,
    onScan: @escaping ([Data]) -> Void
  ) -> some View {
    self
  }
}
