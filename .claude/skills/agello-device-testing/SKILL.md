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
   tests fail with "Timed out while enabling automation mode".
   - The script checks the start itself (the preflight: phone reachable and
     unlocked, iPhone Mirroring closed, 10 GB free on this Mac) and exits with
     4 and the one thing to fix. On exit 4, ask the user to unlock the phone
     or close Mirroring. Never lock the phone or end iPhone Mirroring yourself
     unless the user asks at the time, and don't skip the check
     (`PREFLIGHT=off`) to get past it.
   - During the run: the device suites keep the screen awake themselves
     (`isIdleTimerDisabled` in `DeviceHarness`). `unit`, `ui`, `screenshots`
     and `bench` don't set it: for those, ask the user to set Auto-Lock to
     Never if the phone locks mid-run.
   - Opening iPhone Mirroring during a run locks the phone and stops the
     suite ("Unlock iPhone … to Continue"; 2026-11-02, probe 20 after 45
     cases): ask the user to leave it closed until the run ends.
2. For `ui` and `screenshots`: Settings → Developer → Enable UI Automation is
   on (it asks for the passcode once). Otherwise XCUITest waits 60 s for a
   passcode prompt on the phone and fails with "Timed out while enabling
   automation mode", so those suites can't run unattended. The device-test
   suites (`inference`, `probes`, …) don't need it.
3. The device comes from `deviceId` in the git-ignored
   `.mobilebuildmcp/config.yaml` (copy `config.example.yaml`), or
   `DEVICE_ID=<udid>`. `xcrun devicectl list devices` shows whether it's
   connected.
4. Don't edit files in the target folders (`Agello*/`) while a run is
   building: stage changes elsewhere and apply them after the run. Files
   outside them (docs, `.claude/`, `scripts/`) are safe to edit. The
   `guard-target-edits` hook denies Edit and Write there until the run's last
   suite has started testing; edits made through Bash aren't checked.
5. For `ui` and `screenshots`, turn on a Focus (Do Not Disturb) on the
   iPhone: notification banners, Claude's own included when Remote Control
   pushes to this phone, land on top of the app under test and in the
   screenshots.

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
scripts/device-harness.sh bench       # the autonomous harness (docs/HARNESS.md): bench cases through the UI, Release
```

Start suites with the Bash tool's `run_in_background: true` and send the
console to a file (`> "$scratchpad/inference.console" 2>&1`). You're notified
when the command ends, so don't poll. Chain suites in one command with `;`
when they should run back to back.

- **One run at a time.** The script takes `build/.harness.lock` in the main
  checkout and exits with 3, printing the other run's suite, pid and
  checkout, while another run holds it (from another session or worktree
  too). Wait for that run rather than deleting its lock; a lock whose process
  has gone is replaced at the next start. Chained runs are separate runs to
  the edit hook: it lets edits through once the first is testing, and the
  next one builds them, so leave the targets alone until the last has
  started testing.
- **Watching.** The raw log grows as the run goes. A Terminal panel tab
  (`run_in_terminal`) on
  `tail -n +1 -f build/device-harness/<suite>.log | /opt/homebrew/bin/xcbeautify`
  lets the user follow it; stop the tab after the run.
- **Staying awake.** The script runs `caffeinate` until it exits, on the
  iPhone and the Mac, so a run outlasts the turn that started it. A closed
  lid still puts the Mac to sleep.

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

## The bench (the autonomous harness)

`scripts/device-harness.sh bench` sends each bench case (`AgelloUITests/BenchCases.swift`: the quality
bench's eight requests, a three-part coding prompt, a Search follow-up, a file with a follow-up) through
the app's own screens in a **Release** build, with the app tracing the reply (`--trace`,
`Agello/Support/ReplyTrace.swift`). It then pulls the traces and writes
`build/device-harness/bench/report.md` (and `report.json`, and each reply as Markdown):
settings in effect, each step with memory, why the reply ended, what the screen showed, the
engine's telemetry, and each case's checks from `scripts/bench-report.py` (web apps loaded and
pressed, Swift type-checked, Python compiled or run against `scripts/bench/<id>/`, expected facts).
A full run is 13 turns and about 20 minutes; the phone warms up, so compare speeds case by case.

- `BENCH_ONLY=id,id` runs some cases; `BENCH_TRACE=off` runs without tracing (screen timings only).
- `BENCH_RESUME=1` runs only the cases the last report doesn't hold complete and keeps the
  others: use it after a run cut short (a call, a lock). A case that loses the foreground is
  retried once by itself.
- Each report opens with what changed since the baseline (`scripts/bench/baseline.json`:
  checks, how replies ended, a different reply where Search is off, speeds more than 15 % away).
  `BENCH_ACCEPT=1` makes a run the new baseline: only when the user accepts its results.
- `BENCH_COOL=1` waits for the phone to cool before each case, for speeds.
- `scripts/bench-direct.sh CASE` sends one case with no driver attached (the installed Release
  build launches with the prompt, sets the case's Think and sends it itself). Use it for speed: XCUITest's
  accessibility session costs about 8 % of decode speed and causes late frames (2026-11-10).
- The phone reaches thermal state "fair" within three cases and decodes up to a fifth slower:
  the report's "Engine over time" line shows the state and the decode rate by thirds. Let the
  phone cool before a run whose speeds matter.
- Each case's report says where the time went: before the first token, reasoning, answer; the
  main thread's work (chat writes, markdown parses); late frames; the helpers after the reply.
- It leaves the Release build on the phone, and keeps the user's chats: each case starts a new
  chat. It does change Think, Search and Think's budget, through the app's own controls.
- Use it, not a device test, to answer "what does the app do with this prompt": device tests
  run `AppState` with the harness's options, which once differed from the phone's.
- A device-test run that is killed leaves its options in the app's settings until the next
  device-test run restores them (`harnessSettingsSnapshot`). Don't kill one mid-test if a wait
  will do.

## Runtime builds on the iPhone

`scripts/phone-bench.sh` compares builds of our runtime on the phone, as `cli-bench.sh` does on
this Mac ([HARNESS.md](../../../docs/HARNESS.md), "Runtime builds on the iPhone"). Use it to
confirm a Mac result, or in place of the Mac's run when the Mac is busy: the Mac only builds.

```sh
scripts/phone-bench.sh release next                    # explain, email, file-report; 3 rounds
ROUNDS=5 scripts/phone-bench.sh release next -- explain email
scripts/phone-bench.sh release again=release           # the noise: the shipped build against itself
```

- Start it in the background and wait for the notification: about an hour to an hour and a
  half for the default. Before it, ask the user for Auto-Lock set to Never, a Focus on, iPhone
  Mirroring closed, and the phone plugged in.
- It builds the app once per runtime (Release; background priority unless
  `BUILD_PRIORITY=normal`), then installs the builds in turns, a warm-up after each install. It
  vendors each runtime into `Vendor/LiteRT-LM` to build it and puts it back, so it refuses to
  start when `Vendor/LiteRT-LM` isn't as committed. Leave the Agello* folders alone until both
  builds are done (the edit guard holds them).
- Each case is a driverless launch: the app sets the case's Think, waits for the phone to cool
  to nominal (`COOL=off` sends at once), keeps the screen on, and runs with memories off.
  Cases with Search are refused; only a case's first message is sent.
- Results in `build/phone/runs/<time>/`: read `records.txt` first (each launch, the runtime it
  ran, the heat at the send and at its hottest), then `load.txt` (which runs were disturbed,
  each build's best run), `compare.txt` (undisturbed records), `replies.txt` and `replies/`.
  A build that ran two runtimes is an install gone wrong, and the run says so.
- It holds the harness lock for the whole run, so `bench-direct.sh`, `device-run.sh logs` and
  harness suites wait for it.

## On this Mac

`PLATFORM=mac` runs the suites on this Mac, which runs the iPhone app
("Designed for iPad/iPhone") through the same Metal path and the iOS slice of
`CLiteRTLM`. It's the development bed while the iPhone is away. Its speed and
memory aren't the iPhone's, and a change still needs an iPhone run before it
ships. **Ask the user before a Mac run:** they often keep the Mac busy, and
the iPhone comes first. Not rechecked since the app declared
`iphone-performance-gaming-tier` (2026-11-10): the next Mac run will show
whether it still installs.

```sh
PLATFORM=mac scripts/device-harness.sh unit
PLATFORM=mac ONLY=AgelloDeviceTests/InferenceScenarioTests/test05_ToolCall scripts/device-harness.sh inference
```

- `ui`, `screenshots`, `memory` and `bench` stay iPhone-only: the script
  refuses them, and `all` skips `ui`. The Mac has no jetsam limit to simulate.
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
  - Lab models for the probes go in `Data/Documents/lab/`. Download them with
    `hf download … --local-dir ~/Models/agello/lab`, never into the shared
    Hugging Face cache (`agello-litert-update`, "Lab models").
  - Settings: `defaults read <container>/Data/Library/Preferences/com.patricedery.agello`.
- Logs: `log stream --level debug --predicate 'subsystem == "com.patricedery.agello"'`.
  Crash reports: `~/Library/Logs/DiagnosticReports/Agello-*.ips`.
- To look at the app outside a run, open the last run's build with
  `open -b com.patricedery.agello --args --mock-engine` (CLAUDE.md, "Claude
  desktop app").

## On this Mac, natively: the command line

`agello` (docs/CLI.md) is the app's own engine code built for macOS with SwiftPM: a development
tool for work on the runtime, never shipped. It's faster to iterate with than the iPhone, and it
can be built against any checkout of our LiteRT-LM. The iPhone still confirms what ships.

```sh
swift build -c release --scratch-path build/cli/release            # then build/cli/release/release/agello
scripts/cli-check.sh                                                # does it still build? (every harness run ends with it)
scripts/cli-test.sh unit [Class[/method]]                           # 261 unit tests, about a minute, no phone
scripts/cli-test.sh inference InferenceScenarioTests/test05_ToolCall   # real-model scenarios on this Mac's GPU
build/cli/release/release/agello bench --only todo,explain --out build/cli/runs/x.jsonl
scripts/cli-bench.sh release next -- --only explain                 # two runtime builds, in turns, with the comparison
scripts/cli-report.py | cli-timeline.py | cli-replies.py            # answer checks, where the time went, where two builds' replies part
scripts/mac-ready.sh | cli-load.py                                   # is the Mac quiet enough to measure; which runs its load disturbed
```

- **Ask before a real-model run** (anything but `unit`, `--mock`, a build or `cli-check.sh`): it
  takes this Mac's GPU, which the user often needs.
- **A measuring run handles the Mac's load itself** (`docs/CLI.md`, "System load"):
  `cli-bench.sh` asks `scripts/mac-ready.sh` first and refuses a busy Mac (exit 4, with what to
  fix: tell the user, never work around it), reads from the records which runs were disturbed
  (`load.txt`), adds rounds while a case lacks undisturbed ones, and compares on those
  (`compare.txt`; `compare-all.txt` has every record). Start it in the background and stay
  idle until it ends: a session streaming text is load too. `QUIET=off` is for a run read only
  for its replies. A change inside the noise band isn't a change.
- **What compiles there** is `Package.swift`'s list: `AppState`, `Inference/`, `Knowledge/`,
  `ModelHub/`, `Persistence/` and a few files of `Support/` and `System/`. A platform type the
  engine calls needs its twin in `AgelloCLI/Sources/Platform/`; an engine file elsewhere must be
  added to the list. `cli-check.sh` says when an app change broke it.
- **It runs as the iPhone decides:** the engine sees a simulated 8 GiB app limit, so the window
  is 32K as on the phone (`--memory-limit` changes it). Six bench cases were checked to reach
  the engine exactly as on the iPhone 17 Pro; the replies themselves differ between the GPUs.
- **Nothing of this Mac's is touched:** models are read from `~/Models/agello` and never
  changed, caches go to `~/Models/agello/cache/agello-cli/<build id>/`, tests run with their home
  folder redirected to `build/cli/test-home`, and chats live in memory.
- **Not there:** the interface's tests, the `ui`, `screenshots`, `bench` (the iPhone's) and
  `memory` suites, Search providers that need a key.
- `PLATFORM=mac` (above) runs the iPhone app's own build on this Mac through Xcode; the command
  line is the lighter way to the same engine, and the one that can change runtimes.

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

## Looking at the iPhone

The bench is how the app is driven and checked on the phone (above): a check
worth repeating becomes a bench case or a UI test, not a session of taps. To
see the screen once, `scripts/device-run.sh screenshot <name>` captures an
unlocked phone.

iPhone Mirroring ("Recopie de l'iPhone", `com.apple.ScreenContinuity`) is the
user's own tool, for looking only (dropped as a testing tool on 2026-11-10):

- It and the harness exclude each other. Opening it locks the phone; the
  preflight refuses a run while it's open; a run takes over the phone, and
  the mirror then shows "iPhone en cours d'utilisation" until the phone is
  locked. Opening it, closing it and locking the phone are the user's calls.
- When the user has it open and asks for a look, computer use reaches it
  with the background `app_*` tools (`app_screenshot`, `app_click`; access
  granted 2026-11-02). They look and tap only: scrolling, typing and long
  presses need full-screen control (`mouse_move` before a long press, about
  100 scroll ticks for three lines), and the microphone isn't reachable. After
  a few minutes idle it pauses: its "Connexion" button resumes.
- The app on the phone is the last run's build: Release after `bench`, Debug
  (the test host) after the other suites. It holds the user's chats and
  settings, so start a new chat for a check.

## Tuning a prompt or a model decision

Judge a prompt or schema change against a table of cases, not one try:

1. A device test runs each case with its expected outcome, records the raw
   output and the error per case (catch them: one bad case mustn't hide the
   rest), and fails on the wrong ones. Model: `WebScenarioTests/test04_SearchDecisions`.
2. Run it alone on the iPhone, about three minutes a round:
   `ONLY=AgelloDeviceTests/<Class>/<test> scripts/device-harness.sh <suite>`,
   and read `jq '.scenarios.<name>' build/device-harness/harness-report.json`.
   Check `recordedAt`: a test that throws before `harness.record` leaves the
   last run's record in place.
3. Iterate until the table is right, then the bench for the answers' quality
   (`scripts/device-harness.sh bench`), then the suites the change touches.

Lessons from the first round (Search when needed, 2026-11-02):
- E4B answers a yes/no "does this need X?" by what it thinks it can do alone;
  asked to name the message's kind from a short list, it gets the decision
  right, and the code decides from the kind.
- What the output must hold, the grammar should enforce: with queries
  optional, a "question" came back with none (`anyOf` now requires 1–3 for
  questions and requests, none for the rest).
- Put follow-ups with their conversation in the table: they fail
  differently from first messages.
- JSON enum values must be one word on our runtime (`agello-inference-rules`).
- Put the real input in the table, not a tidy stand-in: a follow-up passed with a two-sentence
  made-up reply as history and failed with the reply the app had actually given (2026-11-10).
  Look at what the helper reads after truncation: a cited reply cut to 400 bytes ended on the
  runner-up's name, and the plan followed that name.

## The test host

Unit and device tests run inside the app, which shows only a black screen
while it hosts them (`AppBootstrap.hostsTests`, from `XCTestConfigurationFilePath`):
the tests build their own `AppState`, and the app's own UI used to warm up a
second E4B engine next to theirs. Device memory figures recorded before
2026-10-15 (afternoon) include that engine, about 1.2 GB once it had loaded.
Probe 16 (`test16_MemoryAfterUnload`) checks that nothing stays after an
unload. UI tests launch the app normally and see its UI.

## Reading results

Everything lands in `build/device-harness/` (`build/mac-harness/` on the Mac):

| File | Use |
| --- | --- |
| Console | Formatted by Homebrew's xcbeautify (`XCBEAUTIFY=off` for raw) |
| `<suite>.log` | Full raw `xcodebuild` output: grep it for `error:` |
| `<suite>.xcresult` | `xcrun xcresulttool get test-results summary --path <bundle>` gives counts and `testFailures` as JSON |
| `attachments/<suite>/` | Per-scenario JSON metrics (device suites) and screenshots (UI tests) |
| `harness-report.json` | In-app report pulled from the device: every recorded scenario of the last run, and the device (hardware, `isiOSAppOnMac`, GPU family, Metal working set) |

Exit codes: `xcodebuild`'s (65 = test failures), 2 for a usage error, 3 while
another run holds the lock, 4 when the preflight refuses, and for `bench` 1
when the report finds a problem. The script ends with
`scripts/storage.sh brief`: the project's disk use against its budget, and any
scratch the run left. An `OUT=build/<name>` run is scratch once its numbers are
recorded (in the roadmap, a doc or a commit message); then run
`scripts/storage.sh clean`.

Each scenario in `harness-report.json` also carries `telemetry`, the engine's
account of that scenario (our runtime's, see `agello-litert-update`, "The
source build"): span timings, GPU time, host copies by buffer size, cache and
delegation counters, logits probes, anomalies. Read it with the fork's report
script:

```sh
python3 ../LiteRT-LM/tools/agello-bench/telemetry.py build/mac-harness/harness-report.json
```

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
- **Long prompts.** The engine counts a message's tokens exactly (probe 17),
  and a send must leave room for a reply (`agello-inference-rules`, "Context
  window", has the reserve): about 21K tokens fit chat's 32K window, about 10K
  at 16K. Digits cost a token each. Longer prompts, or a test that needs one
  window whatever the phone's memory, need
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

- Reply stats (`message.stats`) are hidden unless "Show performance details"
  is on, in the developer screen: five taps on Settings' version line
  (`settings.version`), then `settings.showStats`.
- There's no Advanced screen (removed 2026-11-11): the sampler presets, the
  Think budget and the other engine choices aren't in the UI. The engine-level
  switch left in Settings is On-device tools (`settings.tools`).
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
- `PLATFORM=mac` fails with "Test crashed with signal kill before
  establishing connection", and macOS says "Agello est endommagé" (damaged):
  the iPhone app's build in DerivedData (`Build/Products/Debug-iphoneos/
  Agello.app`) has a broken signature (`codesign --verify` says a sealed
  resource is missing or invalid), left by a stopped run or an unsigned
  compile check writing into the same folder. Cancel the dialog, delete that
  `Agello.app`, and run again.

- `ThinkingScenarioTests/test02_ReasoningStaysOutOfCache` failed on the Mac
  only with Google's v0.18.0 (2026-10-16: the cache grew 139 tokens over the
  second Think turn). With our runtime, which drops the reasoning right after
  the reply, it passes on the Mac too (natively, 2026-11-11) and on the
  iPhone: a failure on either is a regression.

## Launch arguments and environment

| Name | Effect |
| --- | --- |
| `--mock-engine` (or env `AGELLO_MOCK_ENGINE`) | Scripted engine: the whole UI without a model |
| `--uitest-reset` | Wipes chats, projects, files, memories and all settings before a UI test (models are kept) |
| `--uitest-fake-mic` | Fake microphone input (no permission prompt) |
| `--uitest-sample-file`, `--uitest-sample-report` | Attach sample documents generated in code (`ChatView`) |
| `--trace` | The app writes a trace of each reply to `Documents/traces/` (`ReplyTrace`); the bench passes it |
| `AGELLO_BENCH_DRAFT`, `AGELLO_BENCH_AUTOSEND=1` (env) | Open on a new chat with this draft; with autosend, send it once the model is ready (the bench and `bench-direct.sh`) |
| `AGELLO_BENCH_THINK` (1 or 0), `AGELLO_BENCH_COOL=1` (env, with autosend) | Set Think as the driver's pill would; wait up to ten minutes for the thermal state to be nominal before sending (`phone-bench.sh`, `bench-direct.sh`). Autosend also keeps the screen on |
| `-memoryEnabled NO` | The argument domain's value for that launch: no memories in the system prompt, the saved setting untouched (`phone-bench.sh`, `bench-direct.sh`) |
| `AGELLO_SIMULATE_MEMORY_GB` (env) | Stands in for the phone's memory at the hardware-floor check (`DeviceFloorUITests`) |
| `TEST_RUNNER_HARNESS_THINKING`, `_MEMORY`, `_CALIBRATE`, `_PROBES`, `_SCREENSHOTS`, `_BENCH` | Enable the opt-in suites (the script sets them) |
| `AGELLO_TELEMETRY=<0-4>` (to the script) | Engine telemetry level on our LiteRT-LM build, passed as `TEST_RUNNER_AGELLO_TELEMETRY` (default 2: span timings; 4 times each GPU kernel and slows the run) |
| `TEST_RUNNER_AGELLO_VERIFY_DIRECT_COPIES=1` | Our build checks every direct Metal host copy against ML Drift's own conversion; a difference is an error anomaly in the scenario's telemetry |
| `AGELLO_SIMULATE_APPLE_GPU="Apple A17 Pro"` (to the script) | Our build picks another Apple GPU's kernels (here the Apple9 paths), with caches of their own. A runtime debugging aid: no supported iPhone has that GPU. Code paths only: speed, thermals and memory stay this device's; telemetry's `gpu` fact names the family used. Run memory envelopes one per launch (`ONLY=…/test03_…`): in sequence each test inherits 0.8–1.4 GB from the last |

## After a change

Run the relevant suite, then commit each verified chunk. Push only when the
user asks.
