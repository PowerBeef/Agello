# Roadmap

What has shipped, what's next, and what waits for hardware. Updated 2026-10-28.

## Current status

The handoff between work sessions: read this first, then the section of the plan it points to.

- **The app runs on our LiteRT-LM build** since 2026-10-28: release [`agello-next-20261024`](https://github.com/PowerBeef/agello-litert-lm/releases/tag/agello-next-20261024) (build id `99b8f5f6ea49`, from `agello-next` at `f1b88286`), with our patched model file. On this Mac that exact build passed `unit`, `inference`, `files`, `web`, `thinking` and the probes. Its iPhone run (4.3) is next. The last iPhone run, on Google's v0.18.0 on 2026-10-16, passed every default suite.
- **The iPhone 17 Pro is available again** (2026-10-24). The opt-in `calibrate` and `memory` suites passed on it that day, on Google's v0.18.0: the baseline for the budgets (Next, item 3). The manual checks below are still to do.
- **#3913 upstream:** a model exported with litert-torch's RoPE composite fixes the bug at the source.
  - john-rocky's Gemma 4 E2B export is exact on the iPhone 17 Pro and on all three Mac M6 setups: 118/118 cases, against 35/118 for the stock file (the iPhone and Mac runs were posted on 2026-10-24).
  - It's 2–3× slower, but its int8 export recipe also differs. We asked for the same export without the composite, to time the two side by side.
  - Waiting for: that export, an E4B export, and an E2B export with a longer cache. Probe 20 (`AgelloDeviceTests/LabSuiteProbe.swift`) and agello-bench rerun the same cases on any of them.
  - The `agello-litert-update` skill has the thread's history.
- **Our LiteRT-LM build (Next, item 1)** on the fork's `agello-next` (started 2026-10-24, pushed and released 2026-10-28). Builds now use Xcode 27.1.
  - M0.1 of [MAC.md](MAC.md) (`78e7edc4`): the Mac slice is a versioned framework, the iOS slice's plist names the device SDK, and the package requires iOS and macOS 27.
  - Runtime fix (a) (`3fa97211`): no MTP round past the end of the KV cache.
  - Runtime fix (b) (`8acc748c`): one final chunk per conversation send at the C boundary, for every binding. Agello's `test05_ToolCall` and probe 15 pass on this Mac with that build.
  - Runtime fix (c) (`f1b88286`): the sampler follows the active session, so presets and Regenerate's seeds apply on our build too (probe 18).
  - Fix (d), in Agello (`3c4f42a`): on our build, reply stats come from its telemetry and benchmark mode stays off, from 8 ms of CPU per decoded token to 0.7 on the Mac. Google's binary keeps benchmark mode. Checked on this Mac on both runtimes; the iPhone run is still to do.
  - Release (4.2, 4.4): the dry run's files, published unchanged as `agello-next-20261024` on 2026-10-28 after the Mac suites passed (`agello-next` pushed). The third-party notices are in `NOTICE` and the Licenses screen; no new required-reason APIs.
  - Next: the iPhone gate (4.3) on that exact build: the default suites, then `calibrate` and `memory` against the baseline below.
- **Agello for Mac (Next, item 2) has started** (2026-10-24): M0.2 and M0.3 of [MAC.md](MAC.md) are done. The `AgelloMac` target builds a sandboxed, hardened app whose runtime self-test passes on our build, GPU and CPU. Open in M0: the notarization dry run (Developer ID and the maintainer's API key). M1 is done (2026-11-01): the iPhone-only code is in `AgelloiOS/`, behind one type per platform seam, and the shared shell is extracted, with Vocello 3.0 as the reference again; its iPhone batch is queued below. M2 is done too (2026-11-01): Agello for Mac compiles and runs the shared app in a first shell, its 310 unit tests pass natively (`PLATFORM=macos-native unit`), and it loads E4B on the GPU in the sandbox. Next: M3, the Mac's platform policy (memory classes, pressure, App Nap, Keychain), with the native device suites it needs.

## Shipped

- **The app.** Chat, files, projects and memory, web search and dictation, voice mode with the camera, and system integration (Siri and Shortcuts, widgets, Control Center, Spotlight, the share sheet). The original plan is in [archive/agello-overhaul.md](archive/agello-overhaul.md).
- **Long-context digits ([#3913](ENGINEERING.md#long-context-digits-on-the-gpu-litert-lm-3913)).** Agello downloads a model file whose rotary positions are split into 512-token blocks, a workaround worked out with other developers on the issue. It copies digits exactly to 32K tokens on every GPU tested, M1-class Macs included.
- **Reliability and polish (October 2026):**
  - **The runtime wrapper.** A tool call the runtime rejects can no longer crash a reply, Stop works between tool rounds, and tool rounds are bounded.
  - **Context.** Every message is counted exactly, with the runtime's own renderer and tokenizer. A 32K window budgets only the positions that exist.
  - **Helpers.** Titles and memories clean up after themselves, never wipe a chat's history, and never run on the GPU in the background.
  - **History.** The chat store is set aside only when it's truly corrupt, never for a transient error.
  - **Retrieval.** Passages are sized in tokens, and documents with CJK or number-heavy text are indexed. A file that can't be embedded falls back to keywords on its own. Search is faster.
  - **Answers.** Regenerate gives a new answer, and chat markers in files, web pages and tool results are neutralized.
  - **Interface.** Streaming markdown renders incrementally. Launch, the drawer and voice mode are faster.
  - **Release readiness.** A privacy policy and a licenses screen, onboarding copy that matches what the app does, VoiceOver announcements and an accessibility audit, and MetricKit diagnostics that users share themselves.

## Next

1. **Our LiteRT-LM build** (the fork's `agello-next` branch).
   - Runtime fixes, all done: the speculative-decoding bound at the end of the cache, one final event per message, a sampler per conversation, and reply stats without benchmark mode.
   - Released with iPhone and Mac slices and vendored on 2026-10-28. Left: the iPhone gate on that exact build.
   - On an iPhone 17 Pro, in a cooled calibration, it decoded 37–45 tokens a second at a 32K window. Google's binary decoded 20 the same night.
2. **Agello for Mac.** A native Mac app that shares the iPhone app's code, with full parity, widgets and the share extension included. It runs on our build's Metal Mac slice and ships as a notarized DMG. The plan, phases M0 to M9, is in [MAC.md](MAC.md). It depends on item 1 for its runtime.
3. **Energy and performance budgets,** written down and checked with the `calibrate` suite and MetricKit. The baseline is Google's v0.18.0 on the iPhone 17 Pro, measured on 2026-10-24 at a nominal thermal state throughout:
   - **`calibrate`** at 4K / 8K / 16K / 32K windows. First token: 1.5 / 2.1 / 5.8 / 16.0 s for 1.3K / 2.3K / 4.4K / 8.4K-token prompts. Decode: 37 / 39 / 45 / 27 tok/s on a one-sentence reply, and 82 / 74 / 68 / 55 on a 120-token list drawn from the prompt. Peak footprint: 1.2 / 1.3 / 1.9 / 3.4 GB.
   - **`memory`,** an 8 GB iPhone simulated at 5.0 / 4.0 / 3.5 GB usable. E4B loads at 8K with vision, audio and MTP each time, and text, an image, audio, and 2.3K and 4.4K-token prompts all pass. The app peaks at 2.7 GB, leaving 2.3 / 1.3 / 0.8 GB after 1 / 2 / 3 memory warnings, and decode slows to 41 / 35 / 29 tok/s. It's an optimistic bound: the phone keeps its full RAM for the model file.
4. **#3913 follow-up.** Run the next exports from the thread (above) through probe 20 and agello-bench. If a re-exported Google file or a runtime fix ships, check it with probe 10 and the `inference` suite, and the catalog can go back to Google's file (`agello-litert-update`, "When Google fixes #3913").

## Waiting for the iPhone

The phone is available as of 2026-10-24.

- **Manual checks:**
  - AirPods in voice mode and dictation;
  - a phone call during voice mode;
  - the voice camera in landscape;
  - the prompt before a cellular download.
- **The runtime gate** for item 1, and the iPhone checks the Mac work queues ([MAC.md](MAC.md), M1): the default suites with `ui`, then `screenshots` against the last tour, so the iPhone app is shown unchanged by M1.

## Later

Each of these is measured, then kept or dropped:
- **Other iPhones:** check our build on an iPhone 15 or 16 Pro, then their prompt processing.
- **Speed:**
  - the vision encoder on the GPU;
  - batched embedding lookups on the CPU;
  - INT4 prompt processing on the GPU Neural Accelerators;
  - window-aware attention products;
  - Metal binary archives for a faster cold start;
  - a ring-buffer cache for the local attention layers;
  - the composer in its own view, so typing redraws less.
- **Upstream:** rebase the fork on upstream LiteRT-LM.

## Open decisions

- **Default context** on our build, after its iPhone run: it decodes at nearly the same speed from 4K to 32K.
- **An iPhone 15 or 16 Pro** to validate our build before it ships to those devices.
- **For the Mac:** the sandbox, the App Group, the bundle ID, Sparkle updates, supported Macs, and the iPhone app's availability on the Mac App Store ([MAC.md](MAC.md), "Open decisions").
