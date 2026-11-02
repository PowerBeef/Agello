# Roadmap

What has shipped, what's next, and what waits for hardware. Updated 2026-10-28.

## Current status

The handoff between work sessions: read this first, then the section of the plan it points to.

- **The app runs on our LiteRT-LM build** since 2026-10-28: release [`agello-next-20261024`](https://github.com/PowerBeef/agello-litert-lm/releases/tag/agello-next-20261024) (build id `99b8f5f6ea49`, from `agello-next` at `f1b88286`), with our patched model file. **Its iPhone gate (4.3) passed on 2026-11-02** on the iPhone 17 Pro (iOS 27.2), with Agello at `1929ab7`: `unit` 315 (1 skipped), `inference` + `files` + `web` 30/30, `ui` 23 (1 skipped), `thinking` 3/3, `probes` 17 (4 skipped: lab models and variables not set), `screenshots`, `calibrate` and `memory`. The same suites pass in Agello for Mac (`PLATFORM=macos-native`).
- **The iPhone 17 Pro** is available (2026-11-02). Its October baseline (Google's v0.18.0) and our runtime's numbers are in Next, item 3. The manual checks below are still to do.
- **Answer quality (2026-11-02):** three fixes found from the iPhone, checked on this Mac (the phone became unavailable before their iPhone runs).
  - Long answers: with the on-device tools offered, the answering round got a quarter of the room with Think's reasoning inside it, so long answers stopped at about 1,960 tokens (probe 23). That round now gets half the room with the reasoning on top, history trimming keeps a quarter of the window free, and the context is 16K everywhere, no longer a setting (`2d8bc3a`). On the iPhone probe 23, `inference`, `thinking` and `files` passed with it.
  - Search and files: the message is a request and the sources or files its reference material; "create a calculator app" with Search came back as a summary of what pages say (`02c7c6a`).
  - Search as research: the model plans queries for what the message needs (the APIs and techniques, and one complete example for a request), EmbeddingGemma ranks the same shortlist by each passage's best match to the message or a need, code samples keep their lines, and a request's sources leave more room for the work.
  - Probe 24, a quality bench of eight realistic requests run in Agello for Mac, records every reply and tries generated web apps in a web view; `scripts/quality-codecheck.sh` type-checks its Swift against the iOS SDK and compiles its Python. Three runs each, against the old Search: the calculator works 2 of 3 times either way; the SwiftUI view's distinct type-check errors go from 3 / 4 / 1 to 1 / 3 / 1, with invented APIs in one run instead of all three, and replies take no longer. Planned for techniques only, the calculators lost their complete examples and broke (0 of 2), hence the example query. Live search makes single runs noisy: judge Search changes on `BENCH_REPEAT=3`.
  - On the iPhone (2026-11-02, later that night): `web` 4/4 and `files` 4/4 pass with the new prompts and Search.
  - **Open, the maintainer's call:** the memory envelope at the app's 16K window passes at 5.0 and 4.0 GB usable but is killed at 3.5 GB (an 8 GB iPhone under heavy pressure): a 16K load holds about 0.8 GB more than 8K (1.92 against 1.13 GB), an image leaves 0.31 GB, and the next 2K-token prompt goes over. With 8K it passed every step. Options: 16K only when memory allows at load (8K below about 3.5 GB available), 16K on 12 GB iPhones and Macs with 8K on 8 GB iPhones, or a lighter vision path.
  - A code block with an "@" (Swift's @State, CSS's @media) hung the app: the highlighter read an empty word at "@" and never advanced. Fixed, with a UI test streaming a calculator web app that must keep the app responsive.
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
  - Fix (d), in Agello (`3c4f42a`): on our build, reply stats come from its telemetry and benchmark mode stays off, from 8 ms of CPU per decoded token to 0.7 on the Mac. Google's binary keeps benchmark mode. Checked on this Mac on both runtimes and on the iPhone (the gate's stats come from it).
  - Release (4.2, 4.4): the dry run's files, published unchanged as `agello-next-20261024` on 2026-10-28 after the Mac suites passed (`agello-next` pushed). The third-party notices are in `NOTICE` and the Licenses screen; no new required-reason APIs.
  - The iPhone gate (4.3) passed on that exact build (2026-11-02, above). Next in the fork: merge `agello-next` (the maintainer pushes).
- **Agello for Mac (Next, item 2) has started** (2026-10-24): M0.2 and M0.3 of [MAC.md](MAC.md) are done. The `AgelloMac` target builds a sandboxed, hardened app whose runtime self-test passes on our build, GPU and CPU. Open in M0: the notarization dry run (Developer ID and the maintainer's API key). M1 is done (2026-11-01): the iPhone-only code is in `AgelloiOS/`, behind one type per platform seam, and the shared shell is extracted, with Vocello 3.0 as the reference again; its iPhone batch is queued below. M2 is done too (2026-11-01): Agello for Mac compiles and runs the shared app in a first shell, its 310 unit tests pass natively (`PLATFORM=macos-native unit`), and it loads E4B on the GPU in the sandbox. M3 is done but for its speed checks (2026-11-02): memory classes and pressure shared by both apps, App Nap and sleep on the Mac, and the native device suites (`PLATFORM=macos-native` `inference`, `files`, `web`, `thinking`, `probes` all pass). Left in M3: `calibrate` and the hidden-window probe on a quiet Mac. Next: the iPhone batch below, then M4.

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
   - Released with iPhone and Mac slices and vendored on 2026-10-28; its iPhone gate passed on 2026-11-02. Left: merging `agello-next` in the fork.
   - On an iPhone 17 Pro, in a cooled calibration, it decoded 37–45 tokens a second at a 32K window. Google's binary decoded 20 the same night.
2. **Agello for Mac.** A native Mac app that shares the iPhone app's code, with full parity, widgets and the share extension included. It runs on our build's Metal Mac slice and ships as a notarized DMG. The plan, phases M0 to M9, is in [MAC.md](MAC.md). It depends on item 1 for its runtime.
3. **Energy and performance budgets,** written down and checked with the `calibrate` suite and MetricKit. The baseline is Google's v0.18.0 on the iPhone 17 Pro, measured on 2026-10-24 at a nominal thermal state throughout:
   - **`calibrate`** at 4K / 8K / 16K / 32K windows. First token: 1.5 / 2.1 / 5.8 / 16.0 s for 1.3K / 2.3K / 4.4K / 8.4K-token prompts. Decode: 37 / 39 / 45 / 27 tok/s on a one-sentence reply, and 82 / 74 / 68 / 55 on a 120-token list drawn from the prompt. Peak footprint: 1.2 / 1.3 / 1.9 / 3.4 GB.
   - **`memory`,** an 8 GB iPhone simulated at 5.0 / 4.0 / 3.5 GB usable. E4B loads at 8K with vision, audio and MTP each time, and text, an image, audio, and 2.3K and 4.4K-token prompts all pass. The app peaks at 2.7 GB, leaving 2.3 / 1.3 / 0.8 GB after 1 / 2 / 3 memory warnings, and decode slows to 41 / 35 / 29 tok/s. It's an optimistic bound: the phone keeps its full RAM for the model file.
   - **Our runtime** (`agello-next-20261024`), same phone, iOS 27.2, 2026-11-02, nominal thermal state throughout:
     - `calibrate`: first token 1.3 / 1.6 / 3.2 / 6.7 s (2.4× faster at 32K); decode 33 / 39 / 42 / 42 tok/s on the sentence (32K: 1.55×) and 71 / 66 / 67 / 62 on the list; peak footprint 1.1 / 1.3 / 1.9 / 3.5 GB. Decode hardly depends on the window any more. Watch: the list decodes 10–13% slower than Google's at 4K and 8K. The same run with the phone hot (thermal state serious, after the suites while charging) decoded 32–37 and 47–57 tok/s.
     - `memory`: every step passes at 5.0 / 4.0 / 3.5 GB; the app peaks at 2.5 GB (2.7 on Google's), leaving 4.6 / 1.5 / 1.05 GB at the lowest (the phone was hot: decode 38 / 32 / 30 tok/s).
4. **#3913 follow-up.** Run the next exports from the thread (above) through probe 20 and agello-bench. If a re-exported Google file or a runtime fix ships, check it with probe 10 and the `inference` suite, and the catalog can go back to Google's file (`agello-litert-update`, "When Google fixes #3913").

## Waiting for the iPhone

The phone is available (2026-11-02).

- **Manual checks:**
  - AirPods in voice mode and dictation;
  - a phone call during voice mode;
  - the voice camera in landscape;
  - the prompt before a cellular download.
- **Done on 2026-11-02:** the runtime gate for item 1, and the iPhone checks of the Mac work (M1–M3): the default suites with `ui`, `thinking`, `probes`, and `screenshots`. The tour matches October's README screenshots except Settings' rows, about 4 points narrower on each side: no list styling changed since, so it reads as iOS 27.2's list margins (a tour from the commit before M1 on the same phone would settle it).

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

- **Default context** on our build, now that its iPhone run is in: it decodes at nearly the same speed from 4K to 32K (42 tok/s on a sentence at 16K and 32K), but a bigger cache holds more memory (1.3 GB at 8K, 1.9 at 16K, 3.5 at 32K) and a long prompt still takes longer to read. Chat stays at 8K until the maintainer decides.
- **An iPhone 15 or 16 Pro** to validate our build before it ships to those devices.
- **For the Mac:** the sandbox, the App Group, the bundle ID, Sparkle updates, supported Macs, and the iPhone app's availability on the Mac App Store ([MAC.md](MAC.md), "Open decisions").
