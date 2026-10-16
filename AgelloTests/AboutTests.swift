import XCTest

@testable import Agello

/// Settings → About: the licenses the app shows and the privacy policy it links.
final class AboutTests: XCTestCase {
  /// The bundled copy of NOTICE names everything Agello includes or downloads.
  func testLicensesListEveryComponent() {
    let notice = LicensesView.notice
    for component in [
      "LiteRT-LM", "swift-markdown", "swift-cmark", "SwiftMath", "GUST Font License",
      "SIL Open Font License", "Gemma 4 E4B", "EmbeddingGemma 2",
    ] {
      XCTAssertTrue(notice.contains(component), "NOTICE.txt doesn't mention \(component)")
    }
  }

  func testPrivacyPolicyIsServedOverHTTPS() {
    XCTAssertEqual(SettingsView.privacyPolicyURL.scheme, "https")
    XCTAssertEqual(SettingsView.privacyPolicyURL.lastPathComponent, "privacy")
  }
}
