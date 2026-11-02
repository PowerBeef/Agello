import AVFoundation
import SwiftUI

/// Live camera preview.
struct CameraPreview: NSViewRepresentable {
  let session: AVCaptureSession

  final class PreviewView: NSView {
    override init(frame: NSRect) {
      super.init(frame: frame)
      wantsLayer = true
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer { AVCaptureVideoPreviewLayer() }
    // swiftlint:disable:next force_cast - guaranteed by makeBackingLayer
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
  }

  func makeNSView(context: Context) -> PreviewView {
    let view = PreviewView()
    view.previewLayer.session = session
    view.previewLayer.videoGravity = .resizeAspectFill
    return view
  }

  func updateNSView(_ view: PreviewView, context: Context) {}
}
