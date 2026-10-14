# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Ground rules

- The physical iPhone is the only test device. Never build, test, or take screenshots in the simulator: it has no Metal path for LiteRT-LM.
- Run tests with `scripts/device-harness.sh` (below). The iPhone must be connected and unlocked for the whole run.
- Don't edit files in the target folders (`Agello*/`) while a harness run is building: stage changes elsewhere and apply them after the run.
- Commit after each verified chunk, directly on `main`. Push only when asked.
- Use the project skills in `.claude/skills/` before the work they cover:
  - `agello-device-testing`: running and reading the harness, writing scenarios, known failures.
  - `agello-inference-rules`: before changing the engine, `AppState` generation, budgets, or helpers.
  - `agello-litert-update`: the vendored LiteRT-LM, and the `PowerBeef/LiteRT-LM` fork in `../LiteRT-LM`.
  - `agello-release`: TestFlight and App Store preparation.

## Project

Agello is an iPhone-only SwiftUI app (iOS 27.0, Swift 6 language mode, no default MainActor isolation) that runs Gemma 4 E4B on-device through LiteRT-LM, with EmbeddingGemma for search by meaning. `README.md` is the project page (features, performance, highlights); `docs/` holds the user guide, architecture, engineering notes (the #3913 fix, reliability safeguards) and testing; `docs/archive/` is a superseded plan.

- One shared scheme, `Agello`, builds the app, the `AgelloWidgets` and `AgelloShare` extensions, and the test targets `AgelloTests` (unit), `AgelloDeviceTests` (real-model scenarios) and `AgelloUITests`.
- Packages: `Vendor/LiteRT-LM` (local: the Swift wrapper from the fork's `agello` branch, v0.18.0 plus one tool-call patch, and Google's checksummed prebuilt `CLiteRTLM.xcframework`), `swift-markdown`, `SwiftMath`. Record any new dependency's license in `NOTICE`.
- `../LiteRT-LM` is a clone of the fork with the full C++ runtime source; `.claude/settings.json` makes it readable from here.

## Commands

Once per machine, `cp .mobilebuildmcp/config.example.yaml .mobilebuildmcp/config.yaml` and set `deviceId` (from `xcrun devicectl list devices`), or prefix commands with `DEVICE_ID=<udid>`.

```sh
scripts/device-harness.sh unit      # AgelloTests, ~3 min, scripted engine
ONLY=AgelloTests/AppStateTests scripts/device-harness.sh unit
ONLY=AgelloDeviceTests/InferenceScenarioTests/test05_ToolCall scripts/device-harness.sh inference
swiftlint                           # repo root; keep 0 errors (size warnings on the big types are expected)
xcodebuild build -project Agello.xcodeproj -scheme Agello \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet   # compile check, no phone needed
scripts/device-run.sh logs 20       # relaunch the installed app, save 20 s of its logs
```

`ONLY` takes `Target/Class[/method]` entries inside the chosen suite (not with `all`):

| Suite | Scope |
| --- | --- |
| `unit` / `ui` | `AgelloTests` / `AgelloUITests` |
| `inference` / `files` / `web` | `AgelloDeviceTests/` `InferenceScenarioTests` / `KnowledgeScenarioTests` / `WebScenarioTests` |
| `thinking` / `memory` / `probes` / `calibrate` (opt-in) | `AgelloDeviceTests/` `ThinkingScenarioTests` / `MemoryEnvelopeScenarioTests` / `ProbeScenarioTests` / `CalibrationScenarioTests` |
| `screenshots` (opt-in) | `AgelloUITests/ScreenshotTourUITests`: a guided tour with the real model, one screenshot per screen |

- Suites take 3–15 minutes: run them with the Bash tool's `run_in_background` and wait for the notification. Results land in `build/device-harness/`; the exit code is 65 when tests fail.
- Tests build Debug (`@testable import`); measure speed in Release. MobileBuildMCP (from your user-scope MCP config; `.mobilebuildmcp/config.yaml` keeps it to device workflows) reads the same `config.yaml`, but run tests through the harness: it sets each suite's environment and collects the results.
- `--mock-engine` (or the `AGELLO_MOCK_ENGINE` environment variable) runs the whole UI on the scripted engine, without a model.

## Architecture

- **`AppState`** (`Agello/AppState.swift`, `@MainActor @Observable`) is the hub. It owns the engine, `KnowledgeBase` and `ModelStore`, persists settings to UserDefaults in `didSet`, and runs generation. `send`, `regenerate` and `edit` share one `generate` path (voice turns and shared items go through `send`): pending settings → file context → web search → bind the conversation → `fitContext` → save the user turn and a placeholder reply → `engine.send` → `consume` (writes streamed text into the SwiftData `ChatTurn` at most every 100 ms) → memories, title, Spotlight.
- **Engine boundary.** `ChatEngineProtocol` (`Inference/ChatEngine.swift`) has two actors: `LiteRTChatEngine`, the only owner of LiteRT-LM's `Engine` and `Conversation`, and the scripted `MockChatEngine` (unit tests, `--mock-engine`). `LiteRTLM` is imported only by `ChatEngine.swift`, `Inference/Tools.swift`, `Knowledge/Embedding.swift` and AppState's benchmark; keep it contained.
- **One live conversation per engine.** AppState tracks which chat the native conversation holds (`conversationThreadID`). Helper prompts (titles, memories, dictation, web queries, summaries), cancellation and chat switches leave it empty or unbound, and the next send reseeds it from SwiftData history. `serialized { }` runs engine work one operation at a time; never nest it.
- **Settings → engine.** `InferenceOptions` (`Inference/ChatTypes.swift`) → `InferencePlanner.resolve` → `ResolvedInference`. `requiresEngineReload` picks a full reload or a conversation reseed; `scheduleApplyOptions` debounces edits by 600 ms. Decision logic lives in pure, unit-tested enums (`InferencePlanner`, `ContextBudget` in `InferencePlanner.swift`, `SystemPrompt`, `FileContext`, `HelperTasks`, `ToolBudget`, `Dictation`); put new logic there, not in AppState or views.
- **Persistence.** SwiftData `VersionedSchema`s in `Persistence/Schema/` (current: V3) with `ChatMigrationPlan`; code uses the typealiases in `Persistence/ChatHistory.swift`. Turns form a tree (`parentID`), and the thread's `activeLeafID` selects the visible branch: that's how edit, regenerate and the version switcher work.
- **Knowledge.** `KnowledgeBase`: `DocumentIngestor` (PDFKit, Vision OCR) → `Chunker` (page-aware passages) → `LiteRTEmbedder` (EmbeddingGemma) → float16 vectors stored in SwiftData and searched by brute force (`VectorIndex`), with BM25 as the fallback. `FileContext` chooses whole files, a cached summary, or cited passages. `Knowledge/Web/` holds `WebResearch` (the chosen provider, then DuckDuckGo, then Wikipedia) and `WebSearchTool` for automatic mode.
- **Outside the app.** Extensions can't run the model, so everything hands off to the app: App Intents and `agello://` links → `AppRouter.shared.pending` → `ContentView`; the share extension leaves items in the App Group `ShareInbox`, which the app answers on launch and activation. Long document summaries run under `BackgroundWork` (`BGContinuedProcessingTask` with background GPU); other replies stop when the app leaves the foreground.
- **Design system.** `Support/Theme/`, adapted from the Vocello app: one dark palette (warm neutrals on a navy canvas, forced app-wide) and four mode accents (chat glacier, Think lavender, Search teal, Voice gold) that tint the backdrop glow, the pills and the send button. Liquid Glass stays on chrome (`chromeSurface`: composer, banners) and falls back to solid under Reduce Transparency; content uses `surfaceCard`; the primary action uses `LitButtonStyle` / `LitCircleButtonStyle`; motion goes through `Theme.Motion` and `appAnimation` (off under Reduce Motion). Build UI from these tokens and components: no system blue, no literal sizes.
- **Models.** `ModelHub/ModelCatalog.swift` describes each download (Hugging Face repo, file, exact size). `ModelStore` downloads in a background `URLSession`, checks the size, and deletes any file in its folder the catalog doesn't list, so renaming a catalog file makes every user download it again.

## Gotchas

- **Synchronized folders.** A file added under a target's folder joins that target without a `project.pbxproj` edit; non-Swift files become bundle resources unless excluded (as each test folder's `.swiftlint.yml` is). Files under `Agello/` build into the app only. The extensions compile exactly `System/SharedIntents.swift` (widgets, `#if !WIDGET_EXTENSION`) and `System/ShareInbox.swift` (share) through exception sets, so shared code can't use LiteRTLM or app-only types.
- **Tests run inside the app on the phone** and share its UserDefaults and Documents; `agello-device-testing` covers the isolation rules.
- **Settings decoding.** `InferenceOptions` uses synthesized `Codable`: a new non-optional stored key makes saved settings fail to decode and silently resets every option. Make new keys optional, or decode tolerantly as `Personalization` does.
- **Schema changes** need a new frozen `SchemaV4` (new properties optional or defaulted), a migration stage, repointed typealiases and `ChatStore.schema`, and an on-disk migration test like those in `ChatSchemaTests`. `ChatStoreLoader` moves a store that won't open aside and starts empty, so a broken migration wipes history instead of crashing. New `MessageParts` fields need no new version (decoded with `decodeIfPresent`).
- **The chat list follows streaming text through scroll anchors**, not `scrollTo`: `.defaultScrollAnchor(.bottom, for: .sizeChanges)` while the user is at the bottom (tracked with `onScrollGeometryChange`), top alignment for short chats, and an animated `ScrollPosition.scrollTo(edge: .bottom)` only when a message is added. A `scrollTo` per streamed update lands a frame late and made the chat jump; `testStreamingNeverJumps` guards it.
- **Settings → Advanced** (`AdvancedSettingsView`) holds the engine's developer controls; "Show performance details" (`showPerformanceDetails`) turns on the stats line under replies, which is hidden by default.
- **Accessibility identifiers** follow `screen.element` (`chat.stop`, `composer.think`, `models.ready.<id>`). UI tests find elements by them, so keep them stable.

## Style

- swift-format layout: 2-space indent, trailing commas in multi-line lists, `{` on its own line after a wrapped condition, long string literals on one line. `.swiftlint.yml` encodes the rest.
- UI state is a `@MainActor @Observable final class` with `@ObservationIgnored` internals; engine work runs in actors, and only `Sendable` values cross. Log with `Log.engine`, `.generation` or `.lifecycle` (subsystem `com.patricedery.agello`).
- Commit subjects are one line, usually prefixed with the area (`Harness: …`, `Probe 12: …`).
