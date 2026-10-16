# Testing

Agello is tested on a physical iPhone, and on an Apple silicon Mac running the iPhone app. The simulator isn't used: our runtime has no simulator build, and the failures that matter (native heap corruption, GPU precision, memory pressure, background termination) only show up on real hardware.

## The suites

Test methods declared at `047c151` (2026-10-16). The iPhone run of 2026-10-16 (iPhone 17 Pro, iOS 27.0.1, Google's LiteRT-LM v0.18.0) passed every default suite: 296 unit tests, the `inference`, `files`, `web` and `thinking` scenarios, probes 17–19, and 23 UI flows, with 1 skipped.

| Target | Tests | Covers |
| --- | --- | --- |
| `AgelloTests` | 296 | Planner, context budgeting, schema migration and branching, regenerate / edit / versions, markdown, file reading and chunking, retrieval and citations, summaries, projects, memory, web parsers and page extraction (recorded fixtures), dictation, voice-activity detection, deep links and intents, Spotlight, the share inbox, chat grouping and search, personalization, titles, downloads, and the whole app pipeline through a scripted engine |
| `AgelloDeviceTests` | 56 | The real models, in-process: download, load, text, chat isolation, stop and continue, tools, thinking, image, audio, settings rebuilds, context limits, titles, memory, dictation accuracy, voice turns, exact digits past 2,048 and 4,096 tokens, benchmark; files (EmbeddingGemma indexing, "summarize this 40-page PDF", cited follow-up, search chats by meaning); live web search, automatic search with the on-device tools off |
| `AgelloUITests` | 24 | Real taps: send, no jumping while a reply streams, Stop, Home button mid-reply, leaving and returning mid-reply, rapid settings changes, drawer and search, pin / rename / delete, projects, attached files, web search, dictation, voice mode, deep links, a long summary in the background, regenerate / edit / versions, Think, memory settings, markdown, keyboard clearance, composer controls that fit at every text size, Models, an accessibility audit of the main screens; plus the opt-in screenshot tour |

The device scenarios include opt-in suites for work that's too slow or too specialized for every run: long Thinking answers, an **8 GB iPhone memory simulation** (incompressible ballast shrinks usable memory to 5.0, 4.0 and 3.5 GB), **context calibration** (speed and memory at 4K–32K), and **LiteRT-LM probes** that test the runtime directly. The probes are how [#3913](ENGINEERING.md#fixing-long-context-math-on-the-gpu-litert-lm-3913) was pinned to position 2,048 and its fix proven.

## Running them

The harness targets the `deviceId` in `.mobilebuildmcp/config.yaml`, a local, git-ignored file. Create it once and set your iPhone's UDID (from `xcrun devicectl list devices`), or pass `DEVICE_ID=<udid>` per run. It downloads E4B and EmbeddingGemma if they're missing. Keep the iPhone unlocked for the whole run.

```sh
cp .mobilebuildmcp/config.example.yaml .mobilebuildmcp/config.yaml

scripts/device-harness.sh unit        # unit tests (~3 min, scripted engine)
scripts/device-harness.sh inference   # engine scenarios with the real model
scripts/device-harness.sh files       # files and search with the real models
scripts/device-harness.sh web         # live web search (needs internet)
scripts/device-harness.sh ui          # real-tap UI flows
scripts/device-harness.sh all         # unit, inference + files + web, then UI
scripts/device-harness.sh thinking | memory | calibrate | probes   # opt-in
scripts/device-harness.sh screenshots # opt-in tour with the real model (README images)

ONLY=AgelloTests/AppStateTests scripts/device-harness.sh unit   # part of a suite
```

### On a Mac

`PLATFORM=mac` runs the suites on the Mac itself: it runs the iPhone app ("Designed for iPad/iPhone") through the same Metal path and the iOS build of LiteRT-LM, which makes it a development bed when no iPhone is at hand. The UI suites and the memory simulation stay iPhone-only, and the Mac's speed and memory aren't an iPhone's: every change still gets an iPhone run before it ships.

```sh
PLATFORM=mac scripts/device-harness.sh unit
PLATFORM=mac scripts/device-harness.sh inference
```

The first run registers the Mac for development with the signing team. Results land in `build/mac-harness/`; app logs come from `log stream --predicate 'subsystem == "com.patricedery.agello"'` and crash reports from `~/Library/Logs/DiagnosticReports/`.

## Results

Everything lands in `build/device-harness/`: a result bundle and the raw `xcodebuild` log for each suite (`<suite>.log`), per-scenario JSON metrics and UI screenshots under `attachments/`, and `harness-report.json`, an in-app report pulled from the device that survives crash relaunches within a run. Console output goes through Homebrew's [xcbeautify](https://github.com/cpisciotta/xcbeautify) when it's installed (`XCBEAUTIFY=off` for raw output). The exit code is `xcodebuild`'s (65 means test failures).

Outside test runs, `scripts/device-run.sh` relaunches the installed app and saves its logs (`logs [seconds]`), captures the iPhone's screen (`screenshot`), and lists or copies Agello's crash reports (`crashes [pull]`). The app logs under the subsystem `com.patricedery.agello`, categories `engine`, `generation` and `lifecycle`.

## Without a model

Launch the app with `--mock-engine` (**Product → Scheme → Edit Scheme → Run → Arguments**) to drive the whole interface with a scripted engine: streaming, reasoning, titles, regenerate and edit, without downloading anything. A prompt containing "markdown" returns a rich sample with code, a table and math. The unit tests use the same engine.
