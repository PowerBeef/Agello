import AVFoundation
import SwiftUI
import UIKit

/// Takes a photo with the system camera and returns it as JPEG data.
struct CameraPicker: UIViewControllerRepresentable {
  var onCapture: (Data) -> Void
  @Environment(\.dismiss) private var dismiss

  static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
  static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    if Self.isAvailable {
      picker.sourceType = .camera
    }
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ picker: UIImagePickerController, context: Context) {
    context.coordinator.parent = self
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  @MainActor
  final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    var parent: CameraPicker
    init(_ parent: CameraPicker) { self.parent = parent }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      let image = info[.originalImage] as? UIImage
      let onCapture = parent.onCapture
      parent.dismiss()
      guard let image else { return }
      // Scale and JPEG-encode off MainActor so the camera sheet dismisses without hitching.
      Task { @MainActor in
        let data = await Task.detached(priority: .userInitiated) {
          ImagePreparer.prepare(image)
        }.value
        if let data { onCapture(data) }
      }
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      parent.dismiss()
    }
  }
}
