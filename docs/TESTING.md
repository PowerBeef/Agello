# Testing

iRTChat is tested on a physical iPhone only. The simulator has no Metal path for LiteRT-LM, and the failures that matter (native heap corruption, GPU precision, memory pressure, background termination) only show up on real hardware.

## The suites

| Target | Tests | Covers |
| --- | --- | --- |
| `iRTChatTests` | 209 | Planner, context budgeting, schema migration and branching, regenerate / edit / versions, markdown, file reading and chunking, retrieval and citations, summaries, projects, memory, web parsers and page extraction (recorded fixtures), dictation, voice-activity detection, deep links and intents, Spotlight, the share inbox, chat grouping and search, personalization, titles, downloads, and the whole app pipeline through a scripted engine |
| `iRTChatDeviceTests` | 45 | The real models, in-process: download, load, text, chat isolation, stop and continue, tools, thinking, image, audio, settings rebuilds, context limits, titles, memory, dictation accuracy, voice turns, exact digits past 2,048 and 4,096 tokens, benchmark; files (EmbeddingGemma indexing, "summarize this 40-page PDF", cited follow-up, search chats by meaning); live web search, automatic search with the on-device tools off |
| `iRTChatUITests` | 22 | Real taps: send, Stop, Home button mid-reply, leaving and returning mid-reply, rapid settings changes, drawer and search, pin / rename / delete, projects, attached files, web search, dictation, voice mode, deep links, a long summary in the background, regenerate / edit / versions, Think, memory settings, markdown, keyboard clearance, composer controls that fit at every text size, Models; plus the opt-in screenshot tour |

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

ONLY=iRTChatTests/AppStateTests scripts/device-harness.sh unit   # part of a suite
```

## Results

Everything lands in `build/device-harness/`: a result bundle and the raw `xcodebuild` log for each suite (`<suite>.log`), per-scenario JSON metrics and UI screenshots under `attachments/`, and `harness-report.json`, an in-app report pulled from the device that survives crash relaunches within a run. Console output goes through Homebrew's [xcbeautify](https://github.com/cpisciotta/xcbeautify) when it's installed (`XCBEAUTIFY=off` for raw output). The exit code is `xcodebuild`'s (65 means test failures).

Outside test runs, `scripts/device-run.sh` relaunches the installed app and saves its logs (`logs [seconds]`), captures the iPhone's screen (`screenshot`), and lists or copies iRTChat's crash reports (`crashes [pull]`). The app logs under the subsystem `com.patricedery.irtchat`, categories `engine`, `generation` and `lifecycle`.

## Without a model

Launch the app with `--mock-engine` (**Product → Scheme → Edit Scheme → Run → Arguments**) to drive the whole interface with a scripted engine: streaming, reasoning, titles, regenerate and edit, without downloading anything. A prompt containing "markdown" returns a rich sample with code, a table and math. The unit tests use the same engine.
