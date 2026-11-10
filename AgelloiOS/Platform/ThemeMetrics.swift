import CoreGraphics

/// Control sizes for a touch screen.
extension Theme {
  enum Size {
    /// Minimum tappable control (HIG).
    static let target: CGFloat = 44
    /// Composer pills and chips.
    static let pill: CGFloat = 36
    /// Icon tiles in grouped rows.
    static let tile: CGFloat = 30
    /// Inline glyph buttons (message actions); the hit area stays 44.
    static let glyph: CGFloat = 32
    static let hero: CGFloat = 64
  }
}
