<div align="center">

# iRTChat

**A private AI assistant that runs entirely on your iPhone.**

iRTChat brings a ChatGPT-style experience to Google's Gemma 4, running locally through LiteRT-LM.<br>
No account, no API key, no cloud: after a one-time model download, every conversation stays on your phone.

![iOS 27](https://img.shields.io/badge/iOS-27-black?logo=apple)
![iPhone 15 Pro and later](https://img.shields.io/badge/iPhone-15%20Pro%20and%20later-black?logo=apple)
![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF)
![LiteRT-LM 0.18.0](https://img.shields.io/badge/LiteRT--LM-0.18.0-4285F4)
![Gemma 4 E4B](https://img.shields.io/badge/Model-Gemma%204%20E4B-8E75FF)
![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue)

</div>

---

## Contents

- [Features](#features)
- [A quick tour](#a-quick-tour)
- [Requirements](#requirements)
- [Getting started](#getting-started)
- [The model](#the-model)
- [Settings](#settings)
- [Architecture](#architecture)
- [Reliability](#reliability)
- [Performance](#performance)
- [Testing](#testing)
- [Project structure](#project-structure)
- [Roadmap](#roadmap)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)
- [Vendored LiteRT-LM](#vendored-litert-lm)
- [Contributing](#contributing)
- [License](#license)
- [Acknowledgements](#acknowledgements)

## Features

### Private by design

- **Fully on-device.** Gemma 4 E4B runs on the iPhone's GPU (Metal), with automatic CPU fallback. Chats, photos, and voice never leave the phone.
- **Works offline.** The network is used to download the models once, and for web searches you ask for. Searches send only the queries and page requests, never your conversation.
- **Local history.** Conversations are stored with SwiftData on the device, and each chat keeps its own context.

### Conversations

- **ChatGPT-style layout.** A single chat screen with a side drawer: chats grouped by date (Today, Yesterday, Previous 7 Days…), pinned chats on top, rename, and delete.
- **Search by words and by meaning.** Search finds chats by title and message text, plus **Related chats** by meaning (searching "Japan vacation" finds "Kyoto itinerary").
- **Projects.** Group chats with shared instructions and files; every chat in a project follows its instructions and can use its files.
- **Model-written titles.** After the first exchange, the model names the chat.
- **Clean new chats.** A new chat is saved only when you send its first message, so empty chats never pile up.

### Files

- **Attach documents:** PDFs, text, Markdown, code, CSV, JSON and RTF files, or scan paper with the camera. Scanned pages and image-only PDFs are read with on-device text recognition.
- **Ask about them.** Short files are read whole. For long ones, the most relevant passages are found by meaning and cited by page, like *(report.pdf, p. 23)*; each reply lists its sources.
- **Summarize long documents.** "Summarize this" on a long file reads it section by section once (with progress you can stop), then reuses that summary for later questions.

### Replies

- **Live streaming** with per-reply stats: time to first token, decode speed, and backend.
- **Rich markdown:** headings, nested and task lists, tables, block quotes, syntax-highlighted code blocks with a Copy button, and typeset math. Inline LaTeX is shown as readable text, and dollar amounts aren't mistaken for math.
- **Message actions:** copy, read aloud (in the reply's language), regenerate, edit and resend, share, and a ‹ 2/3 › switcher between versions. Editing or regenerating branches the conversation; earlier versions stay one tap away.

### Input

- **One composer** in the style of ChatGPT: the message on top; a `+` menu (Camera, Photos, Files, Scan document), the **Think** toggle, the microphone, and Send/Stop below. You can type your next message while a reply streams.
- **Vision:** take a photo or pick one from your library, with adjustable image detail.
- **Dictation:** tap the mic, speak, and Gemma transcribes your words into the composer for review (about a second for a sentence, in your language).
- **Voice messages:** send up to 30 seconds of audio that Gemma listens to directly.
- **Voice mode.** When the composer is empty, Send becomes a waveform button: a hands-free conversation with a live orb, captions, and an optional camera feed. Speak naturally and Gemma puts what you said into the chat and answers in short spoken sentences; talk over it, or tap the orb, to interrupt.

### Intelligence

- **Think.** Turn on step-by-step reasoning per message; the model's reasoning streams into a collapsible card above the answer.
- **Web search with sources.** Tap **Search** to look something up for one message: iRTChat searches (DuckDuckGo by default, with Wikipedia as a fallback, or your own SearXNG, Brave, or Tavily), reads the top pages, picks the relevant parts, and answers with `[1]`-style citations linked to the sources. Follow-up questions get their own queries. An optional automatic mode lets the model search when a question needs it.
- **On-device tools.** The model can check the current date and time and evaluate arithmetic, with a live status line while a tool runs.
- **Personalization.** Tell iRTChat your name, about yourself, how it should respond, and a response style (Default, Concise, Detailed, Friendly, Professional).
- **Memory (opt-in).** iRTChat can remember lasting facts you share ("Is vegetarian", "Lives in Montreal") and use them in new chats. Every memory is visible, editable, and deletable in Settings, and a reply that saved one says so.
- **Speculative decoding.** Multi-token prediction (MTP) roughly doubles decode speed when the model file includes a drafter.

### Native iOS

SwiftUI with Liquid Glass surfaces, haptics, VoiceOver labels, and accessibility identifiers throughout. Model downloads continue in the background, and a long document summary keeps running when you leave the app (background GPU, on iPhones that support it).

- **Siri and Shortcuts.** "Ask iRTChat", "New Chat", and "Talk to iRTChat" work from Siri, the Shortcuts app, the Action Button, and Spotlight.
- **Widgets and Control Center.** Home Screen and Lock Screen widgets ("Ask iRTChat", "Talk"), and Control Center controls for a new chat or a voice conversation.
- **Spotlight.** Your chats appear in system search (a toggle in Settings), and tapping a result opens that chat.
- **Share sheet.** "Ask iRTChat" from any app with text, a link, an image, or a file; iRTChat answers when the app opens next.
- **Links.** `irtchat://new`, `irtchat://ask?q=…`, and `irtchat://voice` work from anywhere on the system.

## A quick tour

| Where | What you can do |
| --- | --- |
| **First launch** | A welcome screen explains iRTChat and downloads Gemma 4 E4B (3.7 GB). You can leave the app while it downloads. |
| **Chat screen** | ☰ (or a swipe from the left edge) opens the drawer; the pencil starts a new chat; `⋯` renames or deletes the current chat. |
| **Composer** | `+` adds a photo, a file, a scanned document, or a voice message · **Think** turns reasoning on · **Search** searches the web · 🎙 dictates · ↑ sends, or the waveform starts voice mode when the composer is empty · ■ stops. |
| **Talk** | In voice mode, just speak: the answer arrives as text and speech. The camera button sends what you're looking at with your question. |
| **A reply** | Use the row under it to copy, read aloud, regenerate, or share; ‹ › switches between versions. |
| **Your message** | Long-press to copy or edit it; editing loads it back into the composer. |
| **Drawer** | Search all chats; open or create a project; long-press a chat to pin, rename, move to a project, or delete it; Settings sits at the bottom. |
| **A project** | Name, instructions, shared files, its chats, and "New chat in this project". |
| **Outside the app** | Siri ("Ask iRTChat…", "Talk to iRTChat"), the widgets, Control Center, Spotlight, or another app's share sheet ("Ask iRTChat"). |
| **Settings** | Personalization, Memory, Web search, Spotlight, the models, and advanced engine options (see [Settings](#settings)). |

## Requirements

| | |
| --- | --- |
| **iPhone** | iPhone 15 Pro or later (8 GB of memory or more), on iOS 27. The App Store requirement `iphone-performance-gaming-tier` enforces this. |
| **Storage** | About 4.4 GB free: the 3.7 GB chat model, the 165 MB search model, plus headroom |
| **Development** | A Mac with Xcode 27 and the iOS 27 SDK |
| **Signing** | An Apple Developer account with the **Extended Virtual Addressing**, **Increased Memory Limit**, **Background GPU Access**, and **App Groups** capabilities |
| **Network** | To download the models, and for web searches you ask for |

iRTChat runs on a physical iPhone only: the simulator has no Metal path for LiteRT-LM.

## Getting started

### Run on an iPhone

1. Open `iRTChat.xcodeproj`. Swift Package Manager resolves `swift-markdown` and `SwiftMath`; LiteRT-LM is vendored.
2. The project is configured for team `FK2D8X36G2` and bundle IDs `com.patricedery.irtchat`, `com.patricedery.irtchat.widgets` (widgets and controls) and `com.patricedery.irtchat.share` (share sheet), which share the App Group `group.com.patricedery.irtchat`. On another account, change the team and the bundle IDs under **Signing & Capabilities**.
3. Select the `iRTChat` scheme and your iPhone, then run. Use the **Release** configuration for representative speed.
4. On the welcome screen, download **Gemma 4 E4B**. The download continues if you leave the app.
5. Start chatting.

> [!NOTE]
> Automatic signing registers the required capabilities from `iRTChat/iRTChat.entitlements`. If signing fails with *"PLA Update available"*, accept the latest Program License Agreement at [developer.apple.com/account](https://developer.apple.com/account).

### Try the interface without a model

Run the `iRTChat` scheme with the `--mock-engine` launch argument (**Product → Scheme → Edit Scheme → Run → Arguments**). A scripted engine drives the whole interface without downloading a model: streaming, reasoning (when Think is on), titles, regenerate, and edit. A prompt containing "markdown" returns a rich sample with code, a table, and math.

## The model

iRTChat chats with **Gemma 4 E4B** (text, vision, audio, reasoning, and tool calling in one file) and searches by meaning with **EmbeddingGemma**.

| Model | Size | Role | License |
| --- | --- | --- | --- |
| **Gemma 4 E4B** | 3.7 GB | Chat. Context: 8K tokens for chat; up to 16K or 32K for long inputs, depending on the device's memory | Apache 2.0 |
| **EmbeddingGemma 2** (text, 270M) | 165 MB | Turns passages and chats into 256-dimension vectors for retrieval and search by meaning. Downloads automatically after the chat model; keyword search fills in until then | Apache 2.0 |

- **Source.** The `.litertlm` builds from Hugging Face ([`litert-community`](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm)), downloaded at runtime without an account. It is not included in this repository.
- **Downloads** run in a background `URLSession`, so they continue while the app is in the background and resume after the app is relaunched. They support pause and resume, check free space first, and are verified by HTTP status and file size. The model is stored in Application Support and excluded from iCloud backup.
- **Context policy.** A larger KV cache slows every reply, so chat uses 8K tokens; only long inputs get more (32K when the app may use at least 6.5 GB, otherwise 16K).
- **The 8 GB floor.** E4B was validated for the iPhone 15 Pro with an 8 GB memory simulation: incompressible ballast shrank usable memory to 5.0, 4.0, and 3.5 GB, and text, image, audio, and 16K-token inputs all completed without the app being terminated. Speed on A17 Pro hardware is not yet measured.
- **Earlier versions.** Chats created with Gemma 4 E2B continue on E4B, and the old E2B file is deleted automatically.

## Settings

Settings opens from the bottom of the drawer.

| Section | Options |
| --- | --- |
| **Personalization** | Name · about you · how to respond · response style. Stored separately and added to the system prompt. |
| **Memory** | On or off (off by default) · review, edit, add, or delete memories · delete all |
| **Web search** | Allow web search · search automatically (off by default) · provider: DuckDuckGo, Wikipedia, SearXNG (your instance), Brave or Tavily (your API key, kept in the Keychain) |
| **Spotlight** | Show chats in system search (on by default) |
| **Models** | Download, pause, resume, or delete Gemma 4 E4B and EmbeddingGemma |
| **Performance** | GPU or CPU backend · speculative decoding (MTP) · compact reasoning cache (keeps reasoning out of the KV cache, for a longer effective context) |
| **Reasoning & Memory** | Thinking on or off, and its token budget · automatic or manual KV-cache size |
| **Sampling** | Precise (temperature 0.2) · Balanced (0.7) · Creative (1.0) |
| **Voice & Vision** | Image and audio input · image detail (140 / 280 / 560 visual tokens) |
| **System Prompt** | The base instructions for every conversation |
| **Benchmark** | A 1,024-token prefill and 256-token decode run, comparable to Google's published numbers |
| **Tools** | Turn the on-device tools on or off |

## Architecture

```text
┌──────────────────────────────── SwiftUI ─────────────────────────────────┐
│ ContentView ── DrawerView (search, projects, recency groups)             │
│   ├─ ChatView ── MessageBubbleView ── MarkdownView (code, tables, math)  │
│   │    └─ composer (+, Think, Search, mic)     Settings · Project        │
│   └─ VoiceModeView (orb, captions, camera)     Memory · Onboarding       │
└─────────────────────────────────────┬────────────────────────────────────┘
                                      ▼
                    AppState  (@MainActor, @Observable)
   engine lifecycle queue · chat ↔ conversation binding · send / regenerate /
   edit · files, web, memory · system prompt · precision switch · streaming
        │                       │                        │
        │           KnowledgeBase ── EmbeddingGemma     │   AppRouter (Siri,
        │           files → passages → vectors          │   Shortcuts, widgets,
        │           chat vectors (search by meaning)    │   Spotlight, links)
        ▼                       ▼                        ▼
   LiteRTChatEngine   SwiftData (versioned schema)   VoiceSession (mic, VAD,
   load ladder        ChatThread ─ ChatTurn tree     speech, camera)
   validation         parentID branches, active leaf BackgroundWork
   context budget
        │
        ▼
     LiteRT-LM  Engine + Conversation  ──▶  Metal GPU / CPU
```

| Component | Responsibility |
| --- | --- |
| `AppState` | Runs every engine operation (load, settings change, benchmark, delete) one at a time; binds the native conversation to the open chat; drives send, regenerate, and edit through one generation path; publishes streamed text at about 10 Hz. |
| `LiteRTChatEngine` | The single owner of a LiteRT-LM `Engine` and `Conversation`. Loads through a GPU → CPU, multimodal → text-only ladder, validates each engine, keeps every request inside the KV cache, and runs JSON-constrained helper prompts. |
| `InferencePlanner` | Pure, tested resolution of user options and device memory into backend, KV-cache size, sampler, thinking budget, visual-token budget, and MTP. Decides when a settings change needs an engine rebuild. |
| `ContextBudget` | Pure, tested KV-cache arithmetic: token estimates, a preamble sized to the actual system prompt, history trimming, and reply caps. |
| `ToolHost` | Tool budgets (share of the remaining context, maximum calls) and the live tool status shown while a reply streams. |
| Chat history | A SwiftData `VersionedSchema` with a migration plan. Turns form a tree (`parentID`), and the thread's active leaf selects the visible branch, which is what makes edit, regenerate, and version switching possible. |
| `MarkdownDocument` | Pure, tested parsing (swift-markdown) into typed blocks, with display math split out and inline LaTeX converted to Unicode; `MarkdownView` renders it and typesets math with SwiftMath. |
| `KnowledgeBase` | Stores attached files as page-aware passages, indexes them (and chats) with EmbeddingGemma in the background, and finds relevant passages and related chats. |
| `DocumentIngestor`, `Chunker` | Pure, tested file reading (PDFKit, Vision text recognition, text formats) and splitting into ~400-token passages that keep their page numbers. |
| `FileContext` | Pure, tested choice of what the model reads: whole files, cited excerpts, or a cached section-by-section summary, within half the context window. |
| `SystemPrompt` | Base prompt, personalization, memories, and project instructions, composed; any change rebuilds the conversation before the next message. |
| `WebResearch` | Provider chain with fallback (bot-check and rate-limit detection), parallel page reading with a built-in readable-text extractor, passage ranking with EmbeddingGemma, and numbered sources; `WebSearchTool` exposes it to the model in automatic mode. |
| `Dictation` | Transcription through Gemma's audio input in a throwaway conversation, with greedy decoding. |
| `VoiceSession` | Hands-free conversation: microphone with voice-activity turn detection, one audio engine for both capture (echo-cancelled) and sentence-by-sentence speech, barge-in, and the camera frame attached to each utterance. |
| `AppRouter`, App Intents | "Ask iRTChat", "New Chat", "Talk to iRTChat", widgets, Control Center, Spotlight, and `irtchat://` links all hand off to the app, which does the work in the foreground (extensions can't load the model). |
| `BackgroundWork` | A continued processing task around long document summaries: the reply keeps running (background GPU, where the device supports it), with iOS showing progress in a Live Activity that can cancel it. |
| `ShareInbox`, `SpotlightIndex` | Items shared from other apps wait in an App Group inbox for the app to answer; chats are indexed for system search. |
| `ModelStore` | Background model downloads, verification, and storage. |
| `DeviceProfile` | Device memory policy, based on the app's real memory limit. |

## Reliability

These safeguards come from failures reproduced on device by the test harness.

- **Context window.** Overflowing the KV cache corrupts LiteRT-LM's native heap and crashes the app. Every send measures the tokens already cached and estimates the new message, calibrated against exact runtime counts. When needed, it trims older turns (truncating the latest reply rather than dropping it) and caps the reply to the remaining room. The preamble estimate includes the full system prompt, personalization included. A message that can never fit is rejected with an explanation.
- **Branching.** Regenerate and edit rebuild the model's context from the history *before* the changed turn, so abandoned versions never leak into the next answer. Switching versions rebuilds the context on the next message.
- **Engine validation.** LiteRT-LM can report a successful load after failing to map parts of the model file. Each new engine must complete a one-token generation before the app uses it.
- **Stop and resume.** A cancelled LiteRT-LM conversation rejects the next message. Stopped replies keep their partial text, and the chat's conversation is rebuilt from history before the next send.
- **Background.** A reply in progress normally stops cleanly when the app leaves the foreground, since iOS doesn't allow GPU work in the background. Long file summaries are the exception: they run as a continued processing task (background GPU, where the device supports it), keep going when you leave the app, and show their progress in a Live Activity that can cancel them.
- **Memory.** The memory entitlements raise the app's limit to about 8.6 GB on a 12 GB iPhone 17 Pro and prevent address-space exhaustion when engines are rebuilt. A reply stops only when available memory falls below 400 MB, not at the first memory warning.
- **Capability flags.** The model file's *thinking* and *function-calling* flags are not trusted: Gemma 4 files report both as unsupported, yet the model reasons and calls tools on device.
- **Tool budgets.** LiteRT-LM runs tools automatically while streaming, so each generation round gets a share of the remaining context. A streaming guard ends a reply cleanly before it can overflow the window.
- **GPU precision.** With default 16-bit activations, the GPU duplicated digits once the context reached a few thousand tokens ("March 2026" became "March 202026"); the CPU and 32-bit activations were correct ([LiteRT-LM #3913](https://github.com/google-ai-edge/LiteRT-LM/issues/3913)). iRTChat switches to 32-bit activations from about 2,500 context tokens (back below 1,500), keeping short chats at full speed; the stats footer shows `GPU·FP32` in that mode.
- **Structured helpers.** Titles and memories use JSON-schema constrained decoding with speculative decoding off (MTP corrupts the grammar mask on device), in a throwaway conversation. The chat is then rebuilt from history, since LiteRT-LM keeps one live conversation per engine.
- **Settings take effect immediately.** A setting changed just before sending (like **Think**) is applied before that message, not after it.

## Performance

Gemma 4 E4B measured on an iPhone 17 Pro (12 GB, iOS 27), GPU, with MTP enabled.

| Metric | Gemma 4 E4B |
| --- | --- |
| Load (first after download / warm) | ~9 s / ~1–3 s |
| Time to first token, short message | ~0.4 s |
| Time to first token, 2.3K / 4.4K / 8.6K-token input | 2.1 s / 6.0 s / 18.9 s |
| Decode, chat at 4K / 8K / 16K / 32K context | 43 / 38 / 34 / 27 tok/s |
| Decode, long reasoning answers (1,000+ tokens) | ~22 tok/s |
| Chat title, after the first reply | ~2–3 s |
| Index a 40-page PDF (20 passages) / search it | 1.7 s / 15 ms |
| "Summarize this report" (40 pages, first time / again) | 31 s / 13 s |
| Cited follow-up question on the same report | 11 s (includes the switch to 32-bit precision) |
| Long context in 32-bit precision | about half the decode speed |
| Memory extraction after a personal message | ~2.2 s |
| Web search answer (search, read 5 pages, rank, answer) | ~25 s |
| Dictation of a spoken sentence | ~1 s (word error rate 0–0.13 in English and French) |
| Voice mode: first spoken sentence, after you stop talking | ~1.2–1.5 s (transcript included) |
| App memory footprint (8K context, with vision and audio) | ~1.4–2.5 GB |

For reference, Google reports 1,189 prefill and 25 decode tokens per second for E4B on the iPhone 17 Pro GPU without speculative decoding.

## Testing

| Target | Runs on | Covers |
| --- | --- | --- |
| `iRTChatTests` (204 tests) | iPhone | Planner, context budgeting, precision switching, schema migration and branching, regenerate / edit / versions, markdown, file reading and chunking, retrieval and citations, summaries, projects, memory, web parsers and page extraction (recorded fixtures), citations, dictation, voice text and voice-activity detection, deep links and intents, Spotlight entries, the share inbox, chat grouping and search, personalization, titles, downloads, and the app pipeline through the scripted engine |
| `iRTChatDeviceTests` (39 scenarios) | iPhone | The real models in-process: download, load, text, chat isolation, stop and continue, tools, thinking, image, audio, settings rebuilds, context limits, titles, memory, dictation accuracy, voice turns (transcript and spoken answer), benchmark; files (EmbeddingGemma indexing, "summarize this 40-page PDF", cited follow-up, search chats by meaning); live web search (cited answer, planned follow-up, automatic mode). Opt-in suites: long Thinking, 8 GB memory simulation, context calibration, and LiteRT-LM probes. |
| `iRTChatUITests` (20 flows) | iPhone | Real taps: send, Stop, Home button mid-reply, leaving and returning mid-reply, rapid settings changes, drawer and search, pin / rename / delete, projects, attached files, web search, dictation, voice mode, deep links, a long summary while the app is in the background, regenerate / edit / versions, Think, memory settings, markdown, keyboard clearance, Models |

All suites run on a connected, unlocked iPhone through the harness (it downloads E4B and EmbeddingGemma if missing). The simulator isn't used.

The harness targets the `deviceId` in `.mobilebuildmcp/config.yaml`, a local, git-ignored file. Create it once from the template and set your iPhone's UDID (from `xcrun devicectl list devices`), or pass `DEVICE_ID=<udid>` per run:

```sh
cp .mobilebuildmcp/config.example.yaml .mobilebuildmcp/config.yaml
```

```sh
scripts/device-harness.sh unit        # unit tests
scripts/device-harness.sh inference   # engine scenarios
scripts/device-harness.sh files       # files and search with the real models
scripts/device-harness.sh web         # live web search (needs internet)
scripts/device-harness.sh ui          # real-tap UI flows
scripts/device-harness.sh all         # unit, inference + files + web, then UI
scripts/device-harness.sh thinking    # long Thinking-mode scenarios, compact reasoning cache
scripts/device-harness.sh memory      # 8 GB iPhone memory simulation
scripts/device-harness.sh calibrate   # speed and memory at 4K–32K context
scripts/device-harness.sh probes      # LiteRT-LM feature probes

DEVICE_ID=<udid> scripts/device-harness.sh all   # a specific iPhone
```

Results are written to `build/device-harness/`: result bundles, the raw `xcodebuild` log of each suite (`<suite>.log`), per-scenario JSON metrics and screenshots, and `harness-report.json` pulled from the device. Console output goes through Homebrew's [xcbeautify](https://github.com/cpisciotta/xcbeautify) when it's installed (`brew install xcbeautify`); set `XCBEAUTIFY=off` for raw output, or `XCBEAUTIFY=<path>` to use another copy. The app logs under the subsystem `com.patricedery.irtchat` with the categories `engine`, `generation`, and `lifecycle`.

[MobileBuildMCP](https://github.com/getsentry/xcodebuildmcp.com) reads the same `.mobilebuildmcp/config.yaml` for project defaults, including a `device-tests` profile.

## Project structure

```text
iRTChat/
├── iRTChatApp.swift          App entry, SwiftData container, background-download hook
├── AppState.swift            Engine lifecycle, chat binding, generation pipeline
├── Info.plist                URL scheme (irtchat://), background task identifiers
├── iRTChat.entitlements      Extended virtual addressing, memory limit, background
│                             GPU, App Group (with the share sheet)
├── Inference/                Engine actor, planner, context budget, device policy,
│                             tools, title and memory helpers, personalization
├── Knowledge/                File reading, chunking, embeddings, vector index,
│                             knowledge base, file context, web parsers and research
├── Markdown/                 Markdown parsing, code highlighting, rendering
├── ModelHub/                 Model catalog and background download store
├── Persistence/              Versioned SwiftData schema, branching, store loading
├── System/                   App Intents, deep links and router, Spotlight,
│                             share inbox, continued processing tasks
├── Voice/                    Voice mode: capture and speech, turn detection,
│                             camera feed, voice text
├── Views/                    Chat, drawer, composer, message actions, projects,
│                             memory, settings, personalization, onboarding,
│                             camera, scanner, voice mode, speech
└── Support/                  Design tokens, haptics, image preparation, diagnostics
iRTChatWidgets/               Widget extension: Home/Lock Screen widgets and
                              Control Center controls
iRTChatShare/                 Share extension: "Ask iRTChat"
iRTChatTests/                 Unit tests
iRTChatDeviceTests/           On-device engine scenarios
iRTChatUITests/               UI flows
scripts/device-harness.sh     On-device test runner
Vendor/LiteRT-LM/             LiteRT-LM v0.18.0 Swift package
```

## Roadmap

| Phase | Scope | Status |
| --- | --- | --- |
| **0. Foundations** | Versioned schema with branches, tool budgets, model-written titles, calibrated context sizes | Done |
| **1. Core experience** | Drawer navigation, rich markdown, message actions, composer, personalization, onboarding, background downloads | Done |
| **2. Files, projects, memory** | Attach PDFs and documents, scan with the camera, cited answers and summaries, projects with shared files and instructions, pinned chats, memory, search by meaning with EmbeddingGemma | Done |
| **3. Web and voice** | Opt-in web search (per message or automatic) with cited sources, and dictation through Gemma's audio input | Done |
| **4. Voice mode and camera** | Hands-free, interruptible voice conversations; ask about what the camera sees | Done |
| **5. System integration** | Siri and Shortcuts, Control Center, Action Button, widgets, Spotlight, share sheet, background file jobs | Done |
| **First release** | App icon, privacy manifest, App Store metadata, accessibility pass, performance and battery budgets | Next |

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Signing error *"PLA Update available"* | Accept the latest Program License Agreement at [developer.apple.com/account](https://developer.apple.com/account). |
| *"Failed to create a bundle instance … iRTChatDeviceTests.xctest"* | The iPhone has an install from before that target existed. Run `xcrun devicectl device uninstall app --device <udid> com.patricedery.irtchat` and retry. This also removes downloaded models. |
| UI tests fail with *"Timed out while enabling automation mode"* | Unlock the iPhone and keep it unlocked during the run. |
| The download stopped | Tap **Resume** in **Settings → Models**. Downloads continue in the background, but force-quitting the app cancels them. |
| *"Older messages were dropped from the model's memory"* | Expected in long chats. Raise the KV-cache size under **Settings → Reasoning & Memory**, or start a new chat. |
| *"Web search failed … Answered without it"* | Offline, or the provider refused (rate limit). Try again, or choose another provider in **Settings → Web search**. |
| UI tests stall on a system alert | XCTest can't answer system permission prompts on device; the tests use `--uitest-fake-mic` and the scripted engine where needed. |

## Known limitations

- Force-quitting the app (swiping it away) cancels a model download, as iOS does for all background downloads.
- When you switch chats, only text history is replayed to the model, not images or audio.
- Voice recordings are not stored. They are marked in the chat, and replies to voice-only messages can't be regenerated.
- LiteRT-LM's Swift API does not yet support saving and restoring KV sessions, so reopening a long chat replays its history.
- Up to 60 pages per file are read with text recognition; the 25 most recent memories are used in chats.
- Search by meaning needs at least three chats; with fewer, search matches words only.
- Web pages are read without running JavaScript, so pages that build their content with scripts contribute only their search snippet.
- DuckDuckGo results come from its HTML page (an unofficial interface); if it asks for a bot check, searches fall back to Wikipedia, or use your own SearXNG, Brave, or Tavily.
- Only long document summaries keep running when you leave the app, and only on iPhones that support background GPU use; other replies stop, as before.
- Something shared to iRTChat is answered in a new chat the next time the app opens, not inside the share sheet.

## Vendored LiteRT-LM

`Vendor/LiteRT-LM` contains the Swift package surface of [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) at v0.18.0. The upstream repository stores prebuilt binaries in Git LFS, whose endpoint intermittently fails during Swift Package Manager resolution. The iOS build uses only the checksummed release XCFramework, so vendoring the Swift sources changes no behavior.

To update to a newer release:

```sh
TAG=v0.19.0 ./Vendor/refresh-litert-lm.sh
```

Then update the tag in `Vendor/README.md` and run the test suites.

## Contributing

Work happens directly on `main`. Keep the unit tests and the on-device harness green, keep the interface native, and record any new dependency's license in [NOTICE](NOTICE).

## License

iRTChat is licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) for attribution of the third-party components it uses and downloads:

| Component | Distribution | License |
| --- | --- | --- |
| iRTChat source code | This repository | Apache 2.0 |
| LiteRT-LM | Vendored in `Vendor/LiteRT-LM` | Apache 2.0 |
| swift-markdown | Swift package | Apache 2.0 |
| swift-cmark | Swift package (via swift-markdown) | BSD 2-Clause |
| SwiftMath | Swift package | MIT |
| Gemma 4 E4B | Downloaded at runtime | Apache 2.0 |

## Acknowledgements

- [LiteRT](https://github.com/google-ai-edge/litert) and [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM) by Google (Apache 2.0)
- [LiteRT-LM Swift guide](https://developers.google.com/edge/litert-lm/swift)
- [Gemma 4 on LiteRT-LM](https://developers.google.com/edge/litert-lm/models/gemma-4)
- [Gemma 4 E4B](https://huggingface.co/google/gemma-4-E4B-it) by Google, with the [LiteRT-LM build](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm) by `litert-community` (Apache 2.0)
- [swift-markdown](https://github.com/swiftlang/swift-markdown) by the Swift project, and [SwiftMath](https://github.com/mgriebling/SwiftMath) by Computer Inspirations
