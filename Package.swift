// swift-tools-version: 6.0
// The Mac command line for Agello's engine (docs/CLI.md): a development tool, never shipped.
// It compiles the app's own non-UI files in place, with macOS versions of the platform types in
// AgelloCLI/. Xcode never reads this file: the iPhone app is built from Agello.xcodeproj.
//
//   swift build -c release --scratch-path build/cli/release
//   LITERTLM_PACKAGE=/abs/path/to/a/checkout/named/LiteRT-LM swift build -c release --scratch-path build/cli/<arm>
import PackageDescription

// The runtime (the "arm"): what the app ships, or another checkout of our LiteRT-LM whose
// folder is named LiteRT-LM (SwiftPM names a path package after its folder).
let litertlm = Context.environment["LITERTLM_PACKAGE"] ?? "Vendor/LiteRT-LM"

let package = Package(
  name: "agello-cli",
  platforms: [.macOS("27.0")],
  products: [.executable(name: "agello", targets: ["Agello"])],
  dependencies: [.package(path: litertlm)],
  targets: [
    // The module is named Agello, like the app's, so tests can `@testable import Agello`.
    .executableTarget(
      name: "Agello",
      dependencies: [.product(name: "LiteRTLM", package: "LiteRT-LM")],
      path: ".",
      exclude: [
        "Agello.xcodeproj", "AgelloDeviceTests", "AgelloShare", "AgelloTests", "AgelloWidgets",
        // The UI tests, but for the bench's cases (below).
        "AgelloUITests/AccessibilityAuditUITests.swift", "AgelloUITests/BenchUITests.swift",
        "AgelloUITests/ChatFlowUITests.swift", "AgelloUITests/DeviceFloorUITests.swift",
        "AgelloUITests/ScreenshotTourUITests.swift",
        "AgelloiOS", "Vendor", "build", "docs", "scripts", "CLAUDE.md", "LICENSE", "NOTICE",
        "README.md", "buildServer.json",
        // The app's interface, and what only it uses.
        "Agello/App", "Agello/Assets.xcassets", "Agello/PrivacyInfo.xcprivacy", "Agello/Resources",
        "Agello/Views", "Agello/Markdown", "Agello/Support/Theme",
        "Agello/Support/Announcements.swift", "Agello/Support/MetricsReporter.swift",
        "Agello/System/AppIntents.swift", "Agello/System/SharedIntents.swift",
        "Agello/System/AppReset.swift", "Agello/System/AppRouter.swift",
        "Agello/Voice/CameraFeed.swift", "Agello/Voice/VoiceAudio.swift",
        "Agello/Voice/VoiceSession.swift",
      ],
      // Whole folders where every file is engine code, so a new file there joins by itself; a
      // new file elsewhere that the engine needs breaks this build, which is the signal.
      sources: [
        "Agello/AppState.swift",
        "Agello/Inference", "Agello/Knowledge", "Agello/ModelHub", "Agello/Persistence",
        "Agello/Support/Diagnostics.swift", "Agello/Support/ImagePreparer.swift",
        "Agello/Support/ReplyTrace.swift",
        "Agello/System/ShareInbox.swift", "Agello/System/SharedItems.swift",
        "Agello/System/SpotlightIndex.swift",
        "Agello/Voice/VoiceText.swift",
        // One list of bench cases for the iPhone's driver and for `agello bench`.
        "AgelloUITests/BenchCases.swift",
        "AgelloCLI/Sources",
      ]
    )
  ]
)
