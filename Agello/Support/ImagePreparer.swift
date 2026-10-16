import UIKit

/// Downscale + re-encode user photos before vision input to bound memory.
enum ImagePreparer {
  /// The longest side, in pixels, of a photo the model sees.
  static let maxDimension = 1568

  /// `data` scaled so its longest side is at most `maxDimension` pixels, as JPEG, without
  /// decoding the full-size photo (see ``ImageDownsampler``). Call it off the main thread.
  static func prepare(_ data: Data, maxDimension: Int = maxDimension) -> Data? {
    ImageDownsampler.jpeg(from: data, maxPixels: maxDimension)
  }

  /// A camera photo (already decoded by the picker) scaled the same way.
  static func prepare(_ image: UIImage, maxDimension: Int = maxDimension) -> Data? {
    let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
    let longest = max(pixels.width, pixels.height)
    guard longest > 0 else { return nil }
    let scale = min(1, CGFloat(maxDimension) / longest)
    let target = CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
    return resized.jpegData(compressionQuality: 0.85)
  }
}
