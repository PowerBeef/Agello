---
name: agello-device-testing
description: Test Agello's iOS UI, features, and in-app output quality in the iOS Simulator via AgelloSim (scripts/sim-launch.sh + mobilebuildmcp), and run hardware tests and benchmarks on the physical iPhone or Mac with scripts/device-harness.sh and scripts/cli-test.sh. Use before running any build or test, when a run fails, or when adding or changing tests.
---

# Agello testing (Simulator, Mac workbench & physical iPhone)

- **`AgelloSim` (primary UI, iOS-feature & in-app quality workbench):** `scripts/sim-launch.sh` + `mobilebuildmcp` (`ui-automation` + `simulator`) test the real iOS 27 SwiftUI UI, sandboxed iOS features (Maps w/ `simctl location`, EventKit, Contacts, Photos, Shortcuts/Recipes, WebSearch, Files/PDF), and real Gemma 4 E4B replies across all shipping Swift tools ([docs/ARCHITECTURE.md](../../../docs/ARCHITECTURE.md)). Streams real Metal 4 E4B (`SIM_GPU=Apple_A19_Pro`) + ANE EmbeddingGemma 2 from host `agello serve` (`127.0.0.1:8091`).
- **Physical iPhone (hardware truth & benchmarking):** All benchmarks (`phone-bench.sh`, `bench`), hardware suites (`gate`, `memory`, `soak`, Metal 4, on-device ANE, `BGContinuedProcessingTask`, `AVFAudio`/`SpeechAnalyzer`, signed `WeatherKit`, `AlarmKit` Live Activities, real Shortcuts round-trip), App Store screenshots, and final silicon checks stay on physical iPhone (`CLiteRTLM.xcframework` has no simulator slice). `.agents/hooks.json` blocks `axiom_xclog_*` (incl. `mcp_*`), `asc-shots-pipeline`, and `asc-notarization`.

SSOT references: suite catalog, exact test totals & measured durations → [docs/TESTING.md](../../../docs/TESTING.md); `bench` & `phone-bench.sh` internals → [docs/HARNESS.md](../../../docs/HARNESS.md); `agello` CLI & `agello serve` → [docs/CLI.md](../../../docs/CLI.md).

## `AgelloSim` Simulator playbook

```sh
scripts/sim-launch.sh              # boot Simulator, start agello serve, build AgelloSim, grant perms & GPS, launch
scripts/sim-launch.sh --no-build   # fast relaunch without rebuilding
scripts/sim-launch.sh --no-serve   # build & launch without starting host agello serve
scripts/sim-launch.sh --reset      # wipe simulator chats/settings for a clean session
scripts/sim-launch.sh --mock       # launch with --mock-engine (no host server needed)
```

- **Overrides (`BypassSandbox: true`):** `SIM_DEVICE` (`"iPhone 18 Pro"`), `SIM_PORT` (`8091`), `SIM_LOCATION` (`45.5017,-73.5673`), `SIM_GPU` (`Apple_A19_Pro`).
- **Driving with `mobilebuildmcp`:**
  1. `manage-workflows({ workflowNames: ["ui-automation"], enable: true })` (once per session).
  2. `session_set_defaults({ projectPath: ".../Agello.xcodeproj", scheme: "AgelloSim", simulatorId: "<udid>", simulatorName: "iPhone 18 Pro", bundleId: "com.patricedery.agello.sim", derivedDataPath: ".../build/sim/DerivedData" })`.
  3. Drive via `snapshot_ui`, `screenshot` (`returnFormat: "path"` + `read_file`), `tap`, `batch`, `type_text`, and `wait_for_ui` (e.g., `composer.voice` or `tool.confirm.approve`). Issue `tap`/`batch` promptly before `snapshot_ui` refs expire.
- **Exact prompts (no autocorrect):** Use the deep link for UTF-8, LaTeX, code, or multilingual prompts, then refresh `snapshot_ui` and tap `chat.send`:
  ```sh
  xcrun simctl openurl <udid> 'agello://ask?q=Find%20three%20coffee%20shops%20near%20me'
  ```
- **Logs & cleanup:** Host server logs at `build/sim/serve.log` (`build/sim/serve.pid`); Simulator app logs via `xcrun simctl spawn <udid> log stream --level debug --predicate 'subsystem == "com.patricedery.agello"'`. Stop when done: `kill "$(cat build/sim/serve.pid)" && rm -f build/sim/serve.pid; xcrun simctl terminate <udid> com.patricedery.agello.sim`.

## Before a physical iPhone run

0. **Ask the user first.** Iterate in `AgelloSim` and on Mac (`cli-test.sh`, `PLATFORM=mac`) before requesting physical iPhone runs.
1. **Connected, unlocked, Mirroring closed.** Preflight checks reachability, unlock, Mirroring closed, and `>= 10 GB` free on Mac — exiting `4` with the fix. On exit `4`, ask the user; never lock the phone, toggle Mirroring, or pass `PREFLIGHT=off`. Device suites set `isIdleTimerDisabled`; `unit`, `ui`, `screenshots`, `bench`, and `phone-bench.sh` need Auto-Lock set to Never. Opening Mirroring mid-run aborts active suites.
2. **UI tests & screenshots:** Enable Settings → Developer → Enable UI Automation and ask the user for Focus (Do Not Disturb) so banners don't obscure UI/screenshots.
3. **Device ID:** Set `deviceId` in git-ignored `.mobilebuildmcp/config.yaml` or `DEVICE_ID=<udid>` (`xcrun devicectl list devices`).
4. **No target edits while building:** Never edit `Agello*/` or `Vendor/LiteRT-LM/` until the last `xcodebuild` starts testing (`guard-target-edits.sh` denies edits; applies to shell too). Stage edits in `<Artifact Directory Path>/scratch/` or work in `docs/`, `.agents/`, `scripts/`.

## Running suites (`scripts/device-harness.sh`)

```sh
scripts/device-harness.sh gate             # recommended iPhone check: 1x build + shared-engine device/ANE/memory + core UI
scripts/device-harness.sh unit             # AgelloTests (MockChatEngine)
scripts/device-harness.sh inference        # real E4B engine scenarios
scripts/device-harness.sh files            # ANE EmbeddingGemma, PDF, citations, workspace & multilingual tools
scripts/device-harness.sh web              # live web search decisions & grounded answers (needs internet)
scripts/device-harness.sh security         # adversarial prompt-injection gate (0% breach)
scripts/device-harness.sh ui               # real-GPU E2E + --mock-engine UI + Floor + A11y
scripts/device-harness.sh all              # 1x build -> unit, inference+files+web, ui
# Opt-in / milestone / pre-release:
scripts/device-harness.sh thinking | memory | probes | soak | research-probes | calibrate | screenshots | bench
```

- **Backgrounding & lock:** Launch with `run_command` (`WaitMsBeforeAsync: 500`, `BypassSandbox: true`), stop calling tools, and wait for completion — never poll (`manage_task` to inspect/cancel). Invoke scripts directly for prefix-matched approvals. `build/.harness.lock` serializes runs across worktrees (exit `3`; never delete a live lock). Scripts run `caffeinate`; watch live via `tail -n +1 -f build/device-harness/<suite>.log | /opt/homebrew/bin/xcbeautify`.
- **Targeting (`ONLY`):** Comma- or space-separated `Target/Class[/method]` inside the suite (**not with `gate` or `all`**):
  ```sh
  ONLY=AgelloTests/AppStateTests scripts/device-harness.sh unit
  ONLY=AgelloDeviceTests/InferenceScenarioTests/test05_ToolCall scripts/device-harness.sh inference
  ```
- **Chained runs:** Each suite builds separately — keep targets untouched until the last suite starts testing.

## Autonomous `bench` & `phone-bench.sh`

Full details in [docs/HARNESS.md](../../../docs/HARNESS.md):

- **`scripts/device-harness.sh bench`:** Runs `AgelloUITests/BenchCases.swift` (incl. `mockup-os-search`, `typo-fix`, `comment-module`, multi-turn coding, Search & file follow-ups) in the **Bench** config (Release + `BENCH`) with `--trace`, writing `build/device-harness/bench/report.md` against `scripts/bench/baseline.json`. Flags: `BENCH_ONLY`, `BENCH_TRACE=off`, `BENCH_RESUME=1`, `BENCH_COOL=1`, `BENCH_ACCEPT=1` (user approval only). Use `scripts/bench-direct.sh CASE` for driverless speed (XCUITest costs ~8% decode speed).
- **`scripts/phone-bench.sh`:** Interleaved driverless A/B runtime comparison on iPhone (`release next`, `ROUNDS=5`, `release again=release`, `--read <run>` offline). Needs Auto-Lock Never, Focus, Mirroring closed, plugged in, clean committed `Vendor/LiteRT-LM`. Uses `P6.2` alternating heavy/light case order + hysteresis rests (`REST=on` when `COOL=on`; `CASE_REST=15 s`, `HEAVY_REST=45 s`, `WARM_REST=90 s`) because `thermalState` can stay `nominal` while the die warms. Read `records.txt`, `load.txt`, `compare.txt`, `replies/` in `build/phone/runs/<time>/`. Never edit `phone-bench.sh` while running.
- **Don't kill mid-test:** A killed device test leaves harness options in app settings until the next device test restores `harnessSettingsSnapshot`.

## Mac workbench (`PLATFORM=mac` & `agello` CLI)

- **`PLATFORM=mac`:** Runs the signed `arm64-iphoneos` binary on M6 Metal into `build/mac-harness/` (`ui`, `screenshots`, `memory`, `bench` stay iPhone-only; `all` skips `ui`):
  ```sh
  PLATFORM=mac scripts/device-harness.sh unit
  PLATFORM=mac scripts/device-harness.sh gate
  PLATFORM=mac ONLY=AgelloDeviceTests/InferenceScenarioTests/test05_ToolCall scripts/device-harness.sh inference
  ```
  Seed models via `cp -c` from `~/Models/agello/` into the app container's `Data/Library/Application Support/Models/`. Inspect outside a run with `open -b com.patricedery.agello [--args --mock-engine]` + `cua-driver` MCP; quit via `osascript -e 'tell application id "com.patricedery.agello" to quit'` before the next run.
- **Native `agello` CLI ([docs/CLI.md](../../../docs/CLI.md)):** Defaults to `SIM_GPU=Apple_A19_Pro` (8 GiB simulated limit, `MallocLargeCache=0`; `SIM_GPU=native` for M6 kernels), reads `~/Models/agello` read-only, isolates test home in `build/cli/test-home`:
  ```sh
  swift build -c release --scratch-path build/cli/release
  scripts/cli-check.sh                                                # verify CLI compiles after engine edits
  scripts/cli-test.sh unit [Class[/method]]
  scripts/cli-test.sh inference InferenceScenarioTests/test05_ToolCall
  scripts/cli-test.sh security
  MTL_DEBUG_LAYER=1 scripts/cli-test.sh inference InferenceScenarioTests/test02_TextReply
  scripts/cli-bench.sh release next -- --only explain                 # guarded by scripts/mac-ready.sh
  scripts/cli-report.py | cli-timeline.py | cli-replies.py | cli-load.py   # sandboxed Python
  ```
  `swift build`, `cli-check.sh`, `cli-test.sh`, and `cli-bench.sh` need `BypassSandbox: true`. Stay idle during `cli-bench.sh` (exit `4` if busy; `QUIET=off` for reply-only inspection). Pair with `../LiteRT-LM/agello/build-xcframework.sh --mac-only`.

## Outside test runs & looking at the iPhone

```sh
scripts/device-run.sh logs 20 [--mock-engine]   # relaunch installed app, capture 20 s of logs (BypassSandbox: true)
scripts/device-run.sh screenshot <name>         # unlocked iPhone PNG (only when user expects it)
scripts/device-run.sh crashes [pull]            # list/pull crashes -> build/device-run/crashes/
```

Symbolicate crashes via `axiom` MCP (`axiom_xcsym_crash`/`triage`/`axiom_get_agent`; never `axiom_xclog_*`). iPhone Mirroring (`com.apple.ScreenContinuity`) is the user's tool only — inspect via `cua-driver` only if already open and explicitly requested.

## Tuning a prompt or model decision (Mac-first)

1. Put cases in a table test catching per-case errors and recording raw output (model: `WebScenarioTests/test04_SearchDecisions`).
2. **Iterate on Mac first** via `scripts/cli-test.sh <suite> <Class>/<test>` and verify in-app replies in `AgelloSim` (`scripts/sim-launch.sh`), checking `recordedAt` in `harness-report.json` so pre-record throws don't show stale data.
3. Ask the user, then confirm on physical iPhone (`ONLY=... scripts/device-harness.sh <suite>` and `bench`).
4. E4B rules: classify into short enum labels instead of yes/no self-assessments; enforce required fields in JSON schema (`anyOf`); include multi-turn follow-ups with real truncated app replies; keep multi-word enums short to save helper tokens (`test16_MultiWordJsonEnumWithMTP`).

## Results, test host, writing tests & UI rules

- **Test host & outputs:** Unit/device tests run under blank `AppBootstrap.hostsTests` (`#if DEBUG`, no duplicate UI engine). Results land in `build/device-harness/` (`build/mac-harness/` on Mac): `<suite>.log`, `<suite>.xcresult` (`xcrun xcresulttool get test-results summary`), `attachments/<suite>/`, `harness-report.json` (read `telemetry` with `python3 ../LiteRT-LM/tools/agello-bench/telemetry.py <report>`). **Exit codes:** `65` test failures, `3` lock held, `4` preflight/busy Mac, `2` usage, `1` bench report issue. Clean `OUT=build/<name>` scratch with `scripts/storage.sh clean`. Logs use subsystem `com.patricedery.agello` (`engine`, `generation`, `lifecycle`).
- **Unit tests (`AgelloTests`):** Use `AppState(useMockEngine: true)`, in-memory `ModelContainer(for: ChatStore.schema, ...)`, and `appState.engine as! MockChatEngine`. Fixtures in `AgelloTests/Fixtures/`.
- **Isolation & device scenarios:** Tests share UserDefaults & Documents — clear/restore touched keys in `setUp`/`tearDown` and add new settings keys to `DeviceHarness.defaultsKeys`. Subclass `DeviceTestCase`, call `requireLoadedModel()`, call `harness.record(...)` before asserting, assert `exchange.accepted`. Order methods `testNN_Name` (`test90_Benchmark` last). Long prompts (~56–60K at 64K; digits = 1 tok each) use `maxNumTokensOverride` + `applyCurrentOptions()` and restore in `tearDown`. Opt-in classes `XCTSkip` without `TEST_RUNNER_HARNESS_*`. Exclude non-Swift files in `project.pbxproj`.
- **UI expectations:** Reply stats (`message.stats`) require 5 taps on `settings.version` → `settings.showStats`. No Advanced screen. Settings tool controls: On-device tools (`settings.tools`), opt-in Personal tools (`PersonalToolsSettings`: Calendar, Reminders, Contacts, Apple Maps, Weather, Alarms & Timers, Photos OCR), and Automations & Shortcuts (`AutomationRegistry`). `--uitest-reset` wipes user data/settings (keeps models). Release/README screenshots come only from physical iPhone `scripts/device-harness.sh screenshots`.

## Known issues

- **`Failed to create a bundle instance … AgelloDeviceTests.xctest`:** `xcrun devicectl device uninstall app --device <udid> com.patricedery.agello` and retry (deletes ~3.8 GB models).
- **System permission prompts:** XCTest cannot answer them on device; use launch arguments.
- **`PLATFORM=mac` `"Test crashed with signal kill"` / `"Agello est endommagé"`:** Corrupted `Debug-iphoneos/Agello.app` signature in DerivedData; delete that `Agello.app` and re-run.
- **`ThinkingScenarioTests/test02_ReasoningStaysOutOfCache`:** Must pass on both Mac and iPhone; any failure is a KV-stripping regression.

## Launch arguments and environment

| Name | Effect |
| --- | --- |
| `--mock-engine` / `AGELLO_MOCK_ENGINE` | Scripted `MockChatEngine`: full UI without a model (`#if DEBUG \|\| BENCH`) |
| `--remote-engine <url>` / `AGELLO_REMOTE_ENGINE_URL` | Loopback `agello serve` URL for `AgelloSim` (default `http://127.0.0.1:8091/v1`) |
| `--uitest-reset` | Wipe chats, projects, files, memories, settings before UI test (keeps models) |
| `--uitest-fake-mic` | Fake microphone input (no permission prompt) |
| `--uitest-sample-file`, `--uitest-sample-report` | Attach code-generated sample documents (`ChatView`) |
| `--uitest-window N` | Hold context window at `N` tokens (`InferenceOptions.launch`, e.g., `8192`) |
| `--trace` | Write per-reply `ReplyTrace` JSON under `Documents/traces/` (`bench`) |
| `-memoryEnabled NO` | Disable memories for this launch without changing saved setting |
| `AGELLO_BENCH_DRAFT`, `AGELLO_BENCH_AUTOSEND=1` | Open new chat with draft and autosend once loaded (`bench`, `bench-direct.sh`) |
| `AGELLO_BENCH_THINK` (`1`/`0`), `AGELLO_BENCH_COOL=1` | Set Think pill; wait up to 10 min for `nominal` thermal state before autosend |
| `AGELLO_SIMULATE_MEMORY_GB` | Override physical memory check (`DeviceFloorUITests`) |
| `AGELLO_SIMULATE_APPLE_GPU` | Emulate another Apple GPU's kernel paths (e.g., `Apple_A19_Pro`; separate caches) |
| `AGELLO_TELEMETRY=<0-4>` | Engine telemetry level (default `2`; `4` times every GPU kernel; `TEST_RUNNER_AGELLO_TELEMETRY`) |
| `AGELLO_JSON_MTP` (`1`/`0`) | Toggle MTP speculation for JSON-constrained helpers (default `1` / ON) |
| `AGELLO_EXPORT_WINDOW` | Override model export context window for runtime/lab experiments |
| `AGELLO_MODELS_DIR`, `AGELLO_ENGINE_CACHE_DIR`, `AGELLO_TRACE_DIR` | Redirect model, engine cache, and trace paths (Mac CLI / `agello serve`) |
| `TEST_RUNNER_AGELLO_VERIFY_DIRECT_COPIES=1` | Verify every direct Metal host copy against ML Drift (flags diffs as anomalies) |
| `TEST_RUNNER_UITEST_REAL_ENGINE=1` | Run all `ChatFlowUITests` on real GPU instead of `--mock-engine` split |
| `TEST_RUNNER_HARNESS_THINKING`, `_MEMORY`, `_CALIBRATE`, `_PROBES`, `_RESEARCH_PROBES`, `_SCREENSHOTS`, `_BENCH` | Enable opt-in suites (`HARNESS_SYSTEM_PROMPT` overrides probe system prompt) |
| `BENCH_ONLY`, `BENCH_TRACE`, `BENCH_COOL`, `BENCH_RESUME`, `BENCH_ACCEPT` | Filter cases, toggle tracing, cool wait, resume, or accept `baseline.json` (`bench`) |
| `COOL`, `REST`, `CASE_REST`, `HEAVY_REST`, `WARM_REST` | Cooldown & inter-case hysteresis rests (`15 / 45 / 90 s`) in `phone-bench.sh` |

## After a change

Run the narrowest covering suite, verify replies/screenshots, then commit on `main`. Push only when asked.
