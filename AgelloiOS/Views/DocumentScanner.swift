import SwiftUI
import VisionKit

private struct SendableDocumentScan: @unchecked Sendable {
  let scan: VNDocumentCameraScan
}

/// The system document scanner (edge detection, perspective correction,
/// multiple pages); returns the scanned pages as images.
struct DocumentScanner: UIViewControllerRepresentable {
  var onScan: ([Data]) -> Void
  var onError: ((Error) -> Void)?
  @Environment(\.dismiss) private var dismiss

  static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

  func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
    let scanner = VNDocumentCameraViewController()
    scanner.delegate = context.coordinator
    return scanner
  }

  func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {
    context.coordinator.parent = self
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  @MainActor
  final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
    var parent: DocumentScanner
    init(_ parent: DocumentScanner) { self.parent = parent }

    func documentCameraViewController(
      _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
    ) {
      let pageCount = scan.pageCount
      let onScan = parent.onScan
      parent.dismiss()
      guard pageCount > 0 else { return }
      let boxed = SendableDocumentScan(scan: scan)
      // One page decoded at a time off MainActor, kept as a JPEG at OCR resolution: holding every
      // page at full size (about 48 MB each) until OCR finished could exhaust memory.
      Task { @MainActor in
        let pages: [Data] = await Task.detached(priority: .userInitiated) {
          (0..<pageCount).compactMap { index in
            autoreleasepool {
              ImagePreparer.prepare(
                boxed.scan.imageOfPage(at: index), maxDimension: DocumentIngestor.ocrMaxDimension)
            }
          }
        }.value
        guard !pages.isEmpty else { return }
        onScan(pages)
      }
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
      parent.dismiss()
    }

    func documentCameraViewController(
      _ controller: VNDocumentCameraViewController, didFailWithError error: Error
    ) {
      Log.lifecycle.error("document scanner failed: \(error.localizedDescription, privacy: .public)")
      parent.onError?(error)
      parent.dismiss()
    }
  }
}
