import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images and PDFs drawn with Core Graphics and Core Text, so the fixtures are the same on iOS
/// and macOS.
enum TestImages {
  /// A solid sRGB color, `width` × `height` pixels.
  static func solid(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage? {
    guard let context = bitmap(width: width, height: height) else { return nil }
    context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
  }

  /// Black `text` in the system font on white, at `scale` pixels per point. `origin` is the text's
  /// top-left corner in points from the image's top-left, as UIKit's `draw(at:)` places it.
  static func text(
    _ text: String, size: CGSize, fontSize: CGFloat, at origin: CGPoint, scale: CGFloat
  ) -> CGImage? {
    let width = Int(size.width * scale)
    let height = Int(size.height * scale)
    guard let context = bitmap(width: width, height: height) else { return nil }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    draw(text, fontSize: fontSize, at: origin, pageHeight: size.height, in: context)
    return context.makeImage()
  }

  /// `image` as JPEG, tagged with an EXIF orientation when one is given.
  static func jpeg(_ image: CGImage, quality: Double = 0.9, orientation: Int? = nil) -> Data? {
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    if let orientation { properties[kCGImagePropertyOrientation] = orientation }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
  }

  /// The pixel size an image file shows at, its EXIF orientation applied.
  static func pixelSize(of data: Data) -> CGSize? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    return (5...8).contains(orientation)
      ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
  }

  /// A letter-size PDF at `url`: one page per string, each drawn at 72, 72 in 14-point type.
  static func writePDF(pages: [String], to url: URL) throws {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    for page in pages {
      context.beginPDFPage(nil)
      draw(page, fontSize: 14, at: CGPoint(x: 72, y: 72), pageHeight: box.height, in: context)
      context.endPDFPage()
    }
    context.closePDF()
  }

  private static func bitmap(width: Int, height: Int) -> CGContext? {
    guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  }

  /// Core Graphics counts up from the bottom: the baseline sits one ascent below the top-left.
  private static func draw(
    _ text: String, fontSize: CGFloat, at origin: CGPoint, pageHeight: CGFloat, in context: CGContext
  ) {
    guard let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil) else { return }
    let attributes: [CFString: Any] = [
      kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: text, attributes: attributes as [NSAttributedString.Key: Any]))
    context.textMatrix = .identity
    context.textPosition = CGPoint(x: origin.x, y: pageHeight - origin.y - CTFontGetAscent(font))
    CTLineDraw(line, context)
  }
}
