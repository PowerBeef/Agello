import AVFoundation

/// The camera voice mode looks through on iPhone.
enum CameraSource {
  /// The back wide-angle camera: what the user points the phone at.
  static func device() -> AVCaptureDevice? {
    AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
  }

  /// Frames start upright for a phone held in portrait; the rotation coordinator turns them after.
  static let initialRotationAngle: CGFloat = 90
}
