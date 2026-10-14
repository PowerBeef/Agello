@preconcurrency import AVFoundation
import CoreImage
import SwiftUI
import UIKit

/// The back camera for voice mode: a live preview, and the latest frame as
/// a JPEG when the user finishes speaking ("what am I looking at?").
final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "agello.camera")
  private let lock = NSLock()
  private var latest: CVPixelBuffer?
  private let context = CIContext()

  static var isAvailable: Bool { AVCaptureDevice.default(for: .video) != nil }

  /// Ask for access (first use) and start the camera.
  func start() async -> Bool {
    guard await AVCaptureDevice.requestAccess(for: .video) else { return false }
    return await withCheckedContinuation { continuation in
      queue.async { [self] in
        if session.inputs.isEmpty {
          session.beginConfiguration()
          session.sessionPreset = .hd1280x720
          guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
          else {
            session.commitConfiguration()
            continuation.resume(returning: false)
            return
          }
          session.addInput(input)
          let output = AVCaptureVideoDataOutput()
          output.alwaysDiscardsLateVideoFrames = true
          output.setSampleBufferDelegate(self, queue: queue)
          if session.canAddOutput(output) { session.addOutput(output) }
          output.connection(with: .video)?.videoRotationAngle = 90
          session.commitConfiguration()
        }
        session.startRunning()
        continuation.resume(returning: true)
      }
    }
  }

  func stop() {
    queue.async { [self] in
      session.stopRunning()
      lock.withLock { latest = nil }
    }
  }

  /// The most recent frame as JPEG (sized for the model by ImagePreparer).
  func snapshot() -> Data? {
    guard let pixels = lock.withLock({ latest }) else { return nil }
    let image = CIImage(cvPixelBuffer: pixels)
    guard let cgImage = context.createCGImage(image, from: image.extent),
      let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
    else { return nil }
    return ImagePreparer.prepare(jpeg) ?? jpeg
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    lock.withLock { latest = pixels }
  }
}

/// Live camera preview.
struct CameraPreview: UIViewRepresentable {
  let session: AVCaptureSession

  final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    // swiftlint:disable:next force_cast - guaranteed by layerClass
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
  }

  func makeUIView(context: Context) -> PreviewView {
    let view = PreviewView()
    view.previewLayer.session = session
    view.previewLayer.videoGravity = .resizeAspectFill
    return view
  }

  func updateUIView(_ view: PreviewView, context: Context) {}
}
