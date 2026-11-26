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
      // Scaled before encoding: a full-size JPEG of the photo was encoded, then decoded again.
      if let image = info[.originalImage] as? UIImage, let data = ImagePreparer.prepare(image) {
        parent.onCapture(data)
      }
      parent.dismiss()
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      parent.dismiss()
    }
  }
}
