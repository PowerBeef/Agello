---
name: agello-device-testing
description: Run and read Agello's tests on the physical iPhone, or on this Mac running the iPhone app, with scripts/device-harness.sh, and write new tests. Use before running any build or test, when a harness run fails, or when adding or changing tests.
---

# Agello device testing

Agello is tested on a physical iPhone, and on this Mac running the iPhone
app while the phone is away (see "On this Mac"). The simulator has no Metal
path for LiteRT-LM: never build, test, or take screenshots there.
MobileBuildMCP is configured with the `device` workflow only.

## Before a run

1. The iPhone is connected, paired, and **unlocked**, and stays unlocked for
   the whole run. A lock makes Xcode stall ("device is locked") and makes UI
   tests fail with "Timed out while enabling automation mode". For long
   suites, ask the user to set Auto-Lock to Never.
2. The device comes from `deviceId` in the git-ignored
   `.mobilebuildmcp/config.yaml` (copy `config.example.yaml`), or
   `DEVICE_ID=<udid>`. `xcrun devicectl list devices` shows whether it's
   connected.
3. Don't edit files in the target folders (`Agello*/`) while a run is
   building: stage changes elsewhere and apply them after the run. Files
   outside them (docs, `.claude/`, `scripts/`) are safe to edit.

## Running suites

```sh
scripts/device-harness.sh unit        # ~3 min, scripted engine
scripts/device-harness.sh inference   # real E4B engine scenarios
scripts/device-harness.sh files       # EmbeddingGemma, 40-page PDF, citations
scripts/device-harness.sh web         # live web search (needs internet)
scripts/device-harness.sh ui          # real-tap flows; needs E4B downloaded
scripts/device-harness.sh all         # unit, then inference+files+web, then ui
# Opt-in:
scripts/device-harness.sh thinking | memory | calibrate | probes
scripts/device-harness.sh screenshots # UI tour, one screenshot per screen
```

Start suites with the Bash tool's `run_in_background: true` and send the
console to a file (`> "$scratchpad/inference.console" 2>&1`). You're notified
when the command ends, so don't poll. Chain suites in one command with `;`
when they should run back to back.

Pick the narrowest suite that covers the change: `unit` for pure logic
(planner, budgets, schema, markdown, parsers), `inference` or `files` for
engine and retrieval changes, `ui` for views and flows.

Run part of a suite with `ONLY` (comma- or space-separated test identifiers
inside that suite; not with `all`). Use the suite the test belongs to, so
opt-in suites get their environment:

```sh
ONLY=AgelloTests/AppStateTests scripts/device-harness.sh unit
ONLY=AgelloDeviceTests/InferenceScenarioTests/test05_ToolCall scripts/device-harness.sh inference
```

Other extra arguments go to `xcodebuild` as is.

## On this Mac

`PLATFORM=mac` runs the suites on this Mac, which runs the iPhone app
("Designed for iPad/iPhone") through the same Metal path and the iOS slice of
`CLiteRTLM`. It's the development bed while the iPhone is away. Its speed and
memory aren't the iPhone's, and a change still needs an iPhone run before it
ships.

```sh
PLATFORM=mac scripts/device-harness.sh unit
PLATFORM=mac ONLY=AgelloDeviceTests/InferenceScenarioTests/test05_ToolCall scripts/device-harness.sh inference
```

- `ui`, `screenshots` and `memory` stay iPhone-only: the script refuses them,
  and `all` skips `ui`. The Mac has no jetsam limit to simulate.
- The destination is the Mac's provisioning UDID (`system_profiler
  SPHardwareDataType`). The first run registers the Mac for development.
- Results land in `build/mac-harness/`. Device suites print
  `HARNESS_REPORT_PATH=` in their log, and the script copies
  `harness-report.json` from there.
- The app's data lives in its sandbox container,
  `~/Library/Containers/<uuid>/Data/`. Find it with
  `for d in ~/Library/Containers/*/; do [ "$(plutil -extract MCMMetadataIdentifier raw "$d.com.apple.containermanagerd.metadata.plist" 2>/dev/null)" = com.patricedery.agello ] && echo "$d"; done`.
  - Skip downloads: clone the models from `~/Models/agello/` into
    `Data/Library/Application Support/Models/` with `cp -c`.
  - Lab models for the probes go in `Data/Documents/lab/`.
  - Settings: `defaults read <container>/Data/Library/Preferences/com.patricedery.agello`.
- Logs: `log stream --level debug --predicate 'subsystem == "com.patricedery.agello"'`.
  Crash reports: `~/Library/Logs/DiagnosticReports/Agello-*.ips`.
- The script keeps the Mac awake (`caffeinate`) until it exits.

## Outside test runs

`scripts/device-run.sh` looks at the installed app directly (results in
`build/device-run/`):

```sh
scripts/device-run.sh logs 20                 # relaunch, save its logs for 20 s
scripts/device-run.sh logs 20 --mock-engine   # with launch arguments
scripts/device-run.sh screenshot settings     # the iPhone's screen as a PNG
scripts/device-run.sh crashes                 # Agello crash/resource reports
scripts/device-run.sh crashes pull            # copy them to build/device-run/crashes/
```

- Symbolicate pulled reports with `/axiom:analyze-crash <file>` (Axiom's
  `xcsym`).
- `logs` relaunches the app, which brings it to the front on the phone.
- Screenshots show whatever is on screen, so only take them when the user
  expects it.
- Axiom's `xclog` console capture is simulator-only, and `log collect` needs
  root for a physical device: use `logs` instead.

## Reading results

Everything lands in `build/device-harness/` (`build/mac-harness/` on the Mac):

| File | Use |
| --- | --- |
| Console | Formatted by Homebrew's xcbeautify (`XCBEAUTIFY=off` for raw) |
| `<suite>.log` | Full raw `xcodebuild` output: grep it for `error:` |
| `<suite>.xcresult` | `xcrun xcresulttool get test-results summary --path <bundle>` gives counts and `testFailures` as JSON |
| `attachments/<suite>/` | Per-scenario JSON metrics (device suites) and screenshots (UI tests) |
| `harness-report.json` | In-app report pulled from the device: every recorded scenario of the last run, and the device (hardware, `isiOSAppOnMac`, GPU family, Metal working set) |

The script's exit code is `xcodebuild`'s (65 = test failures).

App logs use subsystem `com.patricedery.agello`, categories `engine`,
`generation`, and `lifecycle`. CoreData "database is corrupted" lines during
`unit` come from tests that feed a corrupt store on purpose.

## Writing tests

- **Unit tests** (`AgelloTests`, XCTest): build `AppState(useMockEngine:
  true)` with an in-memory `ModelContainer(for: ChatStore.schema,
  configurations: ModelConfiguration(isStoredInMemoryOnly: true))`, set
  `appState.modelContext`, and script the engine through
  `appState.engine as! MockChatEngine` (`setScript`, `setHelperResponse`,
  `setFitResult`, …). Fixtures live in `AgelloTests/Fixtures/`.
- **Shared state.** Tests run inside the app on the phone and share its
  UserDefaults and Documents. A test that reads settings clears those keys
  before creating `AppState` and restores them in `tearDown` (see
  `AppStateTests`). In device tests, add new settings keys to
  `DeviceHarness.defaultsKeys`.
- **Device scenarios** subclass `DeviceTestCase`
  (`AgelloDeviceTests/DeviceHarness.swift`), call `requireLoadedModel()`, and
  call `harness.record(...)` before asserting, so the metrics survive a
  failure. Assert `exchange.accepted` (with `appState.generationError` as the
  message) so a rejected send can't pass for a wrong answer.
- **Order.** `testNN_Name` methods run in name order. Insert with letter
  suffixes (`test06b_…`), and keep `test90_Benchmark` last.
- **Long prompts.** The app estimates 3 bytes per token, so about 4K tokens
  of English is the most chat's 8K window accepts. Longer prompts need
  `appState.options.maxNumTokensOverride` plus
  `await appState.applyCurrentOptions()`; `tearDown` restores the options.
- **Opt-in suites.** Opt-in classes throw `XCTSkip` in `setUp` unless their
  `HARNESS_*` variable is set: the script exports `TEST_RUNNER_HARNESS_*`, and
  xcodebuild strips the prefix. A new device-test class runs in no suite until
  `scripts/device-harness.sh` maps one to it.
- **Target membership.** New files in a test folder join its target
  automatically; non-Swift files become bundle resources unless excluded in
  `project.pbxproj` (as each `.swiftlint.yml` is).

## UI tests and the design

- Reply stats (`message.stats`) are hidden unless Settings → Advanced →
  Show performance details is on.
- The sampler presets ("Precise"…) live in Settings → Advanced
  (`settings.advanced`).
- `--uitest-reset` wipes chats, projects, files, memories and all settings
  (models are kept): the dev install's own data on the phone goes too.
- Screenshots for the README and App Store come from
  `scripts/device-harness.sh screenshots` (`attachments/screenshots/`,
  names `tour-NN-…` in its `manifest.json`), never the simulator.

## Known issues

- "Failed to create a bundle instance … AgelloDeviceTests.xctest": run
  `xcrun devicectl device uninstall app --device <udid> com.patricedery.agello`
  and retry. This also deletes the downloaded models (about 3.8 GB to
  download again).
- XCTest can't answer system permission prompts on device, so UI tests use
  launch arguments instead.

## Launch arguments and environment

| Name | Effect |
| --- | --- |
| `--mock-engine` (or env `AGELLO_MOCK_ENGINE`) | Scripted engine: the whole UI without a model |
| `--uitest-reset` | Fresh chats and default settings for a UI test; projects, memories and web-search settings persist |
| `--uitest-fake-mic` | Fake microphone input (no permission prompt) |
| `--uitest-sample-file`, `--uitest-sample-report` | Attach sample documents generated in code (`ChatView`) |
| `TEST_RUNNER_HARNESS_THINKING`, `_MEMORY`, `_CALIBRATE`, `_PROBES` | Enable the opt-in device suites (the script sets them) |

## After a change

Run the relevant suite, then commit each verified chunk. Push only when the
user asks.
