import SwiftMath
import SwiftUI

/// Display math, typeset by SwiftMath's AppKit label.
struct MathLabel: NSViewRepresentable {
  let latex: String

  @MainActor
  static func canRender(_ latex: String) -> Bool {
    let label = MTMathUILabel()
    label.latex = latex
    return label.error == nil
  }

  func makeNSView(context: Context) -> MTMathUILabel {
    let label = MTMathUILabel()
    label.labelMode = .display
    label.textAlignment = .left
    label.fontSize = NSFont.preferredFont(forTextStyle: .body).pointSize * 1.15
    return label
  }

  func updateNSView(_ label: MTMathUILabel, context: Context) {
    label.latex = latex
    label.textColor = .labelColor
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTMathUILabel, context: Context) -> CGSize? {
    nsView.intrinsicContentSize
  }
}
