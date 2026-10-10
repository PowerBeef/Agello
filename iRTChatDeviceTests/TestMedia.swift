import AVFoundation
import UIKit

/// Deterministic multimodal inputs generated on device.
enum TestMedia {
  /// A solid-color JPEG, prepared the same way the app prepares photos.
  @MainActor
  static func solidColorJPEG(_ color: UIColor, size: CGFloat = 512) -> Data {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
    let image = renderer.image { context in
      color.setFill()
      context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }
    return image.jpegData(compressionQuality: 0.9)!
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
