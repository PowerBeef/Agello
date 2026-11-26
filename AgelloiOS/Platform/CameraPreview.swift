@preconcurrency import AVFoundation
import SwiftUI

/// Live camera preview whose video rotation tracks the window's interface orientation via
/// `AVCaptureDevice.RotationCoordinator`.
struct CameraPreview: UIViewRepresentable {
  let session: AVCaptureSession
  var device: AVCaptureDevice?

  final class PreviewView: UIView {
    override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    // swiftlint:disable:next force_cast - guaranteed by layerClass
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var onAttachOrLayout: (() -> Void)?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window != nil { onAttachOrLayout?() }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      onAttachOrLayout?()
    }
  }

  @MainActor
  final class Coordinator {
    private weak var previewView: PreviewView?
    private weak var observedDevice: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewAngleObservation: NSKeyValueObservation?

    func sync(view: PreviewView, session: AVCaptureSession, device: AVCaptureDevice?) {
      previewView = view
      if view.previewLayer.session !== session {
        view.previewLayer.session = session
      }
      let resolvedDevice =
        device
        ?? (session.inputs.first as? AVCaptureDeviceInput)?.device
        ?? CameraSource.device()
      guard let resolvedDevice else { return }
      if observedDevice !== resolvedDevice || rotationCoordinator == nil {
        attachRotation(device: resolvedDevice, view: view)
      } else {
        applyCurrentAngle()
      }
    }

    func applyCurrentAngle() {
      guard let coordinator = rotationCoordinator else { return }
      apply(angle: coordinator.videoRotationAngleForHorizonLevelPreview)
    }

    func teardown(view: PreviewView) {
      previewAngleObservation?.invalidate()
      previewAngleObservation = nil
      rotationCoordinator = nil
      observedDevice = nil
      previewView = nil
      view.onAttachOrLayout = nil
      view.previewLayer.session = nil
    }

    private func attachRotation(device: AVCaptureDevice, view: PreviewView) {
      previewAngleObservation?.invalidate()
      let coordinator = AVCaptureDevice.RotationCoordinator(
        device: device, previewLayer: view.previewLayer)
      rotationCoordinator = coordinator
      observedDevice = device
      apply(angle: coordinator.videoRotationAngleForHorizonLevelPreview)
      previewAngleObservation = coordinator.observe(
        \.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]
      ) { [weak self] coordinator, _ in
        let angle = coordinator.videoRotationAngleForHorizonLevelPreview
        Task { @MainActor [weak self] in
          self?.apply(angle: angle)
        }
      }
    }

    private func apply(angle: CGFloat) {
      guard let connection = previewView?.previewLayer.connection,
        connection.isVideoRotationAngleSupported(angle)
      else { return }
      connection.videoRotationAngle = angle
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> PreviewView {
    let view = PreviewView()
    view.previewLayer.videoGravity = .resizeAspectFill
    let coordinator = context.coordinator
    view.onAttachOrLayout = { [weak coordinator] in
      coordinator?.applyCurrentAngle()
    }
    coordinator.sync(view: view, session: session, device: device)
    return view
  }

  func updateUIView(_ view: PreviewView, context: Context) {
    context.coordinator.sync(view: view, session: session, device: device)
  }

  static func dismantleUIView(_ view: PreviewView, coordinator: Coordinator) {
    coordinator.teardown(view: view)
  }
}
