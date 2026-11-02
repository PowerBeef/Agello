import Foundation

/// Downscale + re-encode user photos before vision input to bound memory.
enum ImagePreparer {
  /// The longest side, in pixels, of a photo the model sees.
  static let maxDimension = 1568

  /// `data` scaled so its longest side is at most `maxDimension` pixels, as JPEG, without
  /// decoding the full-size photo (see ``ImageDownsampler``). Call it off the main thread.
  static func prepare(_ data: Data, maxDimension: Int = maxDimension) -> Data? {
    ImageDownsampler.jpeg(from: data, maxPixels: maxDimension)
  }
}
