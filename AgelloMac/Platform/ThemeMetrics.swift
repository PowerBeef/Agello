import CoreGraphics

/// Control sizes on the Mac: the iPhone's for now, as Vocello started its Mac screens from the
/// iPhone's; M4 sets the desktop ladder screen by screen (docs/MAC.md).
extension Theme {
  enum Size {
    /// Minimum control.
    static let target: CGFloat = 44
    /// Composer pills and chips.
    static let pill: CGFloat = 36
    /// Icon tiles in grouped rows.
    static let tile: CGFloat = 30
    /// Inline glyph buttons (message actions).
    static let glyph: CGFloat = 32
    static let hero: CGFloat = 64
  }
}
