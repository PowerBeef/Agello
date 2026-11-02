import SwiftUI

/// Where the attach menu's Camera and Scan document come from: on iPhone, the camera and
/// VisionKit's document camera, full screen.
enum CaptureSources {
  static var cameraAvailable: Bool { CameraPicker.isAvailable }
  static var scannerAvailable: Bool { DocumentScanner.isAvailable }
}

extension View {
  /// Shows the camera while `camera` is set and the document scanner while `scanner` is.
  func captureSources(
    camera: Binding<Bool>, scanner: Binding<Bool>, onPhoto: @escaping (Data) -> Void,
    onScan: @escaping ([Data]) -> Void
  ) -> some View {
    fullScreenCover(isPresented: camera) {
      CameraPicker(onCapture: onPhoto)
        .ignoresSafeArea()
    }
    .fullScreenCover(isPresented: scanner) {
      DocumentScanner(onScan: onScan)
        .ignoresSafeArea()
    }
  }
}
