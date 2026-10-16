import SwiftUI
import VisionKit

/// The system document scanner (edge detection, perspective correction,
/// multiple pages); returns the scanned pages as images.
struct DocumentScanner: UIViewControllerRepresentable {
  var onScan: ([Data]) -> Void
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
      // One page decoded at a time, kept as a JPEG at OCR resolution: holding every page at
      // full size (about 48 MB each) until OCR finished could exhaust memory.
      let pages: [Data] = (0..<scan.pageCount).compactMap { index in
        autoreleasepool {
          ImagePreparer.prepare(scan.imageOfPage(at: index), maxDimension: DocumentIngestor.ocrMaxDimension)
        }
      }
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
