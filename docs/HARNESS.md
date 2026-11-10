# The autonomous harness

A plan, approved by the maintainer on 2026-11-10. H1 is done (below); nothing later is built.

The goal: one command runs Agello on the iPhone as a user would, through its real screens, and
comes back with one report per reply that joins what was on screen, what the app did, and what the
engine did. No screen mirroring, and no one watching.

## Why

On 2026-11-09 and 10 a question took a day to answer: "this answer was cut short, why?" The tools
each saw one layer.

- **iPhone Mirroring** needs the phone locked while test runs need it unlocked. In the background
  it only taps; scrolling and typing take over the Mac's screen; the microphone isn't reachable.
  It drives by pixel position (one press landed on the Voice button), and it records nothing.
- **The device tests** call `AppState` directly, with their own options. The quality bench ran
  Think with 1,024 tokens while the app on the same phone used 4,096, so it reproduced a reply the
  app no longer gives.
- **The UI tests** drive the real screens but record nothing from below: XCUITest runs in another
  process and sees neither reply stats nor engine telemetry.
- **Nothing recorded why a reply ended.** The model's own end, an output cap, Stop, memory and
  the background all look the same from the stored text.

## What exists and stays

| Piece | Where | Role in the new harness |
| --- | --- | --- |
| 25 UI tests, a tour with the real model | `AgelloUITests/` | The driver's helpers and identifiers (`chat.input`, `chat.stop`, `message.model`) |
| Launch arguments | `AppBootstrap`, `AppReset` | Clean state, sample files, the fake microphone |
| Engine telemetry, levels 0–4 | our LiteRT-LM build, `EngineTelemetry` | The engine layer of each report |
| A `Reply` signpost interval and a first-token event | `ChatEngine` | Extended to the whole path |
| The quality bench and its checks | `QualityBenchProbe`, `scripts/quality-codecheck.sh` | Its nine cases move to the UI driver |
| `scripts/device-harness.sh` | lock, `caffeinate`, report pull, storage summary | Gains a `bench` suite and a preflight |

The unit suite and the engine-level device suites (`inference`, `files`, `web`, `thinking`,
`memory`, the probes) stay as they are: they test parts in isolation and run fast.

## Design

Three layers write into one report, joined by the reply's ID.

### 1. The surface: a UI bench driver

A new class in `AgelloUITests`, run as the `bench` suite.

- It launches the app clean, sets Think and Search with the composer's own buttons, enters the
  prompt, taps send, and waits on conditions (`chat.stop` appears, then goes), never on sleeps.
- When the reply ends it reads the rendered text back, scrolls to the top and the bottom to prove
  both are reachable, and attaches a screenshot of the end.
- It measures from outside, coarsely: send to first visible text, send to done. The precise
  figures come from the app's trace.
- It builds **Release**. UI tests don't need `@testable`, so speed numbers are real, and the
  phone keeps an optimized build after a run instead of a Debug test host.

### 2. The app: a reply trace

A small recorder in shared code (`Agello/Support/ReplyTrace.swift`), off unless a launch argument
turns it on. It writes one JSON file per reply into `Documents/traces/`, which the harness pulls
with `devicectl` as it pulls the report today. Nothing is sent anywhere.

Each trace holds, with monotonic timestamps:

- **The settings in effect:** window, Think budget, tools, Search, sampler, build and runtime IDs.
- **The path:** send, file context, the search plan (kind and queries), search results,
  `fitContext` (trimmed or not), prefill, first token, first text on screen, done.
- **Why it ended:** the model's end, an output cap, Stop, low memory, or the background.
- **Conditions:** footprint and available memory at each step, memory warnings, thermal state,
  scene phase changes.
- **The reply:** its text and reasoning, token counts, speeds.

Events are per step, not per token, so tracing shouldn't move the speed it measures. H1 measures
that with tracing on and off.

The same names become signpost intervals, so Instruments shows the path too.

### 3. The engine

The telemetry snapshot the device tests already take per scenario is taken per reply and stored
in the trace, at the level the run asks for.

### The join and the verdicts

A script on the Mac merges the three into `build/device-harness/bench/<run>/`: one JSON report,
one readable summary, and each reply as Markdown. Checkers then judge the replies:

- **Whole:** every part asked for is there, code blocks are closed, and the reply ended by itself.
- **Works:** code is run against tests written from the prompt's spec (as done by hand on
  2026-11-10), web apps are loaded and pressed, citations exist with Search.
- **Agrees:** the text on screen is the text in the trace.

### Running unattended

- **Preflight** before the build: the phone is connected and unlocked, UI automation is enabled,
  iPhone Mirroring is closed, a Focus is on, there's room on disk, and the battery isn't low.
  It stops with the one thing to fix.
- **One session per run:** every case in a single `xcodebuild` invocation, so the phone stays
  awake from the first case to the last.
- **Interruptions are named:** a case whose trace shows the background or a lock is marked
  interrupted and retried once, not counted as a failure.
- **Resume:** a rerun skips the cases the last report already holds.
- **Regressions:** each run is compared with the last accepted one, case by case.

## What it can't do

- Unlock the phone or enable UI automation. Both stay the maintainer's.
- Use the real microphone or camera. The fake microphone and sample files stand in.
- Avoid the Mac: every run starts with a build there.
- Answer system prompts reliably. Interruption monitors cover the known ones.

## Milestones

| | Scope | Done when |
| --- | --- | --- |
| **H1** | One case end to end: the three-part coding prompt of 2026-11-09. The bench driver, trace v1 (settings, path, why it ended, stats), the pull and merge, the code checker. | One command gives a report with all three layers for that reply, with tracing's cost measured. |
| **H2** | The bench's nine cases and the Search, file and follow-up flows on the driver, with their checkers. | The quality bench runs through the UI, and `QualityBenchProbe` is retired. |
| **H3** | Deeper probes: first render and flush cadence, scroll jumps and hitches, a memory timeline, helper tasks (titles, memories), signposts. | A slow or jumpy reply shows which layer was slow. |
| **H4** | Autonomy: preflight, one session, interruptions, resume, comparison with a baseline. | A full run needs nothing but an unlocked phone, and says what changed since the last. |
| **H5** | Coverage: every screen and menu, the attach menu with sample files, Voice with the fake microphone, share and intent routes. | The driver has touched every control the app has. |
| **H6** | Retire and document: mirroring kept for looking only, docs and skills updated. | The fix loop in `CLAUDE.md` names the harness, not the mirror. |

H1 proves the design. If the three layers don't join cleanly there, the plan changes before the
rest is built.

### H1, done on 2026-11-10

`scripts/device-harness.sh bench` builds Release (the `AgelloBench` scheme), runs
`AgelloUITests/BenchUITests` with `--trace`, pulls `Documents/traces` from the phone, and
`scripts/bench-report.py` writes `build/device-harness/bench/report.md`, `report.json` and each
reply as Markdown.

- **The three layers join.** The driver's row and the app's trace are matched by the send time;
  the screen's text, read back through accessibility, ends as the trace's text ends.
- **The driver** starts a new chat with the prompt as the composer's draft
  (`AGELLO_BENCH_DRAFT`), sets Think and Search with the composer's pills and Think's budget in
  Settings → Advanced, taps Send, and scrolls to the top when the reply is done.
- **The trace** (`Agello/Support/ReplyTrace.swift`) holds the settings in effect, the steps (send,
  fit, reply, engine send, first token, first text on screen, engine finished, helpers, scene
  changes) with memory at each, why the reply ended, its text and stats, and the engine's
  telemetry before and after.
- **The verdict** for the three-part prompt runs the reply's code against tests written from the
  prompt (`scripts/bench/ttl-cache/`).
- **Tracing costs nothing measurable:** 117.3 s and 117.5 s with it on, about 125 s on screen
  with it off (the screen is read every 5 s). Looking every second or every five made no
  difference either.
- **What it found on its first run:** the phone's Think budget was 1,024, not the 4,096 the app
  had been given: a device-test run killed mid-test had left its options in the app's settings.
  Device tests now restore a lost snapshot at their next run, and the bench sets its own budget.
- **Open for H3:** the bench decodes this reply at 40 tok/s where a hand run the day before gave
  49. Tracing and the driver's looking are ruled out; the phone's heat after a day of runs and
  the accessibility session XCUITest keeps open are not.

## Decisions for the maintainer

1. **Long prompts.** Typing 2,900 characters through XCUITest is slow and a newline may send
   early. Proposed: a test-only argument fills the composer's draft, and the driver still taps the
   real send button. Typing stays covered by the existing UI tests.
2. **The bench builds Release.** Proposed: yes. The engine-level suites keep Debug.
3. **Tracing only by launch argument.** Proposed: yes for now. A switch in Settings → Advanced, so
   a user can share a trace of a bad reply, is a later choice.
4. **Where results live.** Proposed: reports in `build/` (scratch, as today), the numbers that
   matter in the roadmap, and one small committed file of accepted baselines.
5. **Order.** H1 first, then H2 to H6 in order.

## Risks

- **Flaky long waits.** A reply can take two minutes. Waits are conditions with timeouts sized
  from the case's token cap.
- **Reading long text through accessibility** may be slow or split across elements. The trace is
  the source for content; the screen check is for "visible and reachable".
- **Tracing changes what it measures.** Measured in H1; per-step events only.
- **iOS updates** can reset developer settings. The preflight says so instead of timing out.
