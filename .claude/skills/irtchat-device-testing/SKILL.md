---
name: irtchat-device-testing
description: Run and read iRTChat's tests on the physical iPhone with scripts/device-harness.sh, and write new tests. Use before running any build or test, when a harness run fails, or when adding or changing tests.
---

# iRTChat device testing

iRTChat is tested on a physical iPhone only. The simulator has no Metal path
for LiteRT-LM: never build, test, or take screenshots there. MobileBuildMCP is
configured with the `device` workflow only.

## Before a run

1. The iPhone is connected, paired, and **unlocked**, and stays unlocked for
   the whole run. A lock makes Xcode stall ("device is locked") and makes UI
   tests fail with "Timed out while enabling automation mode". For long
   suites, ask the user to set Auto-Lock to Never.
2. The device comes from `deviceId` in the git-ignored
   `.mobilebuildmcp/config.yaml` (copy `config.example.yaml`), or
   `DEVICE_ID=<udid>`. `xcrun devicectl list devices` shows whether it's
   connected.
3. Don't edit files in the target folders (`iRTChat*/`) while a run is
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
ONLY=iRTChatTests/AppStateTests scripts/device-harness.sh unit
ONLY=iRTChatDeviceTests/InferenceScenarioTests/test05_ToolCall scripts/device-harness.sh inference
```

Other extra arguments go to `xcodebuild` as is.

## Outside test runs

`scripts/device-run.sh` looks at the installed app directly (results in
`build/device-run/`):

```sh
scripts/device-run.sh logs 20                 # relaunch, save its logs for 20 s
scripts/device-run.sh logs 20 --mock-engine   # with launch arguments
scripts/device-run.sh screenshot settings     # the iPhone's screen as a PNG
scripts/device-run.sh crashes                 # iRTChat crash/resource reports
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

Everything lands in `build/device-harness/`:

| File | Use |
| --- | --- |
| Console | Formatted by Homebrew's xcbeautify (`XCBEAUTIFY=off` for raw) |
| `<suite>.log` | Full raw `xcodebuild` output: grep it for `error:` |
| `<suite>.xcresult` | `xcrun xcresulttool get test-results summary --path <bundle>` gives counts and `testFailures` as JSON |
| `attachments/<suite>/` | Per-scenario JSON metrics (device suites) and screenshots (UI tests) |
| `harness-report.json` | In-app report pulled from the device: every recorded scenario of the last run |

The script's exit code is `xcodebuild`'s (65 = test failures).

App logs use subsystem `com.patricedery.irtchat`, categories `engine`,
`generation`, and `lifecycle`. CoreData "database is corrupted" lines during
`unit` come from tests that feed a corrupt store on purpose.

## Writing tests

- **Unit tests** (`iRTChatTests`, XCTest): build `AppState(useMockEngine:
  true)` with an in-memory `ModelContainer(for: ChatStore.schema,
  configurations: ModelConfiguration(isStoredInMemoryOnly: true))`, set
  `appState.modelContext`, and script the engine through
  `appState.engine as! MockChatEngine` (`setScript`, `setHelperResponse`,
  `setFitResult`, …). Fixtures live in `iRTChatTests/Fixtures/`.
- **Shared state.** Tests run inside the app on the phone and share its
  UserDefaults and Documents. A test that reads settings clears those keys
  before creating `AppState` and restores them in `tearDown` (see
  `AppStateTests`). In device tests, add new settings keys to
  `DeviceHarness.defaultsKeys`.
- **Device scenarios** subclass `DeviceTestCase`
  (`iRTChatDeviceTests/DeviceHarness.swift`), call `requireLoadedModel()`, and
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

## Known issues

- "Failed to create a bundle instance … iRTChatDeviceTests.xctest": run
  `xcrun devicectl device uninstall app --device <udid> com.patricedery.irtchat`
  and retry. This also deletes the downloaded models (about 3.8 GB to
  download again).
- XCTest can't answer system permission prompts on device, so UI tests use
  launch arguments instead.

## Launch arguments and environment

| Name | Effect |
| --- | --- |
| `--mock-engine` (or env `IRT_MOCK_ENGINE`) | Scripted engine: the whole UI without a model |
| `--uitest-reset` | Fresh chats and default settings for a UI test; projects, memories and web-search settings persist |
| `--uitest-fake-mic` | Fake microphone input (no permission prompt) |
| `--uitest-sample-file`, `--uitest-sample-report` | Attach sample documents generated in code (`ChatView`) |
| `TEST_RUNNER_HARNESS_THINKING`, `_MEMORY`, `_CALIBRATE`, `_PROBES` | Enable the opt-in device suites (the script sets them) |

## After a change

Run the relevant suite, then commit each verified chunk. Push only when the
user asks.
