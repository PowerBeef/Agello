@preconcurrency import AVFoundation
import CoreImage

/// The back camera for voice mode: a live preview, and the latest frame as
/// a JPEG when the user finishes speaking ("what am I looking at?").
final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
  private let queue = DispatchQueue(label: "agello.camera")
  private let lock = NSLock()
  private let contextLock = NSLock()
  private var captureSession: AVCaptureSession?
  private var latest: CVPixelBuffer?
  private var activeDevice: AVCaptureDevice?
  private var ciContext: CIContext?
  /// Keeps frames level with the horizon whichever way the phone is held (they were always
  /// rotated for portrait, so a landscape snapshot came out sideways).
  private var rotation: AVCaptureDevice.RotationCoordinator?
  private var rotationObservation: NSKeyValueObservation?

  /// Lazily allocated only once the user enables the camera (zero overhead on audio-only launches).
  var session: AVCaptureSession? { lock.withLock { captureSession } }
  var captureDevice: AVCaptureDevice? { lock.withLock { activeDevice } }

  deinit {
    rotationObservation?.invalidate()
  }

  static var isAvailable: Bool { AVCaptureDevice.default(for: .video) != nil }

  /// Ask for access (first use) and start the camera.
  func start() async -> Bool {
    guard await AVCaptureDevice.requestAccess(for: .video), !Task.isCancelled else { return false }
    return await withCheckedContinuation { continuation in
      queue.async { [self] in
        let activeSession = lock.withLock {
          if let existing = captureSession { return existing }
          let created = AVCaptureSession()
          captureSession = created
          return created
        }
        if activeSession.inputs.isEmpty {
          activeSession.beginConfiguration()
          activeSession.sessionPreset = .hd1280x720
          guard let device = CameraSource.device(),
            let input = try? AVCaptureDeviceInput(device: device),
            activeSession.canAddInput(input)
          else {
            activeSession.commitConfiguration()
            continuation.resume(returning: false)
            return
          }
          lock.withLock { activeDevice = device }
          activeSession.addInput(input)
          let output = AVCaptureVideoDataOutput()
          output.alwaysDiscardsLateVideoFrames = true
          output.setSampleBufferDelegate(self, queue: queue)
          if activeSession.canAddOutput(output) { activeSession.addOutput(output) }
          output.connection(with: .video)?.videoRotationAngle = CameraSource.initialRotationAngle
          activeSession.commitConfiguration()
          followRotation(of: device, connection: output.connection(with: .video))
        }
        activeSession.startRunning()
        continuation.resume(returning: true)
      }
    }
  }

  /// Frames turn with the phone (camera queue).
  private func followRotation(of device: AVCaptureDevice, connection: AVCaptureConnection?) {
    guard let connection else { return }
    let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
    rotation = coordinator
    rotationObservation = coordinator.observe(
      \.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]
    ) { [weak self] coordinator, _ in
      let angle = coordinator.videoRotationAngleForHorizonLevelCapture
      self?.queue.async {
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
      }
    }
  }

  func stop() {
    guard lock.withLock({ captureSession != nil || latest != nil }) else { return }
    queue.async { [self] in
      let activeSession = lock.withLock { captureSession }
      activeSession?.stopRunning()
      lock.withLock { latest = nil }
    }
  }

  private func resolveContext() -> CIContext {
    contextLock.withLock {
      if let ciContext { return ciContext }
      let created = CIContext()
      ciContext = created
      return created
    }
  }

  /// The most recent frame as JPEG (skips redundant decode/re-encode when already within model limits).
  func snapshot() -> Data? {
    guard let pixels = lock.withLock({ latest }) else { return nil }
    let image = CIImage(cvPixelBuffer: pixels)
    let context = resolveContext()
    guard let cgImage = context.createCGImage(image, from: image.extent),
      let jpeg = ImageDownsampler.jpeg(cgImage, quality: 0.85)
    else { return nil }
    if max(cgImage.width, cgImage.height) <= ImagePreparer.maxDimension {
      return jpeg
    }
    return ImagePreparer.prepare(jpeg) ?? jpeg
  }

  func captureOutput(
    _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection
  ) {
    guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    lock.withLock { latest = pixels }
  }
}
