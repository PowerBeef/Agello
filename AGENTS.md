# AGENTS.md

Project instructions for Antigravity when working in Agello (`iRT`) and its sibling runtime fork (`../LiteRT-LM`).

## Ground rules

- **Physical iPhone only.** Never build, test, or take screenshots in the iOS Simulator: our LiteRT-LM runtime has no simulator build, and the failures that matter only show on hardware. `.agents/hooks.json` hard-blocks simulator MCP tools (`mobilebuildmcp` simulator actions, `axiom_xclog_*`, `simulator-tester`) and forbidden `asc` skills (`asc-shots-pipeline`, `asc-notarization`).
- **Tool precedence (`mobilebuildmcp` override).** Despite the global `mobilebuildmcp` skill's default instruction, **always** run builds, tests, logs, and screenshots through `scripts/device-harness.sh`, `scripts/device-run.sh`, `scripts/phone-bench.sh`, and `scripts/cli-*.sh` — they enforce the lock, preflight, environment variables, and telemetry collection. Only use `mobilebuildmcp` for ad-hoc project inspection or device operations after switching it to the `device` workflow (`manage-workflows`).
- **iPhone-only app.** iOS 27.0+, Swift 6 language mode (no default MainActor isolation), on iPhones with 12 GB of memory (iPhone 17 Pro / Pro Max, iPhone Air, and later; below that the app opens on `UnsupportedDeviceView`). The Mac app was removed on 2026-11-10 (git history before `1f869b1`). Never add a Mac app, Xcode Mac targets, or 8 GB iPhone paths. The one Mac build is `agello`, an unshipped SwiftPM developer CLI (`Package.swift`, `AgelloCLI/`, [docs/CLI.md](docs/CLI.md)). App code lives in `Agello/`, with UIKit seams behind one type per file in `AgelloiOS/Platform/`; no platform `#if`s.
- **Our backend only.** Hard fork in one repository ([docs/BACKEND.md](docs/BACKEND.md), 2026-11-10): our LiteRT-LM runtime on the GPU with our patched model. Never build, download, run, or compare against Google's runtime binary or the CPU backend. Upstream Google repos are read-only sources (no merges or rebases). Performance is judged by our harness (`scripts/cli-bench.sh`, `scripts/phone-bench.sh`, iPhone `bench`); on the Mac it measures system load and compares undisturbed runs ([docs/CLI.md](docs/CLI.md), "System load"), so leave the Mac idle during measuring runs (this session included). Judge output quality by reading replies (identical replies need no judging; answer checks are evidence, not the verdict).
- **M6 Mac mini as primary iPhone 17 Pro workbench.** Develop and test primarily on this M6 Mac mini without requiring the personal iPhone on every change: `scripts/cli-test.sh` and `scripts/cli-bench.sh` default to `SIM_GPU=Apple_A19_Pro` (exact A19 Pro 6-CU Apple10 kernel paths, 8 GiB memory policy, `MallocLargeCache=0`), `../LiteRT-LM/agello/build-xcframework.sh --mac-only` gives fast macOS-slice runtime iteration (~2× faster incremental builds), and `PLATFORM=mac scripts/device-harness.sh` runs the real signed `arm64-iphoneos` app binary ("Designed for iPad/iPhone") for all 384 unit tests and visual UI checks. Run M6 Mac GPU tests and `cli-bench.sh` freely — rely on `scripts/mac-ready.sh` to wait/refuse measuring runs if the Mac is busy, and leave the Mac idle while a measuring run executes. Batch physical iPhone 17 Pro runs (`phone-bench.sh`, `memory`, `ui`, `bench`, background-GPU expiration, Camera/AirPods/ANE latency) to once per completed phase or release gate.
- **One harness run at a time.** Run tests via `scripts/device-harness.sh`. The iPhone must be connected and unlocked for the entire run, with iPhone Mirroring closed: preflight checks this and exits `4` with the one thing to fix.
- **Never lock the iPhone or open/close iPhone Mirroring** unless the user asks at the time. When a run needs the phone unlocked or Mirroring closed, ask the user.
- **Never edit target code during builds.** Do not edit `Agello*/` while a harness run is building (`.agents/hooks/guard-target-edits.sh` denies file-edit tools; the rule also applies to shell commands). Stage changes in `<Artifact Directory Path>/scratch/` or work outside targets (`docs/`, `.agents/`, `scripts/`) until testing begins. Never edit `../LiteRT-LM` sources while Bazel builds (corrupts Bazel's local/disk action cache digests).
- **Roadmap continuity.** Start each session with `Current status` in `docs/ROADMAP.md` (injected by `.agents/hooks/session-start.sh`) and update it whenever status changes (a run finishes, a phase starts, a thread moves).
- **Git & attribution hygiene.** Commit each verified chunk directly on `main` (merge any worktree branch fast-forward into `main`). **Push only when asked.** Never include AI/agent attribution (no `Co-Authored-By`, no Antigravity/Gemini/Claude mentions) in git commits, GitHub issues/comments, or Hugging Face commits/model cards.
- **Storage budget.** Disk space is limited: 40 GB project budget, 50 GB kept free on `/`. `scripts/storage.sh` classifies project disk use as `keep`, `review`, or `scratch` (run outside the sandbox for an accurate reading; `session-start.sh` and harness runs print `brief`). Clean scratch with `scripts/storage.sh clean`; ask before deleting reviewed or kept items. Put new scratch where `storage.sh` tracks it or update the script.
- **Load project skills before the work they cover** (`.agents/skills/`):
  - `agello-device-testing`: running/reading the harness, `bench`, `phone-bench.sh`, `cli-*`, writing tests, known issues.
  - `agello-inference-rules`: mandatory before changing `ChatEngine.swift`, `AppState` generation/lifecycle, `ContextBudget`, `InferencePlanner`, helpers, or tools.
  - `agello-litert-update`: `Vendor/LiteRT-LM`, `PowerBeef/agello-litert-lm` (`../LiteRT-LM`), Bazel builds, #3913, model surgery, Hugging Face pins/uploads.
  - `agello-release`: TestFlight and App Store Connect checklist (`asc` skills).

## Project

Agello is an iPhone-only SwiftUI app running Gemma 4 E4B on-device through LiteRT-LM, with EmbeddingGemma for semantic search. Key docs: `README.md`, `docs/ROADMAP.md` (status/handoff), `docs/HARNESS.md` (autonomous bench), `docs/CLI.md` (Mac CLI), `docs/BACKEND.md` (runtime hard fork), `docs/PERFORMANCE.md` (B5 speed work), `docs/SYSTEM-PROMPT.md`, `docs/TESTING.md`, `docs/ARCHITECTURE.md`, `docs/ENGINEERING.md`, `docs/LITERT-LM.md`.

- **Schemes & build configs:** `Agello` builds the app, `AgelloWidgets`, `AgelloShare`, `AgelloTests` (unit), `AgelloDeviceTests` (real-model scenarios), and `AgelloUITests`. `AgelloBench` builds the app and `AgelloUITests` in the `Bench` configuration (Release + `BENCH`) for `bench`. Launch-argument/bench hooks (`--mock-engine`, `--uitest-*`, `AGELLO_BENCH_*`) compile only under `#if DEBUG || BENCH` (the Mac CLI also defines `BENCH`).
- **Packages:** `Vendor/LiteRT-LM` (local Swift wrapper from fork `main` with 5 Swift patches listed in `Vendor/README.md`, plus checksummed `CLiteRTLM.xcframework` of release `agello-one-20261122-3`, iPhone + Mac Metal slices, LiteRT & ML Drift in-tree), `swift-markdown`, `SwiftMath`. Record new dependency licenses in `NOTICE` and sync to `Agello/Resources/NOTICE.txt` (`cmp NOTICE Agello/Resources/NOTICE.txt`).
- **Sibling fork (`../LiteRT-LM`):** `PowerBeef/agello-litert-lm` on `main` (one repo, one branch): C++ runtime (`agello/litert`, `agello/ml_drift`), `docs/agello/reference/`, `tools/agello-bench/`, `tools/model-surgery/`, and local `dist/`. Take runtime/model facts for docs and commits from `../LiteRT-LM/docs/agello/reference/facts.md` (mapped by `docs/LITERT-LM.md`).

## Commands

Once per machine: `cp .mobilebuildmcp/config.example.yaml .mobilebuildmcp/config.yaml` and set `deviceId` (from `xcrun devicectl list devices`), or pass `DEVICE_ID=<udid>`.

```sh
scripts/device-harness.sh unit      # AgelloTests, ~3 min, scripted engine (iPhone)
PLATFORM=mac scripts/device-harness.sh unit        # all 428 unit tests in real iOS binary on Mac (no phone)
PLATFORM=mac scripts/device-harness.sh inference   # real-model scenarios in iOS binary on Mac; not ui/screenshots/memory/bench
ONLY=AgelloTests/AppStateTests scripts/device-harness.sh unit
ONLY=AgelloDeviceTests/InferenceScenarioTests/test05_ToolCall scripts/device-harness.sh inference
swiftlint                           # repo root; keep 0 errors (size warnings on big types expected)
xcodebuild build -project Agello.xcodeproj -scheme Agello \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet   # compile check, no phone needed
../LiteRT-LM/agello/build-xcframework.sh --mac-only   # fast macos-arm64 runtime build for Mac CLI iteration
scripts/device-run.sh logs 20       # relaunch installed app, save 20 s of logs
scripts/storage.sh                  # disk use vs 40 GB budget; `clean` deletes scratch
swift build -c release --scratch-path build/cli/release   # Mac CLI (docs/CLI.md) -> build/cli/release/release/agello
scripts/cli-bench.sh release next -- --only explain       # interleaved A/B on Mac (default SIM_GPU=Apple_A19_Pro)
scripts/mac-ready.sh                                      # checks Mac load; cli-bench.sh exits 4 if busy
scripts/phone-bench.sh release next                       # batched iPhone 17 Pro hardware gate (Mac only builds)
scripts/cli-test.sh unit                                  # 361 unit tests natively on Mac, ~20 s, no phone
scripts/cli-test.sh inference InferenceScenarioTests/test05_ToolCall   # real-model scenarios on Mac (SIM_GPU=Apple_A19_Pro)
scripts/cli-test.sh security                              # 6-vector adversarial prompt-injection gate on Mac
```

`ONLY` takes `Target/Class[/method]` entries within the chosen suite (not with `all`):

| Suite | Scope |
| --- | --- |
| `unit` / `ui` | `AgelloTests` / `AgelloUITests` |
| `inference` / `files` / `web` / `security` | `AgelloDeviceTests/` `InferenceScenarioTests` / `KnowledgeScenarioTests` / `WebScenarioTests` / `AgentSecurityScenarioTests` |
| `thinking` / `memory` / `probes` / `calibrate` (opt-in) | `AgelloDeviceTests/` `ThinkingScenarioTests` / `MemoryEnvelopeScenarioTests` / `ProbeScenarioTests` / `CalibrationScenarioTests` |
| `screenshots` (opt-in) | `AgelloUITests/ScreenshotTourUITests` (guided real-model tour, one screenshot per screen) |
| `bench` (opt-in, iPhone) | `AgelloUITests/BenchUITests` ([HARNESS.md](docs/HARNESS.md)): Bench build through real UI, traced replies, report in `build/device-harness/bench/` vs `scripts/bench/baseline.json`; `BENCH_RESUME=1` finishes interrupted runs |

- **Exit codes:** `65` test failures, `3` lock held by another run, `4` preflight refused, `2` usage error, `1` bench report found a problem.
- **Debug vs Release:** Tests build Debug (`@testable import`); measure speed only in Release / Bench (`bench`, `bench-direct.sh`, `phone-bench.sh`, `cli-bench.sh`). `--mock-engine` (or `AGELLO_MOCK_ENGINE`) drives the full UI on the scripted engine without a model.

## Antigravity workflow

- **Multi-root workspace.** Open `iRT` and `../LiteRT-LM` together in one Antigravity workspace so C++/Metal runtime sources, `docs/agello/reference/`, and `tools/agello-bench/` are directly readable and editable in-workspace. All project rules, skills, and hooks live in `iRT` (the fork carries none).
- **Session start & hooks.** `.agents/hooks.json` runs `.agents/hooks/session-start.sh` on startup (roadmap `Current status`, git state, `storage.sh brief`, iPhone status, harness lock), `.agents/hooks/guard-target-edits.sh` to block `Agello*/` edits while building, and `.agents/hooks/guard-hardware-only.sh` to block simulator MCP tools and forbidden skills.
- **Background runs.** Suites take 3–20+ min (`phone-bench.sh` ~1–1.5 h). Launch them with `run_command` (`WaitMsBeforeAsync: 500`), stop calling tools, and wait for the completion notification — never poll. Inspect/stop via `manage_task`. The scripts run `caffeinate` until exit. To watch live in a terminal: `tail -n +1 -f build/device-harness/<suite>.log | /opt/homebrew/bin/xcbeautify`.
- **Terminal sandbox & approvals.** Terminal Sandbox stays **ON** for safety (local `swiftlint`, read-only `git status/diff/log`, and Python report/check scripts like `checks.py` run sandboxed). Commands that need `.git` index locks (`git add`, `git commit`, `git push`), Xcode/SwiftPM manifest compilation, `devicectl`, `~/Models/agello`, `DerivedData`, Keychain, or network (`device-harness.sh`, `device-run.sh`, `phone-bench.sh`, `bench-direct.sh`, `cli-check.sh`, `cli-test.sh`, `cli-bench.sh`, `storage.sh`, `Vendor/use-*.sh`, `xcodebuild`, `swift build`, `bazelisk`, `agello/build-xcframework.sh`, `hf`, `gh`, `asc`) require `BypassSandbox: true`. Invoke scripts directly without unnecessary shell wrappers or chained commands so prefix-matched "Always Allow" approvals work cleanly.
- **Lock & parallel worktrees.** `build/.harness.lock` (resolved via `git-common-dir` in `scripts/lib/harness-lock.sh`) serializes runs across all sessions and worktrees (`device-run.sh logs` and `bench-direct.sh` also refuse while an iPhone run holds it). Never delete a live lock. If using Antigravity `swarm` / subagent `share` worktrees, remember `.mobilebuildmcp/config.yaml` is git-ignored and not auto-copied (copy it or set `DEVICE_ID`), and remove temporary worktrees once fast-forward merged to `main`.
- **Diagnostics & GUI inspection.**
  - **Crashes:** Pull with `scripts/device-run.sh crashes pull`, then symbolicate/triage with `axiom` MCP (`axiom_xcsym_crash`, `axiom_xcsym_triage`, `axiom_get_agent`). Never use `axiom_xclog_*` (simulator-only).
  - **Looking at the iPhone or Mac app:** Prefer `bench` or `scripts/device-run.sh screenshot <name>` when the phone is connected. On this M6 Mac mini, after a `PLATFORM=mac` build, launch the real iPhone app binary with `open -b com.patricedery.agello --args --mock-engine` (drop `--mock-engine` for the real model), inspect/interact via `cua-driver` MCP (`list_windows`, `get_window_state`, `click`, `run_steps`), and quit with `osascript -e 'tell application id "com.patricedery.agello" to quit'` before the next run. Only inspect iPhone Mirroring (`com.apple.ScreenContinuity`) via `cua-driver` when the user already has it open and explicitly asks.
- **Hugging Face.** Read the Hub with `huggingface` MCP (`hf_fs`, `hub_repo_details`, `hub_repo_search`, `hf_whoami`) or `/opt/homebrew/bin/hf` (signed in as `PowerBeef02`) — not web scraping. Always download with `--local-dir ~/Models/agello` (or `…/lab`), never into `~/.cache/huggingface`, and verify `sha256` against the Hub. Uploads to `PowerBeef02` publish immediately: require explicit user go-ahead and zero AI attribution.

## The fix loop

1. **Reproduce** from the user's report (screenshot, chat store, or bench case) and locate the root cause in code.
2. **Tune against a table.** For model behavior (prompt, schema, decision), add/run a device test over a table of real app inputs recording every raw output and error so one failure doesn't hide others (`WebScenarioTests/test04_SearchDecisions`). Run alone on the iPhone (~3 min/round) until the table passes (`agello-device-testing`).
3. **Judge quality** with the bench (`scripts/device-harness.sh bench`, [HARNESS.md](docs/HARNESS.md)).
4. **Verify on the iPhone** with every suite the change touches.
5. **Read the bench report** (screenshots + screen text), update docs and `docs/ROADMAP.md`, and commit.

## Architecture

- **`AppState`** (`Agello/AppState.swift`, `+Reply`, `+Tools`, `+Web`, `+Chats`, `+Benchmark`; `@MainActor @Observable`) owns the engine, `KnowledgeBase`, and `ModelStore`, persists settings to UserDefaults in `didSet`, and unifies `send`, `regenerate`, and `edit` (plus voice and ShareInbox) through one `generate` path: pending settings → file context → web search → bind conversation → `fitContext` → save user turn + placeholder → `engine.send` → `consume` (throttled ≤ 100 ms to SwiftData `ChatTurn`) → helpers (memories, title) + Spotlight.
- **Engine boundary.** `ChatEngineProtocol` (`Inference/ChatEngine.swift`) has two actors: `LiteRTChatEngine` (sole owner of LiteRT-LM `Engine` & `Conversation`) and `MockChatEngine` (unit tests, `--mock-engine`). Keep `import LiteRTLM` confined to `ChatEngine.swift`, `Inference/Tools.swift`, `Knowledge/Embedding.swift`, and `AppState+Benchmark.swift`.
- **One live conversation per engine.** `conversationThreadID` tracks the bound chat; cancellation or switching leaves it unbound so the next send reseeds from SwiftData. Helper prompts use throwaway conversations, keeping the main conversation's KV snapshot aside when memory allows (`DeviceProfile.keepsConversationAcrossHelpers`, `lastHelperKeptConversation`). `serialized { }` serializes engine operations — never nest it.
- **Settings → engine.** `InferenceOptions` (`Inference/ChatTypes.swift`) → `InferencePlanner.resolve` → `ResolvedInference`. `requiresEngineReload` picks reload vs reseed; `scheduleApplyOptions` debounces 600 ms. Put pure decision logic in unit-tested enums (`InferencePlanner`, `ContextBudget`, `SystemPrompt`, `FileContext`, `HelperTasks`, `ToolBudget`, `Dictation`, `LanguageSupport`, `StructuredDataQuery`, `UnitConverter`, `PersonalToolsLogic`, `UntrustedContext`), not in `AppState` or views.
- **Tools, security & language-agnostic design.** Users write natural language in any language without special phrasing. Keep user-facing replies in the user's language, keep machine-to-code boundaries structured or canonical (e.g. `SearchPlacesTool.near`, canonical `place`/`weather`/`currency` formats with local place names intact), and route all Swift-side multilingual normalization/parsing through `Inference/LanguageSupport.swift` (13 languages: EN/FR/ES/DE/IT/PT/NL/PL/RU/AR/JA/ZH/KO) — never add English-only splitters or bloat `SystemPrompt.base` in ways that hurt English quality or latency. Spotlight all untrusted external inputs inside `<untrusted_data>` (`AgentSecurity.swift`), quarantine persistent memories from untrusted blocks, and gate every mutating tool (`isReadOnly == false`) behind fail-closed `ToolConfirmationGate` + inline `ToolConfirmationCard`.
- **Persistence.** SwiftData `VersionedSchema`s in `Persistence/Schema/` (current: V3) with `ChatMigrationPlan` and typealiases in `Persistence/ChatHistory.swift`. Turns form a tree (`parentID`) with `activeLeafID` selecting the visible branch (edit/regenerate/version switcher).
- **Knowledge.** `DocumentIngestor` (PDFKit, Vision OCR) → `Chunker` (page-aware passages) → `CoreAIEmbedder` on 16-core ANE (EmbeddingGemma 2, 768 dims, `usesGPU = false`; `LiteRTEmbedder` fallback) → float16 vectors in SwiftData searched by `VectorIndex` (BM25 fallback). `FileContext` chooses whole files, cached summary, or cited passages (adding a targeted `query_table_or_json` hint only for `.csv`/`.tsv`/`.json` files). `Knowledge/Web/` (`WebResearch`) queries only terms-permitted, key-free sources by `SearchTopic` (Wikimedia, Wikidata, Apple Weather/Maps, ECB, Crossref, PubMed) plus `WebSearchTool`.
- **Outside the app.** Extensions cannot run models: App Intents & `agello://` → `AppRouter.shared.pending` → `ShellModel.perform`; Share extension writes to App Group `ShareInbox`. Only long document summaries use `BackgroundWork` (`BGContinuedProcessingTask` with background GPU); other replies stop when backgrounded.
- **Design system.** `Support/Theme/`: forced dark palette (warm neutrals on navy) with four mode accents (Chat glacier, Think lavender, Search teal, Voice gold). Liquid Glass only on chrome (`chromeSurface`, solid fallback under Reduce Transparency); content uses `surfaceCard`; primary buttons use `LitButtonStyle` / `LitCircleButtonStyle`; motion via `Theme.Motion` & `appAnimation`. No system blue, no literal sizes.
- **Models.** `ModelHub/ModelCatalog.swift` pins HF repo, revision, file, exact byte size, and SHA-256. `ModelStore` downloads in background `URLSession`, verifies size, and deletes unlisted files in its folder (renaming a catalog file forces every user to re-download).

## Gotchas

- **Mac CLI compiles engine files too (`Package.swift`).** Any platform type called by engine code needs a macOS twin in `AgelloCLI/Sources/Platform/`; any engine file outside `Inference/`, `Knowledge/`, `ModelHub/`, `Persistence/` must be listed in `Package.swift`'s `sources:`. Verify with `scripts/cli-check.sh` (or `swift build -c release --scratch-path build/cli/release`) after engine changes. Root-level docs/config files must be in `Package.swift`'s `exclude:`.
- **Synchronized folders.** Files added under a target folder join automatically without `.pbxproj` edits; non-Swift files become bundle resources unless excluded (like test `.swiftlint.yml` files). `Agello/` is shared app code; `AgelloiOS/` holds app-only entry, `ContentView`, camera/scanner, `BackgroundWork`, `Info.plist`, entitlements, `UnsupportedDeviceView`, and `Platform/` seams (called directly by name from `Agello/`, no `#if`). Extensions compile only `System/SharedIntents.swift` (widgets, `#if !WIDGET_EXTENSION`) and `System/ShareInbox.swift` (share) via exception sets — keep LiteRTLM and app-only types out of shared extension files.
- **Device tests share app state** (UserDefaults & Documents); follow the isolation rules in `agello-device-testing`.
- **Settings decoding.** `InferenceOptions` uses synthesized `Codable` — a new non-optional stored property breaks decoding of saved settings and silently resets all options. Make new keys optional or decode tolerantly (as `Personalization` does).
- **Schema changes** require a frozen `SchemaV4` (new properties optional/defaulted), migration stage, repointed typealiases + `ChatStore.schema`, and an on-disk migration test (`ChatSchemaTests`). `ChatStoreLoader` moves an unopenable store aside, so a broken migration wipes history instead of crashing. New `MessageParts` fields need no schema bump (`decodeIfPresent`).
- **Chat streaming scroll uses scroll anchors, never per-chunk `scrollTo`.** Keep `.defaultScrollAnchor(.bottom, for: .sizeChanges)` (tracked via `onScrollGeometryChange`), top alignment for short chats, and animated `scrollTo(id:anchor: .bottom)` only when a message is added (`testStreamingNeverJumps` and bench `mockup-os-search` guard this).
- **No Advanced settings screen** (removed 2026-11-11). Engine choices (MTP, Think budget, sampler, vision, audio, image detail, system prompt) belong to the app — never re-expose them in Settings (`InferenceOptions.launch` preserves only Think). Five taps on Settings' version line opens `DeveloperSettingsView` (`showPerformanceDetails`, benchmark, loaded engine info).
- **Multilingual tool & parser hygiene.** Never write English-only preposition splitters, currency/number parsers, transport maps, or keyword heuristics in Swift. Prefer structured tool parameters (`SearchPlacesTool.near`), reuse `LanguageSupport` (`Inference/LanguageSupport.swift`), guard month/preposition stripping so real city names (`"Rio de Janeiro"`, `"La Paz"`) are never mangled, and test natural non-English prompts with no tool names mentioned (`LanguageSupportTests`, `KnowledgeScenarioTests/test07_MultilingualNaturalToolIntent`).
- **Accessibility identifiers** follow `screen.element` (`chat.stop`, `composer.think`, `models.ready.<id>`, `tool.confirm.approve`); UI tests depend on them — keep stable.

## Style

- `swift-format` layout: 2-space indent, trailing commas in multi-line lists, `{` on its own line after wrapped conditions, long string literals on one line. `.swiftlint.yml` encodes the rest.
- UI state: `@MainActor @Observable final class` with `@ObservationIgnored` internals; engine work in actors; only `Sendable` crosses boundaries. Log with `Log.engine`, `.generation`, or `.lifecycle` (`com.patricedery.agello`).
- Commit subjects: one line, area-prefixed (`Harness: …`, `Probe 12: …`), no AI attribution.
