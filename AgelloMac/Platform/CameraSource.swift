import AVFoundation

/// The camera voice mode looks through on the Mac.
enum CameraSource {
  /// The camera the user prefers (Continuity Camera included), else the built-in one.
  static func device() -> AVCaptureDevice? {
    AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video)
  }

  /// A Mac's camera already delivers upright frames.
  static let initialRotationAngle: CGFloat = 0
}
