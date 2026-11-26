import SwiftMath
import SwiftUI

/// Display math, typeset by SwiftMath's UIKit label.
struct MathLabel: UIViewRepresentable {
  let latex: String
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  @MainActor
  private static let textColor = UIColor(Theme.Text.primary)

  @MainActor
  private static let validationCache: NSCache<NSString, NSNumber> = {
    let cache = NSCache<NSString, NSNumber>()
    cache.countLimit = 256
    return cache
  }()

  @MainActor
  static func canRender(_ latex: String) -> Bool {
    let key = latex as NSString
    if let hit = validationCache.object(forKey: key) {
      return hit.boolValue
    }
    var error: NSError?
    let valid = MTMathListBuilder.build(fromString: latex, error: &error) != nil && error == nil
    validationCache.setObject(NSNumber(value: valid), forKey: key)
    return valid
  }

  private static func fontSize(for traitCollection: UITraitCollection) -> CGFloat {
    UIFont.preferredFont(forTextStyle: .body, compatibleWith: traitCollection).pointSize * 1.15
  }

  func makeUIView(context: Context) -> MTMathUILabel {
    let label = MTMathUILabel()
    label.labelMode = .display
    label.textAlignment = .left
    label.contentInsets = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
    label.fontSize = Self.fontSize(for: label.traitCollection)
    label.textColor = Self.textColor
    return label
  }

  func updateUIView(_ label: MTMathUILabel, context: Context) {
    let targetFontSize = Self.fontSize(for: label.traitCollection)
    if label.fontSize != targetFontSize {
      label.fontSize = targetFontSize
    }
    if label.latex != latex {
      label.latex = latex
    }
    if label.textColor != Self.textColor {
      label.textColor = Self.textColor
    }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTMathUILabel, context: Context) -> CGSize? {
    let targetFontSize = Self.fontSize(for: uiView.traitCollection)
    if uiView.fontSize != targetFontSize {
      uiView.fontSize = targetFontSize
    }
    let raw = uiView.intrinsicContentSize
    let width: CGFloat =
      if raw.width == UIView.noIntrinsicMetric || !raw.width.isFinite {
        proposal.width ?? 0
      } else {
        ceil(max(0, raw.width))
      }
    let height: CGFloat =
      if raw.height == UIView.noIntrinsicMetric || !raw.height.isFinite {
        ceil(targetFontSize * 1.4)
      } else {
        ceil(max(0, raw.height)) + 4
      }
    return CGSize(width: width, height: height)
  }
}
