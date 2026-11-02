import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Deterministic multimodal inputs generated on device.
enum TestMedia {
  /// An sRGB color for ``solidColorJPEG(_:size:)``.
  struct Swatch {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    static let red = Swatch(red: 1, green: 0, blue: 0)
    static let blue = Swatch(red: 0, green: 0, blue: 1)
  }

  /// A solid-color JPEG, `size` pixels square, drawn with Core Graphics (the same on iOS and macOS).
  static func solidColorJPEG(_ color: Swatch, size: Int = 512) -> Data {
    let context = CGContext(
      data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(
      destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    CGImageDestinationFinalize(destination)
    return output as Data
  }

  /// Speak `text` with the system voice and write it as 16 kHz mono 16-bit
  /// WAV (the format the app's recorder produces).
  static func spokenWAV(_ text: String, language: String = "en-US") async throws -> URL {
    let raw = try await synthesize(text, language: language)
    defer { try? FileManager.default.removeItem(at: raw) }
    return try convertTo16kMonoWAV(raw)
  }

  private final class SynthesisState: @unchecked Sendable {
    var file: AVAudioFile?
    var finished = false
  }

  private static func synthesize(_ text: String, language: String) async throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-tts-\(UUID().uuidString).caf")
    let synthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = AVSpeechSynthesisVoice(language: language)
    let state = SynthesisState()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      synthesizer.write(utterance) { buffer in
        guard !state.finished else { return }
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
          state.finished = true
          state.file = nil  // closes the file
          continuation.resume()
          return
        }
        do {
          if state.file == nil {
            state.file = try AVAudioFile(
              forWriting: url, settings: pcm.format.settings,
              commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
          }
          try state.file?.write(from: pcm)
        } catch {
          state.finished = true
          continuation.resume(throwing: error)
        }
      }
    }
    withExtendedLifetime(synthesizer) {}
    return url
  }

  private static func convertTo16kMonoWAV(_ source: URL) throws -> URL {
    let input = try AVAudioFile(forReading: source)
    let target = AVAudioFormat(
      commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    let output = FileManager.default.temporaryDirectory
      .appendingPathComponent("harness-voice-\(UUID().uuidString).wav")
    let outFile = try AVAudioFile(
      forWriting: output,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
      ],
      commonFormat: .pcmFormatInt16, interleaved: true)
    guard let converter = AVAudioConverter(from: input.processingFormat, to: target) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let inBuffer = AVAudioPCMBuffer(
      pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length))!
    try input.read(into: inBuffer)
    let ratio = 16_000 / input.processingFormat.sampleRate
    let outBuffer = AVAudioPCMBuffer(
      pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(inBuffer.frameLength) * ratio) + 1024)!
    var consumed = false
    var error: NSError?
    converter.convert(to: outBuffer, error: &error) { _, status in
      if consumed {
        status.pointee = .endOfStream
        return nil
      }
      consumed = true
      status.pointee = .haveData
      return inBuffer
    }
    if let error { throw error }
    try outFile.write(from: outBuffer)
    return output
  }
}
