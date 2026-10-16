# Agello for Mac: the plan

A native macOS version of Agello that shares most of the iPhone app's code and architecture.

**Status:** approved 2026-10-16; not started. The work is paused before M0. [The roadmap](ROADMAP.md) places it among the other work.

## Context

The reference for the Mac/iPhone split is Vocello 3.0 ([PowerBeef/Vocello](https://github.com/PowerBeef/Vocello), branch `main`). Three investigations covered Vocello's split, Agello's portability, and the LiteRT-LM runtime on macOS:

- **Agello is mostly portable already.** 52 of the 76 files in `Agello/` (61% of 15,605 lines) compile for macOS unchanged: Inference, Persistence, ModelHub, Knowledge (except one file), Markdown parsing, System (except BackgroundWork), the Theme tokens and most views. The real work is:
  - the shell: drawer → sidebar, `fullScreenCover`s, top-bar items;
  - voice audio (`AVAudioSession`), the camera, and the scanner/picker;
  - the memory policy (`os_proc_available_memory` is unavailable on macOS);
  - the background policy (scenePhase stops replies);
  - the two extensions;
  - Mac input: there are no `.commands` or shortcuts today, and Return doesn't send.
- **Vocello's pattern** is two native SwiftUI apps from one project. The iPhone app is the reference. Shared code is a folder compiled into both apps. Service roots use the same type name with one file per platform, `#if os()` is rare, and the Mac adds thin desktop adapters. The Mac shell is:
  - one main window, with app-level state;
  - a `NavigationSplitView` sidebar, a Settings scene reusing the same screen, and command menus;
  - one design-token namespace with desktop metrics;
  - shared components rather than copied screens ("copying drifted every number").
- **Runtime.** Google's v0.18.0 Mac binary (`CLiteRTLM_mac`, already in `Vendor/LiteRT-LM/Package.swift`) runs on WebGPU and processes prompts about 3.5× slower. Our `agello-next` build already produces a `macos-arm64` slice with Metal (M6: about 3,400 tok/s prefill and about 49 tok/s decode, 47–50 at a 32K window), but its framework layout must be fixed before it can be signed inside an app.

**Decisions (2026-10-16):**
1. Our Metal runtime from the start.
2. Developer ID DMG, not the Mac App Store.
3. A second app target sharing the synchronized folders, no XcodeGen.
4. Full parity in the first Mac release, widgets and the share extension included.

**Outcome:** a notarized `Agello.dmg` for Apple silicon Macs on macOS 27, built from the same `Agello/` sources as the iPhone app. Each platform keeps its own shell and adapters. The iPhone app's behavior doesn't change.

## Shape

| Target | Compiles | Bundle ID |
| --- | --- | --- |
| `Agello` (iOS, unchanged) | `Agello/` + new `AgelloiOS/` | `com.patricedery.agello` |
| `AgelloMac` (`PRODUCT_NAME`/`PRODUCT_MODULE_NAME = Agello`) | `Agello/` + new `AgelloMac/` | `com.patricedery.agello.mac` |
| `AgelloMacTests` (host AgelloMac) | `AgelloTests/` minus `BackgroundWorkTests` | `….mac.tests` |
| `AgelloMacDeviceTests` (host AgelloMac) | `AgelloDeviceTests/` minus `MemoryEnvelopeScenarioTests` | `….mac.devicetests` |
| `AgelloMacUITests` | `AgelloMacUITests/` + shared `AgelloUITests/Support/` + `AccessibilityAuditUITests` | `….mac.uitests` |
| `AgelloMacWidgets`, `AgelloMacShare` (appex) | Mac plists and entitlements + `AgelloWidgets/AgelloWidgets.swift` / `AgelloShare/ShareModel.swift` + `SharedIntents` / `ShareInbox` | `….mac.widgets`, `….mac.share` |

- **Membership comes from synchronized root groups.** A file borrowed from another folder joins a target through a `PBXFileSystemSynchronizedBuildFileExceptionSet`, as `SharedIntents.swift` reaches the widgets today. Targets are created in Xcode, then their settings are tuned and the pbxproj diff reviewed.
- **One type name, one file per platform** (`AgelloiOS/Platform/Haptics.swift` and `AgelloMac/Platform/Haptics.swift`). Shared code then needs no `#if`.
- **Versions are shared:** `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` move to the project level, and every target inherits them.
- **Scheme `AgelloMac`;** the `Agello` scheme stays iOS-only. Add the new folders to `.swiftlint.yml`.

## How it interleaves with Phase 4 (our runtime)

```
Fork agello-next : M0.1 ─ 4.1(a–d) runtime fixes ─ 4.2 dry-run artifact (both slices) ─ [iPhone back] 4.3 gate ─ 4.4 publish (maintainer's OK)
Agello main      : M0.2–3 ─ M1 ─ M2 ─ M3 ─ M4 ─ M5 ─ M6 ─ M7 ─ M8 (dry runs) ──── needs 4.4 ──── M9 Mac gate + publish (maintainer's OK)
```
- **Until 4.4, the committed `Vendor/LiteRT-LM` stays Google's.**
  - With it, AgelloMac only compiles (Google's `CLiteRTLM_mac` exports every symbol the wrapper uses) and runs `unit` on the scripted engine.
  - Real-engine Mac runs use `Vendor/use-local-litert.sh`. Rerun it after each fork rebuild, and never commit it.
  - `AgelloMac/App/RuntimeGuard.swift` refuses to load E4B when `EngineCache.runtimeBuildID == nil` and shows a notice instead. The guard stays: the Mac supports only our runtime, and its cache and helper policies assume it.
  - The harness refuses Mac device suites without our build.
  - No conditional targets and no project hacks.
- **4.2's artifact includes M0.1.** **4.3's gate adds the native Mac suites** next to the iPhone batch. **4.4 commits our package for both platforms**, since the wrappers can't mix.
- **4.1(a–d) must land before the Mac ships:** the MTP verify bound (16 GB Macs offer 32K), one terminal event per send, the per-session sampler, and stats without benchmark mode (benchmark mode busy-waits 29.3 ms of CPU per token today).

## M0: the runtime can be embedded and signed

1. **Fork (`agello-next`, `agello/build-xcframework.sh`):**
   - Repackage the macOS slice as a versioned framework: `Versions/A/{CLiteRTLM, Headers, Modules, Resources/Info.plist}`, `Versions/Current -> A`, and top-level symlinks. The install name `@rpath/CLiteRTLM.framework/CLiteRTLM` still resolves. Fallback: a bare-dylib slice, as Google ships.
   - Fix the iOS slice's plist (`CFBundleSupportedPlatforms = iPhoneOS`, `DTPlatformName = iphoneos`), which wrongly says simulator today.
   - `Package.swift`: `.iOS("27.0"), .macOS("27.0")`.
   - Check that `release-xcframework.sh` zips symlinks (`-y`).
   - Trace the `dlopen`, `posix_spawn` and `fork` imports, and confirm they're fallback-only under the hardened runtime and the sandbox.
2. **Agello `Vendor/use-local-litert.sh`:** keep symlinks, assert `Versions/A`, and print both slices' platforms.
3. **AgelloMac skeleton** (`AgelloMac/App/AgelloMacApp.swift`, `RuntimeSelfTest.swift`, `Info.plist`, `AgelloMac.entitlements`):
   - **`--runtime-self-test`** loads E4B on the GPU, runs `validate()`, generates 64 tokens and embeds one sentence, prints JSON and exits. It stays: the DMG check reuses it.
   - **Settings:**
     - `SDKROOT = macosx`, `MACOSX_DEPLOYMENT_TARGET = 27.0`, `ARCHS = arm64`, Swift 6, no default MainActor isolation;
     - hardened runtime in Debug too;
     - `LD_RUNPATH_SEARCH_PATHS = @executable_path/../Frameworks`;
     - Apple Development signing (ad-hoc signing resets the microphone and camera grants);
     - usage strings that say "this Mac";
     - the `agello` URL scheme.
   - **Entitlements:** `app-sandbox`, `network.client`, `device.audio-input`, `device.camera`, `files.user-selected.read-only`, `application-groups`. None of the iOS ones. No JIT or library-validation exceptions unless the forced-CPU self-test proves one is needed.
- **Verify:**
  - `codesign --verify --deep --strict` and an entitlement dump; `Versions/A` inside `Contents/Frameworks`.
  - The self-test on GPU and on a forced CPU under the hardened runtime.
  - A notarization dry run (`notarytool`, with the maintainer's API key, after asking) and `spctl -a -vvv`.
  - The committed package still compiles.

## M1: split shared from iOS code (the iPhone app behaves the same)

The phone is away, so these are moves and seams that keep iOS defaults. Each one is verified by `swiftlint`, the generic iOS compile and `PLATFORM=mac unit` (plus `inference` for the audio, camera and AppState commits), with an iPhone batch queued. One commit each:
1. **`git mv` into a new `AgelloiOS/` root,** which only the iOS target compiles:
   - `AgelloApp.swift`
   - `Views/ContentView.swift`, `CameraPicker.swift`, `DocumentScanner.swift`
   - `System/BackgroundWork.swift`, `Platform/Haptics.swift`
   - `Info.plist` and `Agello.entitlements`, with `INFOPLIST_FILE` and `CODE_SIGN_ENTITLEMENTS` repointed
2. **Portable rewrites:**
   - Thumbnails: `ImageDownsampler.cgImage(from:maxPixels:)` (in `System/ShareInbox.swift`) with `Image(decorative:scale:)` replaces `UIImage` at `ChatView.swift:532` and `MessageBubbleView.swift:50`.
   - `CameraFeed.snapshot` encodes JPEG with CGImageDestination.
   - `DocumentIngestor.render` draws the PDF page into a CGContext.
   - Announcements use `AccessibilityNotification`.
   - `MetricsReporter` drops `import UIKit`.
   - The `ImagePreparer(UIImage)` overload moves to `AgelloiOS/`.
   - Test fixtures: `AgelloTests/Support/TestImages.swift` (CGContext, CGPDFContext) replaces UIGraphics in `AppStateTests` and `IngestionTests`; the same for `AgelloDeviceTests/TestMedia.swift`.
3. **Seams, one type per platform** (iOS versions extracted verbatim; Mac versions in M2–M5):

| Seam | Shared caller | iOS | Mac |
| --- | --- | --- | --- |
| `MemoryProbe.availableBytes` / `.appMemoryLimitBytes` (`Support/Diagnostics.swift:55`) | `DeviceProfile`, AppState, harness | `os_proc_available_memory` | `host_statistics64` (free, inactive, purgeable); `min(MTLDevice.recommendedMaxWorkingSetSize, RAM)` |
| `MemoryPressureMonitor` (`AppState.swift:196-207`; AppState drops UIKit) | AppState | memory warning | `DispatchSource.makeMemoryPressureSource([.warning, .critical])` |
| `AudioSessionControl` | `VoiceAudio`, `AudioRecorder`, `SpeechReader` | AVAudioSession categories, activation and observers | no-ops; `AVAudioEngineConfigurationChange` stays shared |
| `CameraPreview`, `CameraSource` | `VoiceModeView`, `CameraFeed` | UIViewRepresentable; back camera, 90° | NSViewRepresentable + `AVCaptureVideoPreviewLayer`; `systemPreferredCamera`, 0° |
| `MathLabel` (`MarkdownView.swift:273-299`) | MarkdownView | `MTMathUILabel` as a UIView | `MTMathUILabel` as an NSView |
| `ComposerField` | `ChatView.inputBar` | today's `TextField(axis: .vertical)` | NSTextView wrapper (M4) |
| `CaptureSources` | ChatView's attach menu | camera picker and scanner covers | capture sheet + Continuity Camera |
| `Platform` | views | `copy` (UIPasteboard), `reduceMotion`, `deviceName` "iPhone", `isDesktop` | NSPasteboard, NSWorkspace, "Mac" |
| `ThemeMetrics` (`Theme.Size`, `Theme.Layout`, font roles) | all views | today's values | desktop ladder (M4) |

4. **Modifier shims** in `Support/Theme/PlatformModifiers.swift`, the one shared file with `#if os(iOS)`: `inlineTitleDisplay()`, `urlField()`, `fullScreenOrSheet(...)`. `Theme.swift:214` uses `Platform.reduceMotion`.
5. **Wording.** The 17 "this iPhone" strings use `Platform.deviceName`.
6. **Shared shell extraction** (pixels identical):
   - `Agello/App/AppBootstrap.swift` takes over `AgelloApp.init`.
   - `Agello/Views/Shell/ShellModel.swift` (`@MainActor @Observable`) takes ContentView's actions: perform, new chat, select, pin, rename and delete state, open project, answer shared items.
   - `ShellModifiers.swift`: `.routesExternalRequests` (Spotlight, `onOpenURL`, `AppRouter`) and `.shellDialogs`.
   - `Agello/Views/Sidebar/ChatListModel.swift` and `ChatRows.swift` take the rows, the debounced search and the context menu from `DrawerView`.
   - `Agello/Views/Settings/AppliesEngineSettings.swift` takes SettingsView's engine `onChange` hooks (lines 34–39).
   - Before-and-after mock screenshots of the iPhone app on this Mac.

## M2: AgelloMac compiles and runs the shared app

- **Target setup.** Add `Agello/` to AgelloMac, plus the Mac seam files, `AgelloMacApp` (fills `AppBootstrap`), `MacAppDelegate` and a first `MacRootView`.
- **`MacAppDelegate`:** secure restorable state, `NSApp.appearance = .darkAqua`, no automatic window tabbing.
- **No background policy:** the Mac never calls `enterBackground`, so replies don't stop and `GPUGate` stays open.
- **Downloads** use the background `URLSession`, which reattaches at launch.
- **App icon:** a macOS entry.
- **`AgelloMacTests`:** `TEST_HOST`/`BUNDLE_LOADER` point at `Agello.app/Contents/MacOS/Agello`, and `@testable import Agello` works.
- **Verify:**
  - the Mac compile (`-scheme AgelloMac -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO`) and the iOS compile
  - `PLATFORM=macos-native unit`
  - a real chat on the GPU with local vendoring
  - `PLATFORM=mac unit` unchanged

## M3: platform policy on the Mac

- **Memory classes** (pure, in `DeviceProfile`, tested). The app limit is the Metal working set: about 5.5 GB on 8 GB Macs, about 11 GB on 16 GB.
  - Maximum context: 16K on 8 GB Macs, 32K at 16 GB and up. Default stays 8K.
  - The 400 MB stop applies to the Mac's estimate of available memory.
  - `keepsConversationAcrossHelpers` is driven by that same estimate.
- **Memory pressure.** A pure `MemoryPolicy.action(level:isBusy:)` drives `AppState.relieveMemoryPressure(level:)`.
  - The warning level does what iOS does today.
  - On the Mac, `.critical` while idle also unloads E4B, which reloads in about 1.2 s from the warm cache.
- **Activity and sleep.** `Agello/System/WorkActivity.swift` holds `ProcessInfo.beginActivity(.userInitiated)` around generation, helpers and indexing, against App Nap.
  - The Mac `BackgroundWork` stub prevents idle system sleep during long summaries.
  - Hidden windows never stop GPU work. Measure a reply across system sleep before adding any handling.
- **Keychain:** use `kSecUseDataProtectionKeychain` on the Mac.
- **Downloads:** Mac wording for the expensive-network consent, and a check that a download resumes after quitting.
- **Docs:** the Mac rules go into `agello-inference-rules`.
- **Verify:** `PLATFORM=macos-native` `inference`, `files`, `web`, `thinking`, `probes` and `calibrate`, compared with the M6 numbers; `memory_pressure -S -l critical` during a reply and while idle; a reply with the window hidden for 5 minutes.

## M4: Mac shell and UI (one screen per commit, identifiers kept)

1. **Shell, `MacRootView`.**
   - **Window:** `WindowGroup(id: "main")` with `CommandGroup(replacing: .newItem)` for New Chat, so there's one window. `.handlesExternalEvents` keeps links and Spotlight in it. AppState lives at app level, so a reply survives closing the window. `@SceneStorage` keeps the column visibility.
   - **Sidebar:** `List(selection:)` with the shared rows and `.searchable(placement: .sidebar)`; the `drawer.*` identifiers are kept.
   - **Detail and toolbar:** ChatView in the detail column. The toolbar has New Chat and the chat menu (Pin, Rename, Delete), with `ToolbarSpacer` and `.sharedBackgroundVisibility(.hidden)` on controls that have their own track.
   - **Backdrop:** one mode-tinted `AmbientBackdrop` behind both columns, under a transparent title bar.
2. **Commands.**
   - `Agello/System/ChatCommandRouter.swift`: an AppRouter-style `pending: ChatCommand?` that ChatView consumes, plus a published `ComposerState` for enabling menu items.
   - `AgelloMac/App/AgelloCommands.swift`: `SidebarCommands`, `TextEditingCommands`, `ImportFromDevicesCommands` and a Chat menu.
   - Shortcuts:
     - ⌘N new chat, ⇧⌘N new project, ⌘O attach
     - Return sends, ⇧Return adds a newline, ⌘. stops
     - ⌘F search
     - ⌥⌘T Think, ⌥⌘S Search, ⌥⌘V voice, ⌥⌘D dictate
     - ⇧⌘R rename, ⇧⌘P pin, ⌘⌫ delete, ⌘R regenerate, ⇧⌘C copy the reply
     - ⌘, Settings
3. **Chat on a desktop.**
   - **Composer:** the Mac `ComposerField` is an NSTextView, 1 to 8 lines. It's safe with input methods (`hasMarkedText`), and pasting an image attaches it.
   - **Reading width:** capped at about 720 pt (`Theme.Layout.readingWidth`).
   - **Drop and paste:** a shared `Agello/System/IncomingItems.swift` reuses ShareModel's item-provider loading, and ChatView accepts dropped files and images. iOS gets drops too.
   - **Message actions:** shown on hover and in the right-click menu.
4. **Settings scene:** `Settings { SettingsView() }` with `.appliesEngineSettings()` and a grouped form, without the Done button.
5. **Sheets:** onboarding, the model library and projects. The share inbox is answered when the app becomes active.
6. **Desktop design pass.**
   - **Metrics:** a desktop ladder in `AgelloMac/Platform/ThemeMetrics.swift`, adapted from Vocello: hero 48, composer action 36, pill 28, glyph 24.
   - **Interaction:** hover states in the shared controls, and a tinted focus ring on the composer.
   - **Glass:** a `\.suspendsGlass` gate during generation, adopted only if an ABAB run on the M6 shows at least 3% decode loss.
   - **Accent:** check that system accent blue never leaks into list selection or toggles.
- **Verify each commit:**
  - the Mac compile, swiftlint and `macos-native unit` plus that screen's UI flow
  - the iOS compile and `PLATFORM=mac unit` for every shared edit

## M5: voice and camera on the Mac

- **Voice processing.** `VoiceAudio` runs on AVAudioEngine's voice processing without AVAudioSession. Ducking of other audio is set to the minimum. The fallback for when voice processing fails stays, and the engine restarts when the audio device changes.
- **Cameras.** The default is `systemPreferredCamera`, which picks Continuity Camera when an iPhone is mounted. Voice mode gets a camera menu (built-in, Continuity, external), disconnections are handled, `RotationCoordinator` keeps running, and the snapshot isn't mirrored.
- **Voice mode** opens as a sheet; Esc ends it. **Take Photo** is a capture sheet.
- **Continuity Camera import.** `ImportFromDevicesCommands` and `.importsItemProviders([.image, .pdf])` bring in photos and scans. Scans go through `DocumentIngestor` and OCR.
- **Verify:**
  - the voice, dictation and image scenarios in `macos-native inference`
  - a manual checklist: AirPods, a USB mic unplugged, Continuity photo and scan, the iPhone in portrait and landscape, a FaceTime call during voice mode

## M6: widgets and share extension

- **`AgelloMacWidgets`:**
  - system small and medium widgets, with the accessory families behind `#if os(iOS)`;
  - the Talk and New Chat controls (macOS 26 or later);
  - the `WIDGET_EXTENSION` condition, sandboxed, embedded in AgelloMac.
- **`AgelloMacShare`:**
  - `ShareModel` and `ShareView` move to `AgelloShare/ShareModel.swift` and are shared by both share targets;
  - an `NSViewController` hosts them in an `NSHostingView`;
  - the same activation rule;
  - sandbox and App Group entitlements.
- **Verify:**
  - `ShareInboxTests` in `macos-native unit`
  - sharing from Safari, Finder (a PDF) and Photos, then answering in Agello
  - every widget and control added
  - the App Group container reachable from all three processes with no privacy prompt

## M7: tests and harness

- **`scripts/device-harness.sh` with `PLATFORM=macos-native`:**
  - scheme `AgelloMac`, destination `platform=macOS,arch=arm64`, results in `build/macos-harness/`
  - `ONLY` mapped to the `AgelloMac*` targets
  - allows `ui` and `screenshots`, refuses `memory`, and checks for our runtime
  - clones the models with `cp -c` into the `com.patricedery.agello.mac` container
  - `PLATFORM=mac` (the iPhone app on this Mac) stays as it is
- **`scripts/device-run.sh` with `PLATFORM=macos-native`:** `logs` filters by the Mac app's image path, since both apps are named Agello; `crashes` reads the Mac's diagnostic reports.
- **UI tests:**
  - `AgelloUITests/Support/UITestSupport.swift` is shared by both UI bundles.
  - `AgelloMacUITests/MacChatFlowUITests.swift` covers the shortcuts, the menus, Settings, deep links and the share inbox.
  - `AccessibilityAuditUITests` runs on both.
  - `MacScreenshotTourUITests` takes stills only, since recording throttled the engine in Vocello.

## M8: release engineering (dry runs only)

- **`scripts/mac/` scripts** (adapted from Vocello's `release.sh`, `create_dmg.sh` and `verify_packaged_dmg.sh`):
  1. Archive, then export with `ExportOptions-developer-id.plist`.
  2. Check every component's signature, runtime flag and entitlements: no `get-task-allow`, `Versions/A` present, the same version everywhere.
  3. Build a `hdiutil` DMG with an Applications link and sign it.
  4. `notarytool submit --wait`, then staple and validate.
  5. Mount the DMG and run `spctl`, then `--runtime-self-test` from the mounted app.
- **Privacy manifest and NOTICE:** embed the privacy manifest in the Mac app, run the `nm -u` required-reason check on the Mac slice, and add the per-slice third-party notices to NOTICE.
- **Sparkle, if approved** (decision 4):
  - an AgelloMac-only package, with a "Check for Updates…" command and a Settings toggle;
  - `docs/appcast.xml` on Pages, an EdDSA key, and the sandbox XPC exceptions.
- **Drafted docs:**
  - `docs/privacy.md`: "iPhone or Mac", Continuity Camera, and the update checks if Sparkle is adopted;
  - a Mac section in the README;
  - `docs/USER_GUIDE.md`: shortcuts, drag and drop, Continuity Camera, widgets, share;
  - `docs/ARCHITECTURE.md` and `docs/TESTING.md`.

## M9: Mac gate and publish (after Phase 4.4)

1. **Our release on `main`.** Vendor it with `REF=… TAG=… Vendor/use-release-litert.sh`.
2. **Gate on the M6:** every `macos-native` suite, `calibrate`, an Instruments energy log and the M5 checklist. Then a run on a real M1–M4 Mac, ideally 8 GB: those prefill and precision paths have only been simulated (F-095, F-101).
3. **The real artifact:** notarized and stapled, installed in a fresh user account, and updated through Sparkle from the previous build.
4. **Publish (with the maintainer's OK):** a GitHub release with the DMG, the appcast, the README, and the App Store Connect setting for the iPhone app's Mac availability.

**Docs and skills, in the phase that changes them:**
- `CLAUDE.md`: the new folders, the per-platform file rule, the Mac commands, the interim runtime rule.
- `agello-device-testing`: `macos-native`.
- `agello-inference-rules`: the Mac memory and activity rules.
- `agello-release`: a Mac section.
- `agello-litert-update`: the versioned Mac slice, the iOS plist fix, and the privacy check on both slices.

## Open decisions (recommendation first; confirm at the phase named)

1. **Sandbox the main app: yes** (M0). It keeps the privacy promise system-enforced. It keeps the un-namespaced `Application Support/Models` and SwiftData's `default.store` out of the user's library. The extensions need it anyway, and nothing in the app needs unsandboxed powers.
2. **App Group: `group.com.patricedery.agello`, with Developer ID provisioning profiles** (M0). One constant across platforms, and the profile also enables the data-protection keychain. The alternative is the team-prefixed ID.
3. **Bundle ID `com.patricedery.agello.mac`** (M0). The harness runs `com.patricedery.agello` on this Mac, and a shared ID would share its container, TCC grants and Spotlight. Developer ID has no universal purchase anyway.
4. **Sparkle 2: yes,** with Sparkle's permission prompt, the appcast on Pages, and the privacy policy and NOTICE updates (M8). Otherwise Developer ID users never learn about fixes. The alternative is a "Check for Updates" command that opens the Releases page.
5. **Release order: keep Phase 4's iPhone gate before publishing** (M9). If the phone stays away for weeks, publish the runtime after the Mac gate, with the iPhone gate still required before the iPhone app uses it.
6. **Supported Macs:** Apple silicon, macOS 27, 8 GB minimum (16K maximum context), 16 GB recommended. One real M1–M4 run before shipping.
7. **The iPhone app's automatic Mac App Store availability: opt out** once the native app ships (M9).
8. **Smaller choices:**
   - Settings: the same `SettingsView` in a Settings window.
   - Voice mode: a sheet.
   - Composer: an NSTextView.
   - Glass: gated only if measured.
   - Mac default context: 8K for now.
   - The shortcut set in M4.2.

## Risks

- **Packaging.** The versioned repack could still upset SwiftPM or codesign; M0 proves it, with the bare dylib as the fallback. The hardened runtime could block a fallback `dlopen` or the CPU path; the forced-CPU self-test catches it.
- **The project file.** Exception sets can compile a same-named type twice, so both platforms compile on every commit.
- **Two Agello apps on the dev Mac.** Expect duplicate `agello://` handlers, Spotlight entries and log names; test with `open -b`.
- **Mac voice processing** varies by device: USB and aggregate mics, ducking. Memory estimates on 8 GB Macs may be too eager or too lax; M3 and the M1–M4 gate check them.
- **Continuity Camera has no SwiftUI button,** so the File menu may be the only entry point. Sparkle in the sandbox needs XPC exceptions and adds the first unprompted network request.
- **Schedule and disk.** The Mac release waits on Phase 4, and so on the iPhone gate. A second container adds a cache of about 2.2 GB; clone models with `cp -c` and delete caches after runs.
- **No chat sync** between iPhone and Mac; the user guide says so.

## Verification

| Phase | Gate |
| --- | --- |
| Every commit | `swiftlint` 0 errors; generic iOS compile; Mac compile (`xcodebuild build -project Agello.xcodeproj -scheme AgelloMac -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO -quiet`); `df -h /` before builds |
| M0 | codesign, `spctl`, entitlement dumps; `Versions/A`; self-test on the GPU and on forced CPU; notarization dry run; both slices' plists |
| M1 | `PLATFORM=mac unit` (+ `inference` for audio, camera and AppState); before-and-after mock screenshots; iPhone batch queued (`ui`, `screenshots`, voice with AirPods and a call, camera picker and scanner, haptics, `memory`, drops) |
| M2–M3 | `PLATFORM=macos-native` `unit`, then `inference`, `files`, `web`, `thinking`, `probes`, `calibrate`; memory pressure and hidden-window checks |
| M4–M6 | per screen: the Mac UI flow + `unit`, plus `PLATFORM=mac unit` for shared edits; the manual voice, camera, share and widget checklist |
| M7 | every `macos-native` suite green; `PLATFORM=mac` suites unchanged |
| M8–M9 | release dry run; `verify_packaged_dmg.sh`; fresh-account install; a Sparkle update; the M6 + M1–M4 gate |
| End to end | One Phase 4.2 artifact passes the iPhone batch and the native Mac batch. A DMG from clean `main` with the published runtime installs, finds its models and runs everything: chat, Think, Search, files, voice, Continuity Camera, share, widgets, Shortcuts, links and updates. |
