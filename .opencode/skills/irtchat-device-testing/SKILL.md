---
name: iRTChat device testing
description: Run and read iRTChat's tests on the physical iPhone with scripts/device-harness.sh. Use before running any build or test, when a harness run fails, or when adding test scenarios.
---

# iRTChat device testing

iRTChat is tested on a physical iPhone only. The simulator has no Metal path
for LiteRT-LM: never build, test, or take screenshots there (MobileBuildMCP is
configured with the `device` workflow only).

## Before a run

1. The iPhone is connected, paired, and **unlocked**, and stays unlocked for
   the whole run. A lock makes Xcode stall ("device is locked") and makes UI
   tests fail with "Timed out while enabling automation mode". For long
   suites, ask the user to set Auto-Lock to Never.
2. The device comes from `deviceId` in the git-ignored
   `.mobilebuildmcp/config.yaml` (copy `config.example.yaml`), or
   `DEVICE_ID=<udid>`.
3. Don't edit source files while a run is building: stage changes elsewhere
   and apply them after the run.

## Suites

```sh
scripts/device-harness.sh unit        # ~3 min, 204 tests, scripted engine
scripts/device-harness.sh inference   # real E4B engine scenarios
scripts/device-harness.sh files       # EmbeddingGemma, 40-page PDF, citations
scripts/device-harness.sh web         # live web search (needs internet)
scripts/device-harness.sh ui          # real-tap flows; needs E4B downloaded
scripts/device-harness.sh all         # unit, then inference+files+web, then ui
# Opt-in:
scripts/device-harness.sh thinking | memory | calibrate | probes
```

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
scripts/device-run.sh crashes pull            # copy them, then symbolicate
                                              # with Axiom's xcsym tools
```

`logs` relaunches the app, which brings it to the front on the phone.
Screenshots show whatever is on screen, so only take them when the user expects
it. `log collect` and Axiom's `xclog_show` need root for a physical device;
use `logs` instead.

## Reading results

Everything lands in `build/device-harness/`:

| File | Use |
| --- | --- |
| Console | Formatted by Homebrew's xcbeautify (`XCBEAUTIFY=off` for raw) |
| `<suite>.log` | Full raw `xcodebuild` output: grep it for `error:` |
| `<suite>.xcresult` | `xcrun xcresulttool get test-results summary --path <bundle>` gives counts and `testFailures` as JSON |
| `attachments/<suite>/` | Per-scenario JSON metrics and screenshots |
| `harness-report.json` | In-app report pulled from the device |

The script's exit code is `xcodebuild`'s (65 = test failures).

App logs use subsystem `com.patricedery.irtchat`, categories `engine`,
`generation`, and `lifecycle`. CoreData "database is corrupted" lines during
`unit` come from tests that feed a corrupt store on purpose.

## Known issues

- Unit tests share the app's settings (UserDefaults) on the phone. A test that
  depends on default settings must clear the keys it reads in `setUp` and
  restore them in `tearDown`, as `AppStateTests` does.
- "Failed to create a bundle instance … iRTChatDeviceTests.xctest": run
  `xcrun devicectl device uninstall app --device <udid> com.patricedery.irtchat`
  and retry. This also deletes the downloaded models (about 3.8 GB to
  download again).
- XCTest can't answer system permission prompts on device, so UI tests use
  launch arguments instead.

## Launch arguments and environment

| Name | Effect |
| --- | --- |
| `--mock-engine` | Scripted engine: the whole UI without a model |
| `--uitest-reset` | Fresh state for a UI test |
| `--uitest-fake-mic` | Fake microphone input (no permission prompt) |
| `--uitest-sample-file`, `--uitest-sample-report` | Attach bundled sample documents |
| `TEST_RUNNER_HARNESS_THINKING`, `_MEMORY`, `_CALIBRATE`, `_PROBES` | Enable the opt-in device suites (the script sets them) |

## After a change

Run the relevant suite, then commit each verified chunk. Push only when the
user asks.
