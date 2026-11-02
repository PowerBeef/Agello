import UIKit

extension ImagePreparer {
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
