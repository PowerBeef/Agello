# Agello overhaul — the best local alternative to the ChatGPT app

> [!IMPORTANT]
> **Archived plan, superseded.** Phases 0–5 have shipped; [README.md](../../README.md) describes the app as it is now. Kept for the reasoning behind its decisions and risks. Where the implementation differs:
>
> - **Models:** Gemma 4 E4B only; E2B and the model picker were dropped.
> - **Testing:** on the physical iPhone only, with no simulator (see [CLAUDE.md](../../CLAUDE.md)).
> - **Structure:** one app target organized in folders (`Inference/`, `Knowledge/`, `Voice/`…), not separate modules.
> - **Tools:** LiteRT-LM runs tool calls automatically while streaming, with app-side budgets, rather than an app-controlled tool loop.
> - **Web pages:** read with a built-in readable-text extractor, not `WebPage` plus Readability.js.
> - **First release:** moved after Phase 5.

Status at the time of writing: plan (not started). Base: `main` @ `ddedc83` — engine hardened and verified on iPhone 17 Pro (device harness green, 73 simulator tests).

## 1. Goal and positioning

**"ChatGPT's experience, without the cloud."** Free, private, offline-first, fast. Everything runs on Gemma 4 via LiteRT-LM on the phone; the network is used only to download models and, when the user enables it, to search and read the web.

We cannot match GPT-5.x on world knowledge and deep reasoning. We close the gap with web search, the user's own files, memory, E4B, thinking, and a much larger context than we use today.

## 2. Decisions

Confirmed:

| # | Decision |
| --- | --- |
| 1 | Web search: unofficial DuckDuckGo results by default, Wikipedia fallback, optional SearXNG / user-provided key |
| 2 | Models: LiteRT-LM + Gemma 4 family only (Gemma 4 E2B/E4B, EmbeddingGemma 2). No Apple Foundation Models, no Private Cloud Compute, no Image Playground |
| 3 | Vetted, permissively licensed Swift/JS packages allowed; licenses recorded in `NOTICE` |
| 4 | iPhone only, iPhone 15 Pro (A17 Pro, 8 GB) and later |

Assumptions to confirm before the phases that depend on them:

| Assumption | Rationale | Affects |
| --- | --- | --- |
| A. System frameworks that aren't language models are allowed: WebKit, PDFKit, VisionKit document scanner, Vision text recognition, AVSpeechSynthesizer | They have no Gemma/LiteRT equivalent (Gemma can't speak; LiteRT has no PDF/web stack) | Phases 2–4 |
| B. Speech-to-text uses Gemma's native audio input, not Apple's SpeechAnalyzer | Keeps "the model" 100% Gemma; Gemma 4 E2B/E4B transcribe and understand audio | Phase 4 |
| C. First release = Phases 0–3 + dictation | Biggest gap vs competitors with manageable risk | Release planning |
| D. Web search is opt-in: per-message toggle, plus an "automatic" setting that is off by default | Privacy is the core promise | Phase 3 |

## 3. Constraints

- **Devices:** iPhone 15 Pro, 15 Pro Max, and later (8 GB or more). Enforce with `UIRequiredDeviceCapabilities` → `iphone-performance-gaming-tier` (iOS 17+, "equivalent to iPhone 15 Pro") plus a runtime check of the app's memory limit. Deployment target stays iOS 27.
- **Memory:** the app limit with the increased-memory-limit entitlement was ~6.4 GB on a 12 GB iPhone 17 Pro. *(Superseded: the steady limit is about 8.6 GB (8 GiB); ~6.4 GB was an early reading.)* It must be **measured on an 8 GB device** (an iPhone 15 Pro or another 8 GB model) before choosing defaults. `DeviceProfile` already derives policy from the real limit.
- **LiteRT-LM on iOS:** GPU (Metal) and CPU backends only (no Neural Engine). v0.18.0 is the latest release (2026-10-06).
- **Background:** no GPU work in the background except via `BGContinuedProcessingTask` when `supportedResources` includes `.gpu`. Extensions can't load Gemma (memory), so they hand off to the app.
- **Gemma 4 E2B/E4B:** 128K context *(the trained model; the phone files export a 32K window)*, text + image + audio input, video as frames, function calling, thinking, 140+ languages, Apache 2.0. Outputs text only.

## 4. Model lineup (all LiteRT-LM)

| Model | Size | Role | Default on |
| --- | --- | --- | --- |
| Gemma 4 E2B | 2.6 GB | Fast chat, voice, helper tasks | All devices |
| Gemma 4 E4B | 3.7 GB | Quality chat, harder files and search | Devices whose app memory limit passes the gate (≥ 4.5 GB today; recalibrate on 8 GB) |
| EmbeddingGemma 2 text 270M | 165 MB | Search ranking, file retrieval, memory, chat search by meaning | Downloaded with the first chat model |
| EmbeddingGemma 2 text-vision 440M / 740M multimodal | 388 / 485 MB | Optional: search images and audio by meaning | Later, opt-in |

LiteRT-LM / Gemma 4 capabilities to adopt (currently unused):

- **Large context:** budget by measured memory instead of the fixed 4K (target 8–16K on 8 GB, 16–32K on 12 GB; determined by harness measurement).
- **JSON-schema constrained decoding** (`ResponseFormat`, `enableResponseFormat`) for structured helper outputs: search queries, memory facts, titles, citations.
- **App-controlled tool calls** (`automaticToolCalling: false`, tool-call streaming) so the UI can show "Searching…", ask for confirmation, and display sources.
- **Image detail up to 1,120 visual tokens** *(the trained model; the phone files accept at most 280)* for documents and screenshots on roomy devices; **video** as sampled frames.
- **Thinking** with a budget (now confirmed working on device); **MTP** speculative decoding.
- **EmbeddingGemma 2** Matryoshka truncation (e.g. 768 → 256 dims) to keep vector storage small.
- **LoRA hooks** reserved for later task adapters; **ModelInfo** for the model catalog.
- **Helper conversation:** a second small `Conversation` on the same `Engine`, run after the reply, for titles, memory extraction, and query rewriting (no second model in memory).

## 5. Target parity map

| ChatGPT | Agello target | Phase |
| --- | --- | --- |
| Streaming chat with rich markdown | Full markdown, code blocks (highlighted, copy), tables, LaTeX math | 1 |
| Model picker | E2B / E4B, with capability hints | 1 |
| Edit, regenerate, versions | Edit and resend, regenerate, ‹ 1/3 › version switcher (branches) | 1 |
| Copy, share, read aloud | Per-message actions; read aloud via system voices | 1 |
| Chat search | Text and by-meaning search over all chats | 1–2 |
| Custom instructions | Personalization: about you, response style, language | 1 |
| File uploads | PDF, text, Markdown, code, images, scanned pages, video clips | 2 |
| Projects | Folders with instructions and files, searched locally | 2 |
| Memory | Opt-in, visible, editable facts; retrieved by relevance | 2 |
| Web search with sources | Search toggle, page reading, numbered citations, source cards | 3 |
| Dictation | Mic in composer, transcribed by Gemma | 3 |
| Voice mode | Hands-free, interruptible conversation | 4 |
| Camera | Take photo, document scanner, ask about what the camera sees | 4 |
| Siri / Shortcuts / widgets | App Intents, Control Center, Action Button, widgets, Spotlight | 5 |
| Share sheet | "Ask Agello" share extension (hands off to app) | 5 |
| Image generation | **Out of scope** (Gemma outputs text only) | — |

## 6. Architecture

```text
App (SwiftUI, iPhone)  ── navigation, chat, composer, voice, projects, settings
   │
ChatCore      conversations · message parts · branches · agent/tool loop · citations · helper tasks
   ├── InferenceKit   Gemma engine actor (today's hardened LiteRTChatEngine) · context budget ·
   │                  lifecycle queue · helper conversation · constrained decoding
   ├── KnowledgeKit   EmbeddingGemma engine · ingestion (PDFKit, scanner, Vision OCR) ·
   │                  chunking · vector index (Accelerate) · memory · projects
   ├── WebSearchKit   providers (DDG HTML, Wikipedia, DDG Instant Answer, SearXNG, Brave/Tavily key) ·
   │                  WebPage + Readability.js reader · ranking · citation builder
   ├── VoiceKit       capture · voice activity detection · Gemma audio transcription ·
   │                  sentence streaming to AVSpeechSynthesizer · interruption
   └── ModelHub       catalog · background URLSession downloads · verification · device gating
Persistence: SwiftData with VersionedSchema (v1 = today's store, migrated) + vectors as compact blobs
```

Key designs:

1. **Message parts.** `Message { id, parentID, role, parts[], createdAt, stats }` where parts are text, image, audio, file reference, tool call, tool result, citation, thought. `parentID` makes branches; the active path through a branch is what gets replayed to the model.
2. **App-controlled tool loop.** Model → tool call (constrained JSON) → app runs the tool with visible status → tool result → model continues. Every step is bounded by `ContextBudget`. Tools: `web_search`, `open_url`, `search_files`, `recall_memory`, `calculate`, `current_date_time`.
3. **Context assembly.** Each turn's prompt is built from a budget: system instructions + personalization → relevant memories → project/file passages → web passages → the conversation (trimmed as today) → the new message. Each section has a token cap scaled to the device's context size.
4. **Helper tasks.** After a reply: title (first turn), memory candidates (if Memory is on), follow-up suggestions. Run in a small helper conversation with constrained JSON output; cancel if the user sends again.
5. **Vector index.** Embeddings stored as Float16 blobs in SwiftData; brute-force cosine search with Accelerate (fine for tens of thousands of chunks on one phone). No database dependency.
6. **Keep what works.** `ContextBudget`, engine validation, cancellation handling, lifecycle serialization, the device harness — all carried over unchanged.

## 7. Web search design

Flow (≈3–6 s network, ≈1 s prefill):

1. **Decide:** search toggle on, or automatic mode and the model emits a `web_search` call.
2. **Plan queries:** Gemma produces 1–3 queries (constrained JSON).
3. **Search:** provider chain with fallback and per-provider health tracking:
   1. DuckDuckGo HTML (`html.duckduckgo.com/html`) — default, unofficial; parse title/URL/snippet; keep DuckDuckGo attribution.
   2. Wikipedia / MediaWiki API — official, free; also used directly for encyclopedic questions.
   3. DuckDuckGo Instant Answer API — official, short abstracts.
   4. SearXNG — user-provided instance URL (JSON format).
   5. Brave / Tavily — user's own API key, stored in Keychain.
4. **Read:** fetch the top 3–5 pages in parallel with `WebPage` (ephemeral data store, JavaScript off first, on as fallback, strict timeouts), extract readable text with Readability.js (Apache 2.0).
5. **Rank:** chunk pages, embed with EmbeddingGemma 2, take the top passages that fit the web budget.
6. **Answer with citations:** numbered `[1]` markers mapped to source cards (favicon, title, domain); tapping opens Safari View Controller.

Privacy and reliability:

- Visible "Searching the web" state; only queries and page fetches leave the device; no conversation text is sent. Setting to disable web access entirely.
- Rate-limit and bot-challenge detection → automatic fallback, plus a clear message when all providers fail.
- **Before release:** review DuckDuckGo's terms for app use; keep the provider swappable.
- Test with recorded fixtures (offline, deterministic) plus a small live smoke test.

## 8. Files, projects, and memory

- **Ingestion:** PDFKit text for digital PDFs; VisionKit scanner + Vision text recognition for paper; Gemma vision for screenshots, charts, and handwriting; plain text, Markdown, and code files directly; video → sampled frames (1 fps, capped).
- **Retrieval:** chunk (~400 tokens with overlap), embed, store per file; at question time pull the top passages with page/section references for citations.
- **Projects:** a folder of chats sharing instructions and files; retrieval is scoped to the project.
- **Memory:** off by default. When on, the helper task proposes short facts; they are saved locally, listed in Settings, editable and deletable, and injected by relevance. "Forget this" and "temporary chat" modes.

## 9. Voice design

- **Dictation (first release):** record → Gemma audio input with a "transcribe exactly" instruction → text in the composer for review.
- **Voice mode (Phase 4):** full-screen view with a reactive orb.
  - Capture with `AVAudioSession` voice-chat mode (echo cancellation) and voice activity detection for turn ends.
  - The user's audio goes straight to Gemma (no separate transcription step), keeping latency low.
  - The reply streams sentence by sentence into AVSpeechSynthesizer (enhanced/premium voices offered in Settings).
  - Speaking over the model stops speech and cancels generation (uses the hardened stop path).
  - Target: under ~1.5 s to the first spoken word on iPhone 15 Pro-class devices.

## 10. UI redesign

- **Navigation:** single chat screen with a side drawer: New chat, Search, Projects, recent chats grouped by date; Settings at the bottom. Model picker in the title.
- **Composer:** `+` menu (Camera, Photos, Files, Scan document), Search and Think toggles, mic (dictation), voice-mode button; attachment chips with previews.
- **Messages:**
  - Assistant replies render full-width with rich markdown; user turns stay as bubbles.
  - Reasoning is collapsible; tool status lines appear while working; source cards follow web answers.
  - Actions: copy, read aloud, regenerate, edit, version switcher, share.
- **Onboarding:**
  - Device check → choose E2B or E4B, with a recommendation based on measured memory.
  - Background download that survives leaving the app, with a Live Activity.
  - A short tour while the download runs.
- **Settings:** Personalization, Memory, Models and storage, Web search, Voice, Data (export all chats, delete all), Advanced (today's performance and sampling options), About and licenses.
- Visual language stays native SwiftUI with Liquid Glass; Dynamic Type and VoiceOver throughout.

## 11. Roadmap

Every phase ends with simulator tests and the device harness green, and adds harness scenarios for its features.

| Phase | Deliverables | Exit criteria |
| --- | --- | --- |
| **0. Foundations** | Module split; SwiftData VersionedSchema v2 (message parts, branches) with migration from v1; app-controlled tool loop; helper conversation; constrained-JSON utility; device gating (`iphone-performance-gaming-tier`); context-size calibration in the harness | Existing chats migrate losslessly; per-device context defaults chosen from measurements; harness green |
| **1. Core experience** | New navigation, composer, message rendering (swift-markdown, code highlighting, LaTeX), message actions and branches, personalization, chat text search, onboarding with background downloads and Live Activity | New user chatting within the onboarding flow; UI tests for every message action |
| **2. Files, projects, memory** | Ingestion pipeline, EmbeddingGemma engine and vector index, Projects, Memory, search-by-meaning across chats | "Summarize this 40-page PDF" and follow-ups cite pages; memory is fully user-controlled |
| **3. Web + dictation** | Provider chain, page reader, ranking, citations, privacy controls; dictation via Gemma audio | Current-events questions answered with working citations; graceful offline/blocked behavior |
| **— First release —** | App icon, privacy manifest ("Data Not Collected"), App Store metadata, accessibility pass, performance/battery budgets | Ready for TestFlight |
| **4. Voice mode + camera** | Hands-free voice mode, interruption, camera capture and "ask about this view" | Latency target met; interruption reliable in UI tests |
| **5. System integration** | App Intents (Ask, New chat, Voice), App Shortcuts, Control Center, Action Button, widgets, Spotlight indexing of chats, share extension hand-off, `BGContinuedProcessingTask` for long file jobs where GPU is available | Each entry point covered by a test |

## 12. Testing and verification

- **Simulator:** unit tests for parsing, budgeting, ranking, migration, tool loop (mock engine + fixtures).
- **Device harness additions:** context-size calibration; long-PDF Q&A; memory recall; web search on recorded fixtures plus a live smoke test; dictation accuracy on synthesized speech; voice-mode round-trip latency; branch/regenerate flows in UI tests.
- **Hardware:** add an 8 GB iPhone (15 Pro or another 8 GB model) to the harness rotation before setting defaults.

## 13. Risks

| Risk | Mitigation |
| --- | --- |
| DuckDuckGo HTML changes or blocks requests | Provider chain with health checks; Wikipedia/SearXNG/own-key fallbacks; fixture tests catch parser breakage |
| 8 GB devices can't afford large contexts or E4B | Measure first; scale budgets from the runtime memory limit; E2B default |
| Small-model answer quality | Search, retrieval, E4B, thinking; prompts tuned with harness evals |
| Gemma audio transcription weaker than a dedicated speech model | Measure word error rate in the harness; revisit assumption B if needed |
| SwiftData migration of existing chats | VersionedSchema with a tested migration from today's store |
| App Store review of web scraping | Terms review before release; DuckDuckGo attribution kept; providers selectable in Settings so the default can be changed without redesign |

## 14. Open questions

1. Confirm assumptions A–D (section 2).
2. Monetization or distribution plans (free, one-time purchase, TestFlight only)?
3. Should exports (Markdown/PDF of chats) be in the first release?
