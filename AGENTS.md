# AGENTS.md

Instructions for Antigravity in Agello (`iRT`) and sibling fork (`../LiteRT-LM`).

## Ground rules

- **`AgelloSim` vs physical iPhone.** Use unshipped `AgelloSim` (`com.patricedery.agello.sim`, `scripts/sim-launch.sh`) for iOS UI, sandboxed features, and real E4B replies across all shipping Swift tools ([ARCHITECTURE](docs/ARCHITECTURE.md)); proxies Metal 4 E4B (`SIM_GPU=Apple_A19_Pro`) + ANE EmbeddingGemma 2 from host `agello serve`. **Benchmarks (`phone-bench.sh`, `bench`), hardware suites (`device-harness.sh`), jetsam `memory`, Metal/ANE/background/audio/WeatherKit/AlarmKit checks, App Store screenshots, and final silicon checks stay on physical iPhone** (`CLiteRTLM.xcframework` has no simulator slice). `.agents/hooks.json` runs `session-start.sh`, `guard-target-edits.sh` (blocks `Agello*/` & `Vendor/LiteRT-LM/` while building; applies to shell too), and `guard-hardware-only.sh` (blocks `axiom_xclog_*` incl. `mcp_*`, `asc-shots-pipeline`, `asc-notarization`).
- **Tool precedence (`mobilebuildmcp`).** Drive `AgelloSim` via `mobilebuildmcp` (`ui-automation`+`simulator`) & `xcrun simctl openurl 'agello://ask?q=...'`. Run iPhone & Mac CLI tasks through `scripts/device-harness.sh`, `device-run.sh`, `phone-bench.sh`, `cli-*.sh` (`mobilebuildmcp` on iPhone ad-hoc only via `manage-workflows`).
- **iPhone-only.** iOS 27.0+, Swift 6 (no default MainActor), 12 GB floor (iPhone 17 Pro+, Air; below: `UnsupportedDeviceView`). Never add a Mac app, Xcode Mac targets, or 8 GB paths. Only Mac build: unshipped CLI `agello` (`Package.swift`, `AgelloCLI/`, [CLI](docs/CLI.md)). App code in `Agello/`; UIKit seams in `AgelloiOS/Platform/` (one type/file, no `#if`s).
- **Our backend only.** Hard fork in one repo ([BACKEND](docs/BACKEND.md)): our GPU runtime + patched model. Never build/download/run/compare Google's binary or CPU backend; upstream repos are read-only (no merges/rebases). Judge speed via our harness (keep Mac idle during measuring runs, this session included) and quality by reading replies.
- **M6 freely; ask before physical iPhone.** Run `AgelloSim`, `cli-test.sh`, `agello`, `build-xcframework.sh --mac-only`, `PLATFORM=mac device-harness.sh`, `cli-bench.sh` (`mac-ready.sh`) freely. **Always ask before physical iPhone runs.** One harness run at a time; phone connected, unlocked, Mirroring closed (exit `4`). Never lock iPhone or toggle Mirroring unless asked.
- **No edits during builds.** Stage `Agello*/` or `Vendor/LiteRT-LM/` edits in `<Artifact Directory Path>/scratch/` (or work in `docs/`, `.agents/`, `scripts/`) until Xcode starts testing. Never edit `../LiteRT-LM` during Bazel builds.
- **Roadmap, Git & storage.** Start from [ROADMAP](docs/ROADMAP.md) `Current status` (`<= 3 KB`) and keep it current; consult [BACKEND_KNOWLEDGE_BASE](docs/BACKEND_KNOWLEDGE_BASE.md) (Part 4 Worth Revisiting / `§4.1` M6-vs-iPhone & Part 6 "Do Not Repeat") before proposing or implementing model, kernel, executor, speculative-decode, ANE, or backend changes, and record every new optimization, probe, fix, negative/reverted result, or M6-vs-iPhone divergence (per Part 7) in the same commit. Commit verified chunks on `main` (fast-forward worktrees); **push only when asked**; zero AI attribution (git, GitHub, HF). Storage: 40 GB budget, 50 GB free on `/` (`scripts/storage.sh` outside sandbox; `clean` deletes scratch; ask before deleting `review`/`keep`).
- **Load skills first** (`.agents/skills/`): `agello-device-testing`, `agello-inference-rules` (before engine/lifecycle/budget/helper/tool edits), `agello-litert-update`, `agello-release`.

## Project

iPhone-only SwiftUI app running Gemma 4 E4B via LiteRT-LM + ANE EmbeddingGemma 2. Docs: `README.md`, `docs/` (`ROADMAP`, `TESTING`, `HARNESS`, `CLI`, `BACKEND`, `BACKEND_KNOWLEDGE_BASE`, `SYSTEM-PROMPT`, `ARCHITECTURE`, `ENGINEERING`, `LITERT-LM`, `USER_GUIDE`, `privacy`), [B5 Perf](docs/archive/performance-b5-2026-11.md).

- **Schemes:** `Agello` (app/widgets/share/tests), `AgelloBench` (Release+`BENCH`), `AgelloSim` (`iphonesimulator`, `SKIP_INSTALL = YES`, links `LiteRTLMTools`). Hooks: `#if DEBUG || BENCH` (CLI defines `BENCH`); `hostsTests`: `#if DEBUG`.
- **Packages:** `Vendor/LiteRT-LM` (Swift wrapper + dual-slice `CLiteRTLM.xcframework`; pins/patches in [Vendor/README.md](Vendor/README.md)), `swift-markdown`, `SwiftMath`. Sync `NOTICE` ↔ `Agello/Resources/NOTICE.txt`.
- **Fork (`../LiteRT-LM`):** `PowerBeef/agello-litert-lm` `main` (`agello/litert`, `agello/ml_drift`, `docs/agello/reference/`, `tools/`, `dist/`). `facts.md` (`b7b856a0`, `2026-11-17`, v1 32K) lags recent phases — cross-check `ROADMAP.md`, `Vendor/README.md`, `BACKEND_KNOWLEDGE_BASE.md`, `ModelCatalog.swift`.

## Quick commands

Setup: copy `.mobilebuildmcp/config.example.yaml` → `config.yaml` (set `deviceId` or `DEVICE_ID`).

```sh
scripts/sim-launch.sh  # --no-build --no-serve --reset --mock
scripts/cli-test.sh unit  # or: security | inference InferenceScenarioTests/test05_ToolCall
PLATFORM=mac scripts/device-harness.sh unit  # or: gate
scripts/device-harness.sh gate  # iPhone (ask first)
swiftlint
xcodebuild build -project Agello.xcodeproj -scheme Agello -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO -quiet
../LiteRT-LM/agello/build-xcframework.sh --mac-only
scripts/storage.sh  # `clean` removes scratch
scripts/cli-bench.sh release next -- --only explain
scripts/phone-bench.sh release next  # iPhone (ask first)
```

Suites, `ONLY` (not `gate`/`all`), durations, exit codes, `--mock-engine`: [TESTING](docs/TESTING.md) & `agello-device-testing`.

## Antigravity workflow

- **Multi-root, backgrounding & lock:** Open `iRT`+`../LiteRT-LM` (rules/skills/hooks in `iRT`). Start long runs with `run_command` (`WaitMsBeforeAsync: 500`), stop calling tools, wait — never poll (`manage_task`; scripts run `caffeinate`). `build/.harness.lock` serializes runs across worktrees — never delete a live lock. Copy `.mobilebuildmcp/config.yaml` (or set `DEVICE_ID`) into share worktrees; remove after fast-forward merge.
- **Sandbox:** Keep **ON** (`swiftlint`, read-only `git`, Python scripts). Use `BypassSandbox: true` for `git add/commit/push`, `sim-launch.sh`, `xcrun simctl`, `device-*.sh`, `phone-bench.sh`, `bench-direct.sh`, `cli-*.sh`, `storage.sh`, `Vendor/use-*.sh`, `xcodebuild`, `swift build`, `bazelisk`, `build-xcframework.sh`, `hf`, `gh`, `asc`; invoke directly without wrappers/chains.
- **Diagnostics & HF:** Pull crashes (`device-run.sh crashes pull`), symbolicate via `axiom` MCP (`axiom_xcsym_crash`/`triage`/`axiom_get_agent`; never `xclog`). See `agello-device-testing` for `AgelloSim`/`cua-driver`. Inspect HF via `huggingface` MCP or `/opt/homebrew/bin/hf` (`PowerBeef02`); download to `--local-dir ~/Models/agello` (or `…/lab`), verify `sha256`, ask before uploading.

## The fix loop

1. **Reproduce** from report, chat store, or bench case; locate root cause (consult `docs/BACKEND_KNOWLEDGE_BASE.md` Part 4 / `§4.1` & Part 6 first for model, kernel, executor, speculative-decode, ANE, or backend work).
2. **Verify on Mac + `AgelloSim`:** `cli-test.sh` + `AgelloSim` via `mobilebuildmcp` (read real replies & screenshots).
3. **Ask & confirm on physical iPhone** (`device-harness.sh`/`phone-bench.sh`) for silicon truth, benchmarks, screenshots.
4. **Update `ROADMAP.md` `Current status` (+ `docs/BACKEND_KNOWLEDGE_BASE.md` per Part 7 in the same commit for any model/backend/runtime optimization, probe, fix, negative/reverted result, or M6-vs-iPhone divergence) and commit** on `main`.

## Architecture

- **`AppState`** (`AppState.swift`, `+Reply/+Tools/+Web/+Chats/+Benchmark`; `@MainActor @Observable`): owns engine, `KnowledgeBase`, `ModelStore`; persists settings in `didSet`; unifies `send`/`regenerate`/`edit`/voice/`ShareInbox` via `generate` (settings→files→web→bind→`fitContext`→save→`engine.send`→`consume` throttled via `ThermalPolicy` `100/200/250 ms`→helpers+Spotlight). `ChatComposerView` isolates draft state via `ComposerBridge`.
- **Engine boundary:** `ChatEngineProtocol` actors: `LiteRTChatEngine` (`ChatEngine.swift`, sole LiteRT-LM owner), `RemoteChatEngine` (`AgelloSim/`), `MockChatEngine`. `EngineFactory` seams (`AgelloiOS/`, `AgelloCLI/`, `AgelloSim/`) select engine/embedder (no `#if targetEnvironment(simulator)` in `Agello/`). Keep `import LiteRTLM` in 3 `Agello/` files (`ChatEngine.swift`, `LiteRTEmbedder.swift`, `AppState+Benchmark.swift`); pure-Swift `LiteRTLMTools` in `Tools.swift`, `PersonalActionTools.swift`, `AutomationTools.swift`, `AppState+Tools.swift`, `ChatEngineProtocol.swift`, `RemoteChatEngine.swift`.
- **Inference & security:** Single live conversation (`serialized { }`, never nested; helpers+`afterHelper()` guard); `InferenceOptions`→`InferencePlanner.resolve` (pure enums). Multilingual parsing via `LanguageSupport.swift` (13 languages); `<untrusted_data>` spotlighting (`AgentSecurity.swift`), memory quarantine, fail-closed `ToolConfirmationGate`+`ToolConfirmationCard`/`PlanConfirmationCard` (`agello-inference-rules`, [ARCHITECTURE](docs/ARCHITECTURE.md)).
- **Persistence:** SwiftData `VersionedSchema` (`Persistence/Schema/`, `V3`), `ChatMigrationPlan`, turn tree (`parentID`, `activeLeafID`), `MessageParts.actionCards` (`LossyArray`, no bump).
- **Knowledge:** `DocumentIngestor`→`Chunker`→`CoreAIEmbedder` on ANE (`EmbeddingGemma 2`, 768 dims, `usesGPU = false`; `LiteRTEmbedder` fallback)→float16 vectors (`VectorIndex`+BM25). `FileContext` picks whole/summary/passages (table hint only for `.csv`/`.tsv`/`.json`). `WebResearch` queries terms-permitted sources+`WebSearchTool` (`getaddrinfo` SSRF, `PublicRedirects`, `maxPageBytes`, `ReadableText` nonces).
- **Outside the app:** Extensions never run models. App Intents (quick actions, composable Shortcuts, `AgelloFocusFilter`, `RunAgelloRecipeIntent`, `IndexedEntity` `OpenIntent`s w/ `requiresAuthentication`) & `agello://` (`recipe/<id>`, `shortcut-result`) → `AppRouter`→`ShellModel`. Share writes `ShareInbox` (`AgelloShare/PrivacyInfo.xcprivacy` `C617.1`). `BackgroundWork` (`BGContinuedProcessingTask`+`BackgroundWorkPlan`) covers synthesis/web/multi-step Think (`onSubmissionFailure` closes `GPUGate`+drains; plain chat stops unless parked for Shortcut handoff); `AgelloWidgets` hosts `AgelloAlarmLiveActivity`. `MetricsReporter` consumes iOS 27 `MetricKit.MetricManager` streams.
- **Design system:** `Support/Theme/`: forced dark palette, 4 accents (Chat glacier, Think lavender, Search teal, Voice gold), Liquid Glass chrome only (`chromeSurface`), `surfaceCard`, `LitButtonStyle`/`LitCircleButtonStyle`, `Theme.Motion`/`appAnimation`. No system blue or literal sizes.
- **Models:** `ModelCatalog.swift` pins HF repo/revision/file/size/SHA-256. `ModelStore` downloads via background `URLSession`, verifies size+SHA-256, unpacks `.aar` atomically, deletes unlisted files (renaming forces re-download).

## Gotchas

- **Mac CLI (`Package.swift`):** Engine-called platform types need twins in `AgelloCLI/Sources/Platform/`; engine files outside `Inference/`/`Knowledge/`/`ModelHub/`/`Persistence/` go in `sources:`; root docs/configs in `exclude:`. Verify via `cli-check.sh`.
- **Synchronized folders & extensions:** Files join automatically; exclude non-Swift files unless bundled. `Agello/` is shared; `AgelloiOS/` holds app-only files & `Platform/` seams (no `#if`); `AgelloSim/` excludes native engine/embedder files via exception sets. Extensions compile only `System/SharedIntents.swift` (`#if !WIDGET_EXTENSION`) + `System/AgelloAlarmMetadata.swift` (widgets) and `System/ShareInbox.swift` (share) — keep `LiteRTLM`/app-only types out.
- **Shared device-test state:** Tests share UserDefaults & Documents; follow `agello-device-testing` isolation rules.
- **Settings decoding:** `InferenceOptions` uses synthesized `Codable` — new non-optional properties reset saved settings; make new keys optional or decode tolerantly.
- **Schema changes:** Require frozen `SchemaV4` (optional/defaulted), migration stage, repointed typealiases+`ChatStore.schema`, on-disk `ChatSchemaTests`. `ChatStoreLoader` moves unopenable stores aside (broken migration wipes history). New `MessageParts` fields need no bump (`decodeIfPresent`).
- **Streaming scroll:** `.defaultScrollAnchor(.bottom, for: .sizeChanges)` via `onScrollGeometryChange`, never per-chunk `scrollTo`; animate `scrollTo(id:anchor: .bottom)` only on new message (`testStreamingNeverJumps`, `mockup-os-search`).
- **No Advanced settings** (removed 2026-11-11): engine choices stay internal (`InferenceOptions.launch` keeps Think only). Five taps on Settings version opens `DeveloperSettingsView`.
- **Multilingual parsers:** No English-only splitters, currency/number parsers, or heuristics. Use structured params (`SearchPlacesTool.near`) & `LanguageSupport.swift`, protect city names (`"Rio de Janeiro"`, `"La Paz"`), test non-English prompts (`LanguageSupportTests`, `test07_MultilingualNaturalToolIntent`).
- **Accessibility IDs:** Keep `screen.element` IDs (`chat.stop`, `composer.think`, `models.ready.<id>`, `tool.confirm.approve`) stable.

## Style

- `swift-format`: 2-space indent, trailing commas, `{` on own line after wrapped conditions, long strings on one line (`.swiftlint.yml`).
- `@MainActor @Observable final class` + `@ObservationIgnored` internals; actors for engine work; `Sendable` across boundaries; `Log.engine`/`.generation`/`.lifecycle` (`com.patricedery.agello`).
- One-line area-prefixed commits, zero AI attribution.
