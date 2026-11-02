import AppKit

/// App-wide AppKit settings SwiftUI doesn't reach.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
  func applicationWillFinishLaunching(_ notification: Notification) {
    // One window, dark like the iPhone app (Theme has one dark palette).
    NSWindow.allowsAutomaticWindowTabbing = false
    NSApp.appearance = NSAppearance(named: .darkAqua)
  }

  func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
