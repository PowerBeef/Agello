# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Ground rules

- Test on the physical iPhone, or on this Mac running the iPhone app (`PLATFORM=mac`, "Designed for iPad/iPhone", same Metal path). Never build, test, or take screenshots in the simulator: our runtime has no simulator build, and the failures that matter only show on hardware. `.claude/settings.json` denies the desktop app's simulator tools.
- Agello is an iPhone app only: iOS 27 and up, on iPhones with 12 GB of memory (iPhone 17 Pro and Pro Max, iPhone Air, and later; below that the app opens on `UnsupportedDeviceView`). The Mac app was removed on 2026-11-10 (the maintainer's choice; it's in the git history before `3a97e08`). Don't add Mac targets or 8 GB iPhone paths. App code lives in `Agello/`, with what touches UIKit behind one type per seam in `AgelloiOS/Platform/`; there are no platform `#if`s.
- This Mac can run the iPhone app when the phone is away (`PLATFORM=mac`, "Designed for iPad/iPhone"). Its speed and memory aren't the iPhone's, every change that ships needs an iPhone run, and the maintainer often keeps the Mac busy: ask before a Mac run.
- Run tests with `scripts/device-harness.sh` (below), one run at a time. The iPhone must be connected and unlocked for the whole run.
- Never lock the iPhone or end iPhone Mirroring unless the user asks at the time: mirroring keeps the phone's own screen dark, so there's no burn-in to avoid.
- Don't edit files in the target folders (`Agello*/`) while a harness run is building: stage changes elsewhere and apply them after the run. A hook denies Edit and Write there during the build; edits through Bash aren't checked, and the rule still holds for them.
- Start each session with the "Current status" section of `docs/ROADMAP.md` (the session-start hook prints it), and update it whenever the status changes (a run finishes, a phase starts, a thread moves).
- Commit after each verified chunk, directly on `main` (a worktree session's branch is merged into `main`, below). Push only when asked.
- Disk space on this Mac is limited, and the project has a storage budget: 30 GB, with 50 GB kept free on `/`. `scripts/storage.sh` itemizes everything the project writes (models and lab models, the app containers, DerivedData, worktrees, Bazel, the fork checkouts and bench builds) as kept, to review, or scratch; the session-start hook and every harness run print its summary. Act on it: `scripts/storage.sh clean` deletes the scratch (one-off harness OUT folders once their numbers are recorded, engine caches beside the models or from another runtime build, DerivedData of removed checkouts, Bazel's disk cache beyond 6 GB), ask the user about what it lists to review, and when the project is over budget ask which kept items can go. Put new scratch where the script looks, or teach the script about it.
- Use the project skills in `.claude/skills/` before the work they cover:
  - `agello-device-testing`: running and reading the harness, writing scenarios, known failures.
  - `agello-inference-rules`: before changing the engine, `AppState` generation, budgets, or helpers.
  - `agello-litert-update`: the vendored LiteRT-LM, and the `PowerBeef/agello-litert-lm` fork of LiteRT-LM, cloned at `../LiteRT-LM`.
  - `agello-release`: TestFlight and App Store preparation.

## Project

Agello is an iPhone-only SwiftUI app (iOS 27.0, Swift 6 language mode, no default MainActor isolation) that runs Gemma 4 E4B on-device through LiteRT-LM, with EmbeddingGemma for search by meaning. `README.md` is the project page (features, performance, highlights); `docs/` holds the user guide, architecture, engineering notes (the #3913 fix, reliability safeguards), testing, the roadmap (`ROADMAP.md`) and the approved plan for the autonomous harness (`HARNESS.md`); `docs/archive/` is a superseded plan.

- One shared scheme, `Agello`, builds the app, the `AgelloWidgets` and `AgelloShare` extensions, and the test targets `AgelloTests` (unit), `AgelloDeviceTests` (real-model scenarios) and `AgelloUITests`. A second scheme, `AgelloBench`, builds the app and `AgelloUITests` in Release for the `bench` suite.
- Packages: `Vendor/LiteRT-LM` (local: the Swift wrapper from the fork's `agello-next` branch, with four Swift patches (tool-call errors, a stream's weak reference to its conversation, streams kept by ID with bounded tool rounds, the tokenizer and embedding overflow; `Vendor/README.md` lists them), and our runtime: the checksummed `CLiteRTLM.xcframework` of the fork's release `agello-next-20261024`, iPhone and Mac slices on Metal, built with our LiteRT and ML Drift forks), `swift-markdown`, `SwiftMath`. Record any new dependency's license in `NOTICE`, and copy it to `Agello/Resources/NOTICE.txt` (Settings → Licenses shows that copy; `cmp NOTICE Agello/Resources/NOTICE.txt`).
- `../LiteRT-LM` is a clone of the fork with the full C++ runtime source; `.claude/settings.json` makes it readable from here.
- `docs/LITERT-LM.md` maps what Agello uses of LiteRT-LM to the fork's verified reference (`../LiteRT-LM/docs/agello/reference/`): take runtime and model facts for docs and commit messages from its `facts.md`.

## Commands

Once per machine, `cp .mobilebuildmcp/config.example.yaml .mobilebuildmcp/config.yaml` and set `deviceId` (from `xcrun devicectl list devices`), or prefix commands with `DEVICE_ID=<udid>`.

```sh
scripts/device-harness.sh unit      # AgelloTests, ~3 min, scripted engine
PLATFORM=mac scripts/device-harness.sh inference   # on this Mac; not ui, screenshots or memory
ONLY=AgelloTests/AppStateTests scripts/device-harness.sh unit
ONLY=AgelloDeviceTests/InferenceScenarioTests/test05_ToolCall scripts/device-harness.sh inference
swiftlint                           # repo root; keep 0 errors (size warnings on the big types are expected)
xcodebuild build -project Agello.xcodeproj -scheme Agello \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet   # compile check, no phone needed
scripts/device-run.sh logs 20       # relaunch the installed app, save 20 s of its logs
scripts/storage.sh                  # the project's disk use against its budget; `clean` deletes the scratch
```

`ONLY` takes `Target/Class[/method]` entries inside the chosen suite (not with `all`):

| Suite | Scope |
| --- | --- |
| `unit` / `ui` | `AgelloTests` / `AgelloUITests` |
| `inference` / `files` / `web` | `AgelloDeviceTests/` `InferenceScenarioTests` / `KnowledgeScenarioTests` / `WebScenarioTests` |
| `thinking` / `memory` / `probes` / `calibrate` (opt-in) | `AgelloDeviceTests/` `ThinkingScenarioTests` / `MemoryEnvelopeScenarioTests` / `ProbeScenarioTests` / `CalibrationScenarioTests` |
| `screenshots` (opt-in) | `AgelloUITests/ScreenshotTourUITests`: a guided tour with the real model, one screenshot per screen |
| `bench` (opt-in, iPhone) | `AgelloUITests/BenchUITests`: the autonomous harness ([HARNESS.md](docs/HARNESS.md)). Bench cases through the app's screens in a Release build, each reply traced; the report lands in `build/device-harness/bench/` and opens with what changed since the baseline (`scripts/bench/baseline.json`). `BENCH_RESUME=1` finishes a run cut short |

- Suites take 3–15 minutes: run them with the Bash tool's `run_in_background` and wait for the notification. Results land in `build/device-harness/` (`build/mac-harness/` on the Mac); the exit code is 65 when tests fail.
- Tests build Debug (`@testable import`); measure speed in Release. MobileBuildMCP (from your user-scope MCP config; `.mobilebuildmcp/config.yaml` keeps it to device workflows) reads the same `config.yaml`, but run tests through the harness: it sets each suite's environment and collects the results.
- `--mock-engine` (or the `AGELLO_MOCK_ENGINE` environment variable) runs the whole UI on the scripted engine, without a model.

## Claude desktop app

The project is worked on in the Claude Code desktop app on this Mac. `.claude/settings.json` and `.claude/hooks/` set it up, and work the same in the CLI.

- **Session start.** A hook prints the roadmap's "Current status", the git state (changed files, commits not pushed), the project's disk use (`scripts/storage.sh brief`), whether the iPhone is reachable, and any harness run in progress.
- **Harness runs.** Start suites with the Bash tool's `run_in_background`: you're told when the run ends, and the script keeps the Mac awake (`caffeinate`) until then, so a run can outlast the turn. To let the user watch one, open a Terminal panel tab on `tail -n +1 -f build/device-harness/<suite>.log | /opt/homebrew/bin/xcbeautify`.
- **The preflight.** An iPhone run first checks that the phone is reachable and unlocked, that iPhone Mirroring is closed and that this Mac has 10 GB free, and exits with 4 and the one thing to fix. Ask the user to unlock the phone or close Mirroring: don't do it for them.
- **The lock.** The script holds `build/.harness.lock` in the main checkout and exits with 3 while another run holds it, from any session or worktree; the edit hook reads it. A lock whose process has gone is replaced. Never delete a live one.
- **Parallel sessions** share the iPhone and this Mac: one harness run at a time, and Mac speed numbers measured while another session builds are suspect.
- **Worktrees.** A parallel session can run in a worktree (`.claude/worktrees/`, git-ignored). New worktrees branch from the local `HEAD` (`worktree.baseRef` is `"head"`), so unpushed commits come along, and `.worktreeinclude` copies `.mobilebuildmcp/config.yaml` in. The session commits to its own `claude/…` branch. Once it's verified, rebase it onto `main` if `main` has moved, merge it from a session in the main checkout (`git merge --ff-only refs/heads/<branch>`), and don't push the branch. Each worktree builds into its own DerivedData (about 1 GB) and `build/`, so remove it once merged (Settings → This computer → Storage lists them). The sibling checkouts (`../LiteRT-LM`, `../agello-arms/`) don't resolve from inside a worktree: fork work runs from the main checkout, or in a session opened on the fork.
- **Looking at the iPhone.** The user may mirror the phone to this Mac (iPhone Mirroring, "Recopie de l'iPhone", `com.apple.ScreenContinuity`), and computer use has access to it: look and tap with the background `app_*` tools, and the user keeps the Mac. It authenticates automatically. After a few minutes idle the session pauses (Apple's design, no setting): click its "Connexion" button to resume. A harness run takes over the phone, and the mirror shows "iPhone en cours d'utilisation" until the phone is locked, which is the user's call: look before or after runs, not during. The other way round, opening the mirror locks the phone and stops a running suite ("Unlock iPhone … to Continue"): before a long iPhone run, ask the user to leave it closed until the run ends.
- **Hugging Face.** The user's setup has the `hf` CLI (Homebrew, signed in as PowerBeef02), the `huggingface-skills` plugin's skills and its Hub tools (`hf_fs`, `hub_repo_details`, `hub_repo_search`). The old HF connector and `hf-mcp-server` are gone. The setup is the user's: adopt it, don't change it. Load `huggingface-skills:hf-cli` before `hf` work.
  - Reads (a repo's files, its model card, new uploads): `hf_fs` (`ls` or `cat hf://models/<repo>/…`), `hub_repo_details`, or `hf models list|info`. Not WebFetch.
  - Downloads: `hf download <repo> <file> --revision <commit> --local-dir ~/Models/agello` (or `…/lab`). Never the shared cache, `~/.cache/huggingface`, which holds other projects' models and isn't in the budget. Check the file's sha256 against the Hub's.
  - Pins: `hf models list <repo> --revision <commit> --format json` gives each file's `size` and `lfs.sha256`, `ModelCatalog`'s `sizeBytes` and `sha256`.
  - Uploads to PowerBeef02's repos publish: only on the user's go, with no Claude attribution in the commit or the model card, as for GitHub posts.
- **Looking at the app without the phone.** After a `PLATFORM=mac` run has installed it, `open -b com.patricedery.agello --args --mock-engine` opens the iPhone app on this Mac (drop `--mock-engine` for the real model), and computer use can look at it and tap through it once the user grants access to Agello. It's the build of that last run. Quit it with `osascript -e 'tell application id "com.patricedery.agello" to quit'` before the next run.

## The fix loop

How a behavior the user reports gets fixed (Search when needed, 2026-11-02):

1. **Reproduce** from the user's report (a screenshot, the phone's chat store, or a bench case) and find the cause in the code.
2. **Tune against a table.** When the fix is the model's behavior (a prompt, a schema, a decision), write a device test that runs a table of cases with their expected outcome and records each raw output and error, so one bad case doesn't hide the rest (`WebScenarioTests/test04_SearchDecisions`). Put the app's real input in the table, not a tidy stand-in. Run it alone on the iPhone, about three minutes a round: `ONLY=AgelloDeviceTests/<Class>/<test> scripts/device-harness.sh <suite>`, then `jq '.scenarios.<name>' build/device-harness/harness-report.json`. Iterate until the table is right.
3. **Judge quality** where answers matter with the bench (`scripts/device-harness.sh bench`, [HARNESS.md](docs/HARNESS.md)): it sends the cases through the app's own screens and checks the replies.
4. **Verify on the iPhone** with the suites the change touches.
5. **Read the bench report** for what the user would see (screenshots and the text on screen are in it), then update the docs and the roadmap and commit.

## Architecture

- **`AppState`** (`Agello/AppState.swift`, `@MainActor @Observable`) is the hub. It owns the engine, `KnowledgeBase` and `ModelStore`, persists settings to UserDefaults in `didSet`, and runs generation. `send`, `regenerate` and `edit` share one `generate` path (voice turns and shared items go through `send`): pending settings → file context → web search → bind the conversation → `fitContext` → save the user turn and a placeholder reply → `engine.send` → `consume` (writes streamed text into the SwiftData `ChatTurn` at most every 100 ms) → memories, title, Spotlight.
- **Engine boundary.** `ChatEngineProtocol` (`Inference/ChatEngine.swift`) has two actors: `LiteRTChatEngine`, the only owner of LiteRT-LM's `Engine` and `Conversation`, and the scripted `MockChatEngine` (unit tests, `--mock-engine`). `LiteRTLM` is imported only by `ChatEngine.swift`, `Inference/Tools.swift`, `Knowledge/Embedding.swift` and AppState's benchmark; keep it contained.
- **One live conversation per engine.** AppState tracks which chat the native conversation holds (`conversationThreadID`). Cancellation and chat switches leave it empty or unbound, and the next send reseeds it from SwiftData history. Helper prompts (titles, memories, dictation, web queries, summaries) do too on Google's runtime; ours keeps the chat's conversation when memory allows (`DeviceProfile.keepsConversationAcrossHelpers`, `lastHelperKeptConversation`). `serialized { }` runs engine work one operation at a time; never nest it.
- **Settings → engine.** `InferenceOptions` (`Inference/ChatTypes.swift`) → `InferencePlanner.resolve` → `ResolvedInference`. `requiresEngineReload` picks a full reload or a conversation reseed; `scheduleApplyOptions` debounces edits by 600 ms. Decision logic lives in pure, unit-tested enums (`InferencePlanner`, `ContextBudget` in `InferencePlanner.swift`, `SystemPrompt`, `FileContext`, `HelperTasks`, `ToolBudget`, `Dictation`); put new logic there, not in AppState or views.
- **Persistence.** SwiftData `VersionedSchema`s in `Persistence/Schema/` (current: V3) with `ChatMigrationPlan`; code uses the typealiases in `Persistence/ChatHistory.swift`. Turns form a tree (`parentID`), and the thread's `activeLeafID` selects the visible branch: that's how edit, regenerate and the version switcher work.
- **Knowledge.** `KnowledgeBase`: `DocumentIngestor` (PDFKit, Vision OCR) → `Chunker` (page-aware passages) → `LiteRTEmbedder` (EmbeddingGemma) → float16 vectors stored in SwiftData and searched by brute force (`VectorIndex`), with BM25 as the fallback. `FileContext` chooses whole files, a cached summary, or cited passages. `Knowledge/Web/` holds `WebResearch` (the chosen provider, then DuckDuckGo, then Wikipedia) and `WebSearchTool` for automatic mode.
- **Outside the app.** Extensions can't run the model, so everything hands off to the app: App Intents and `agello://` links → `AppRouter.shared.pending` → the shell's `.routesExternalRequests` → `ShellModel.perform` (`Views/Shell/`); the share extension leaves items in the App Group `ShareInbox`, which the app answers on launch and activation. Long document summaries run under `BackgroundWork` (`BGContinuedProcessingTask` with background GPU); other replies stop when the app leaves the foreground.
- **Design system.** `Support/Theme/`, adapted from the Vocello app: one dark palette (warm neutrals on a navy canvas, forced app-wide) and four mode accents (chat glacier, Think lavender, Search teal, Voice gold) that tint the backdrop glow, the pills and the send button. Liquid Glass stays on chrome (`chromeSurface`: composer, banners) and falls back to solid under Reduce Transparency; content uses `surfaceCard`; the primary action uses `LitButtonStyle` / `LitCircleButtonStyle`; motion goes through `Theme.Motion` and `appAnimation` (off under Reduce Motion). Build UI from these tokens and components: no system blue, no literal sizes.
- **Models.** `ModelHub/ModelCatalog.swift` describes each download (Hugging Face repo, file, exact size). `ModelStore` downloads in a background `URLSession`, checks the size, and deletes any file in its folder the catalog doesn't list, so renaming a catalog file makes every user download it again.

## Gotchas

- **Synchronized folders.** A file added under a target's folder joins that target without a `project.pbxproj` edit; non-Swift files become bundle resources unless excluded (as each test folder's `.swiftlint.yml` is). Files under `Agello/` are the app's code, also compiled into the extensions where exception sets say so; `AgelloiOS/` holds the app's own part: the app entry, `ContentView` (the drawer shell), the camera and scanner, `BackgroundWork`, its `Info.plist` and entitlements, and `Platform/`, one file per seam (memory limits, the memory warning, the audio session, the camera, haptics, the clipboard, `Theme.Size`, the composer field, display math). Code in `Agello/` calls those types by name, with no `#if`. The extensions compile exactly `System/SharedIntents.swift` (widgets, `#if !WIDGET_EXTENSION`) and `System/ShareInbox.swift` (share) through exception sets, so shared code can't use LiteRTLM or app-only types.
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
