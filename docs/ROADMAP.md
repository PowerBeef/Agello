# Roadmap

What has shipped, what's next, and what waits for hardware. Updated 2026-10-16.

## Shipped

- **The app.** Chat, files, projects and memory, web search and dictation, voice mode with the camera, and system integration (Siri and Shortcuts, widgets, Control Center, Spotlight, the share sheet). The original plan is in [archive/agello-overhaul.md](archive/agello-overhaul.md).
- **Long-context digits ([#3913](ENGINEERING.md)).** Agello downloads a model file whose rotary positions are split into 512-token blocks. It copies digits exactly to 32K tokens on every GPU tested, M1-class Macs included.
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

## Waiting for the iPhone

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
