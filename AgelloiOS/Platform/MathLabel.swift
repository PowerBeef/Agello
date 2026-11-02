import SwiftMath
import SwiftUI

/// Display math, typeset by SwiftMath's UIKit label.
struct MathLabel: UIViewRepresentable {
  let latex: String
  @Environment(\.colorScheme) private var colorScheme

  @MainActor
  static func canRender(_ latex: String) -> Bool {
    let label = MTMathUILabel()
    label.latex = latex
    return label.error == nil
  }

  func makeUIView(context: Context) -> MTMathUILabel {
    let label = MTMathUILabel()
    label.labelMode = .display
    label.textAlignment = .left
    label.fontSize = UIFont.preferredFont(forTextStyle: .body).pointSize * 1.15
    return label
  }

  func updateUIView(_ label: MTMathUILabel, context: Context) {
    label.latex = latex
    label.textColor = .label
  }

  func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTMathUILabel, context: Context) -> CGSize? {
    uiView.intrinsicContentSize
  }
}
