import SwiftUI
import VisionKit

/// The system document scanner (edge detection, perspective correction,
/// multiple pages); returns the scanned pages as images.
struct DocumentScanner: UIViewControllerRepresentable {
  var onScan: ([CGImage]) -> Void
  @Environment(\.dismiss) private var dismiss

  static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

  func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
    let scanner = VNDocumentCameraViewController()
    scanner.delegate = context.coordinator
    return scanner
  }

  func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  @MainActor
  final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
    let parent: DocumentScanner
    init(_ parent: DocumentScanner) { self.parent = parent }

    func documentCameraViewController(
      _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
    ) {
      let pages = (0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).cgImage }
      parent.onScan(pages)
      parent.dismiss()
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
      parent.dismiss()
    }

    func documentCameraViewController(
      _ controller: VNDocumentCameraViewController, didFailWithError error: Error
    ) {
      parent.dismiss()
    }
  }
}
