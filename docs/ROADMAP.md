# Roadmap

What has shipped, what's next, and what waits for hardware. Updated 2026-10-24.

## Current status

The handoff between work sessions: read this first, then the section of the plan it points to.

- **The app** hasn't changed since the iPhone run of 2026-10-16, which passed every default suite (`unit`, `inference`, `files`, `web`, `thinking`, `ui`, probes 17–19). It ships on Google's LiteRT-LM v0.18.0 with our patched model file.
- **The iPhone 17 Pro is available again** (2026-10-24). The opt-in `calibrate` and `memory` suites and the manual checks below haven't been run on it yet.
- **#3913 upstream:** a model exported with litert-torch's RoPE composite fixes the bug at the source.
  - john-rocky's Gemma 4 E2B export is exact on the iPhone 17 Pro and on all three Mac M6 setups: 118/118 cases, against 35/118 for the stock file (the iPhone and Mac runs were posted on 2026-10-24).
  - It's 2–3× slower, but its int8 export recipe also differs. We asked for the same export without the composite, to time the two side by side.
  - Waiting for: that export, an E4B export, and an E2B export with a longer cache. Probe 20 (`AgelloDeviceTests/LabSuiteProbe.swift`) and agello-bench rerun the same cases on any of them.
  - The `agello-litert-update` skill has the thread's history.
- **Not started:** our LiteRT-LM build (Next, item 1) and Agello for Mac (item 2). Both begin in the fork's `agello-next` branch:
  - the runtime fixes in item 1;
  - M0 in [MAC.md](MAC.md): a versioned macOS framework, the iOS slice's platform plist, package platforms set to iOS and macOS 27.

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
   - Runtime fixes: the speculative-decoding bound at the end of the cache, one final event per message, a sampler per conversation, and reply stats without benchmark mode.
   - Then a release with iPhone and Mac slices, the iPhone gate on that exact build, and publishing.
   - On an iPhone 17 Pro, in a cooled calibration, it decoded 37–45 tokens a second at a 32K window. Google's binary decoded 20 the same night.
2. **Agello for Mac.** A native Mac app that shares the iPhone app's code, with full parity, widgets and the share extension included. It runs on our build's Metal Mac slice and ships as a notarized DMG. The plan, phases M0 to M9, is in [MAC.md](MAC.md). It depends on item 1 for its runtime.
3. **Energy and performance budgets,** written down and checked with the `calibrate` suite and MetricKit.
4. **#3913 follow-up.** Run the next exports from the thread (above) through probe 20 and agello-bench. If a re-exported Google file or a runtime fix ships, check it with probe 10 and the `inference` suite, and the catalog can go back to Google's file (`agello-litert-update`, "When Google fixes #3913").

## Waiting for the iPhone

The phone is available as of 2026-10-24.


- **Manual checks:**
  - AirPods in voice mode and dictation;
  - a phone call during voice mode;
  - the voice camera in landscape;
  - the prompt before a cellular download.
- **Opt-in suites:** `calibrate` and `memory`.
- **The runtime gate** for item 1, and the iPhone checks the Mac work queues ([MAC.md](MAC.md), M1).

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

- **Default context** once our build ships: ours decodes at nearly the same speed from 4K to 32K.
- **An iPhone 15 or 16 Pro** to validate our build before it ships to those devices.
- **For the Mac:** the sandbox, the App Group, the bundle ID, Sparkle updates, supported Macs, and the iPhone app's availability on the Mac App Store ([MAC.md](MAC.md), "Open decisions").
