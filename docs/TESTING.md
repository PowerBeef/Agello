# Testing

Agello uses a clear split between fast in-app Simulator testing and physical-hardware verification:

- **iOS Simulator (`AgelloSim` + host `agello serve`):** Primary way to test iOS app features, UI presentation (Liquid Glass, Markdown/LaTeX, Think drawer, `ToolConfirmationCard`, deep links), and real model output quality inside the shipping iOS app and its 16 Swift tools (MapKit with spoofed GPS, EventKit Calendar/Reminders, Contacts, WebSearch, Files/PDF).
- **Physical iPhone (and Mac Metal CLI):** Source of truth for **all benchmarking, hardware test suites, and final feature verification on real silicon**. Our `CLiteRTLM.xcframework` has no simulator slice, and hardware failures (native heap corruption, Metal GPU precision, jetsam memory pressure, background GPU termination, ANE/audio hardware) only show up on real silicon.

## The suites

Test methods declared on 2026-11-23 (including Audit Waves 1–2 coverage). The dated iPhone and M6 runs and their results are in the [roadmap](ROADMAP.md#current-status).

| Target | Tests | Covers |
| --- | --- | --- |
| `AgelloTests` | 456 | Planner, context budgeting, schema migration and branching, regenerate / edit / versions, markdown, file reading and chunking, retrieval and citations, summaries, projects, memory, web parsers, SSRF/redirect guards and Billion-Laughs-safe page extraction (`WebTests`, recorded fixtures), workspace & structured CSV/JSON tools (`WorkspaceToolsTests`), language-agnostic parsing across 13 languages (`LanguageSupportTests`), deterministic agentic security & request-ID confirmation gate (`AgentSecurityTests`), post-tool Think budgets & stream tool-round cancellation (`ToolHostTests`, `StreamRegistryTests`), Core AI ANE embedder & SentencePiece (`CoreAIEmbedderTests`), dictation, voice-activity & neural turn detection, deep links, multimodal intents & `AppEntities` (`AppRouterTests`, `AppEntitiesTests`), Spotlight chats/projects/documents, isolated `ComposerBridge`, multi-step `BackgroundWorkPlan`, iOS 27 `MetricKit.MetricManager` & `MemoryProbe` peak-delta diagnostics (`DiagnosticsTests`), the share inbox, chat grouping and search, personalization, titles, downloads, and the whole app pipeline through a scripted engine |
| `AgelloDeviceTests` | 89 | The real models, in-process: download, load, text, chat isolation, stop and continue, tools, multi-word JSON enums under MTP, Think + tool continuity, thinking, image, audio, settings rebuilds, context limits, titles, memory, dictation accuracy, voice turns, exact digits past 2,048 and 4,096 tokens, benchmark; files (ANE EmbeddingGemma 2 indexing & FP32 parity, "summarize this 40-page PDF", cited follow-up, search chats by meaning, workspace CSV/page/unit tools, parallel read-only tool calls, natural-language multilingual tool intent); live web search, automatic search with on-device tools off; and the 6-vector adversarial prompt-injection evaluation suite (`security`, gated at 0% unauthorized tool execution) |
| `AgelloUITests` | 28 | Real taps: send, no jumping while a reply streams, Stop, Home button mid-reply, leaving and returning mid-reply, rapid settings changes, drawer and search, pin / rename / delete, projects, attached files, web search, dictation, voice mode, deep links, a long summary in the background, regenerate / edit / versions, Think, memory settings, markdown, keyboard clearance, composer controls that fit at every text size, Models, the screen an iPhone below the 12 GB floor opens on, an accessibility audit of the main screens; plus the opt-in screenshot tour and the bench driver |

The device scenarios include opt-in suites for work that's too slow or too specialized for every run: long Thinking answers, a **memory pressure simulation** (incompressible ballast shrinks usable memory to 6.0, 5.0, 4.0 and 3.5 GB, as when other apps hold memory; it once stood for 8 GB iPhones, which the app no longer runs on), **context calibration** (speed and memory at 4K–32K), and **LiteRT-LM probes** that test the runtime directly. The probes are how [#3913](ENGINEERING.md#long-context-digits-on-the-gpu-litert-lm-3913) was pinned to position 2,048 and its fix proven.

## Running them

The harness targets the `deviceId` in `.mobilebuildmcp/config.yaml`, a local, git-ignored file. Create it once and set your iPhone's UDID (from `xcrun devicectl list devices`), or pass `DEVICE_ID=<udid>` per run. It downloads E4B and EmbeddingGemma if they're missing. Keep the iPhone unlocked for the whole run.

```sh
cp .mobilebuildmcp/config.example.yaml .mobilebuildmcp/config.yaml

scripts/device-harness.sh gate        # fast iPhone hardware gate (~7.5-9 min: 1x build + shared device/ANE/memory + core UI)
scripts/device-harness.sh unit        # unit tests (~1-1.5 min, scripted engine)
scripts/device-harness.sh inference   # engine scenarios with the real model (~5.5-6.5 min)
scripts/device-harness.sh files       # files, ANE retrieval, and workspace/multilingual tools (~2.5-3.5 min warm ANE)
scripts/device-harness.sh web         # live web search (~7-8 min, needs internet)
scripts/device-harness.sh security    # 6-vector adversarial prompt-injection gate (0% breach, ~1-1.5 min)
scripts/device-harness.sh ui          # real-tap UI flows (~11-15 min; TEST_RUNNER_UITEST_REAL_ENGINE=1 ~16-18 min)
scripts/device-harness.sh all         # builds once, then unit, inference + files + web, and UI (~25-32 min)
scripts/device-harness.sh thinking | memory | calibrate | probes   # opt-in (probes ~3-5 min, fast regression only)
scripts/device-harness.sh soak | research-probes                   # opt-in 200-turn soak (~4-5 min) / historical sweeps (~60-75+ min)
scripts/device-harness.sh screenshots # opt-in tour with the real model (README images, ~4 min)
scripts/device-harness.sh bench       # opt-in: the bench through the app's screens, Release (~25-30 min, HARNESS.md)

ONLY=AgelloTests/AppStateTests scripts/device-harness.sh unit   # part of a suite
```

One run goes at a time on a machine: a second start exits with 3 while the first holds `build/.harness.lock`. An iPhone run starts with a preflight (the phone reachable and unlocked, iPhone Mirroring closed, 10 GB free on this Mac) and exits with 4 and the one thing to fix; [Results](#results) lists every exit code. The script keeps the Mac awake until it ends.

### On the iOS Simulator (`AgelloSim` + `agello serve`)

`AgelloSim` (`com.patricedery.agello.sim`, `SUPPORTED_PLATFORMS = iphonesimulator`, `SKIP_INSTALL = YES`) is the **primary workflow** for testing iOS app features, UI layout/rendering, and end-to-end model output quality from inside the app with the exact system prompt and all 16 shipping Swift tools. It runs the full iOS 27 SwiftUI app, SwiftData store, and native Simulator frameworks (MapKit, EventKit Calendar & Reminders, Contacts, PDFKit/Vision, WebSearch, `ToolConfirmationCard`) locally in the Simulator while proxying token-by-token SSE inference (`POST /v1/chat/completions`) and ANE embeddings (`POST /v1/embeddings`) over `127.0.0.1:8091` to host `agello serve` (`SIM_GPU=Apple_A19_Pro`, Gemma 4 E4B v2 64K + Core AI ANE EmbeddingGemma 2).

```sh
scripts/sim-launch.sh              # boot iPhone 18 Pro Simulator, start agello serve, build, grant perms & spoof GPS, launch AgelloSim
scripts/sim-launch.sh --no-build   # fast relaunch without rebuilding
scripts/sim-launch.sh --reset      # wipe simulator chats and settings for a fresh run
scripts/sim-launch.sh --mock       # launch against the scripted MockChatEngine (no server)
```

`SIM_DEVICE`, `SIM_PORT`, `SIM_LOCATION` (default `45.5017,-73.5673` for Maps testing), and `SIM_GPU` override defaults. For scripted UI driving, use `mobilebuildmcp` (`ui-automation` + `simulator` workflows) alongside `xcrun simctl openurl <udid> 'agello://ask?q=...'` to send exact UTF-8/LaTeX prompts cleanly. All benchmarking, hardware test suites, jetsam envelopes, App Store screenshots, and final feature verification remain on the physical iPhone.

### On a Mac

`PLATFORM=mac` runs the suites on the Mac itself: it runs the iPhone app ("Designed for iPad/iPhone") through the same Metal path and the iOS build of LiteRT-LM, which makes it a development bed when no iPhone is at hand. The UI suites, the bench and the memory simulation stay iPhone-only, and the Mac's speed and memory aren't an iPhone's: every change still gets an iPhone run before it ships.

```sh
PLATFORM=mac scripts/device-harness.sh unit
PLATFORM=mac scripts/device-harness.sh inference
```

The first run registers the Mac for development with the signing team. Results land in `build/mac-harness/`; app logs come from `log stream --predicate 'subsystem == "com.patricedery.agello"'` and crash reports from `~/Library/Logs/DiagnosticReports/`.

### The Mac command line

For work on the runtime, the app's engine also builds as a command line for macOS
([CLI.md](CLI.md)): `scripts/cli-test.sh unit` runs the unit tests that need no interface
natively (384, about 20 seconds), `scripts/cli-test.sh inference|files|web|security` runs the
real-model scenarios on the Mac's GPU (`SIM_GPU=Apple_A19_Pro`), and `agello bench` runs the bench's
cases with the runtime's telemetry, against any build of our LiteRT-LM. It's a development tool:
what ships is confirmed on the iPhone.

### Looking at the iPhone

The autonomous bench (`scripts/device-harness.sh bench`, [HARNESS.md](HARNESS.md)) and UI tests drive and verify the app on the phone, and `scripts/device-run.sh screenshot <name>` captures an unlocked phone's screen. iPhone Mirroring is for ad-hoc visual inspection only (dropped as a testing tool on 2026-11-10): it pauses after a few minutes idle, and opening it locks the phone and stops any harness run in progress. Keep iPhone Mirroring closed during harness runs.

### Tuning the model's behavior

Prompt and schema changes are judged against a table, not a single try. A device test runs the cases with their expected outcome, records each raw output (and any error, so one failure doesn't hide the rest) and fails on the wrong ones; `WebScenarioTests/test04_SearchDecisions` does this for Search's decision to search. Run alone on the iPhone, a round takes about three minutes:

```sh
ONLY=AgelloDeviceTests/WebScenarioTests/test04_SearchDecisions scripts/device-harness.sh web
jq '.scenarios.web04_searchDecisions' build/device-harness/harness-report.json
```

Then the bench judges the answers themselves through the app's own screens (`scripts/device-harness.sh bench`, [HARNESS.md](HARNESS.md)), and the change runs on the iPhone with the suites it touches.

## Results

Everything lands in `build/device-harness/`: a result bundle and the raw `xcodebuild` log for each suite (`<suite>.log`), per-scenario JSON metrics and UI screenshots under `attachments/`, and `harness-report.json`, an in-app report pulled from the device that survives crash relaunches within a run. Console output goes through Homebrew's [xcbeautify](https://github.com/cpisciotta/xcbeautify) when it's installed (`XCBEAUTIFY=off` for raw output). The script exits with `xcodebuild`'s code (65 when tests fail), 3 while another run holds the lock, 4 when an iPhone run's preflight refuses (the phone unreachable or locked, iPhone Mirroring open, or less than 10 GB free on this Mac), 2 for a usage error, and, for `bench`, 1 when the report finds a problem.

Outside test runs, `scripts/device-run.sh` relaunches the installed app and saves its logs (`logs [seconds]`), captures the iPhone's screen (`screenshot`), and lists or copies Agello's crash reports (`crashes [pull]`). The app logs under the subsystem `com.patricedery.agello`, categories `engine`, `generation` and `lifecycle`.

## Without a model

Launch the app with `--mock-engine` (**Product → Scheme → Edit Scheme → Run → Arguments**) to drive the whole interface with a scripted engine: streaming, reasoning, titles, regenerate and edit, without downloading anything. A prompt containing "show me markdown" returns a rich sample with code, a table and math. The unit tests use the same engine.
