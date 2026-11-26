# User guide

Everything Agello can do, where to find it, and what to do when something goes wrong.

- [A quick tour](#a-quick-tour)
- [Settings](#settings)
- [Outside the app](#outside-the-app)
- [The models](#the-models)
- [Troubleshooting](#troubleshooting)
- [Known limitations](#known-limitations)

## A quick tour

| Where | What you can do |
| --- | --- |
| **First launch** | A welcome screen explains Agello and downloads Gemma 4 E4B (3.7 GB). You can leave the app while it downloads. |
| **Chat screen** | ☰ (or a swipe from the left edge) opens the drawer; the pencil starts a new chat; `⋯` renames or deletes the current chat. A new chat is saved only when you send its first message. |
| **Composer** | `+` adds a photo, a file, a scanned document, a voice message, or **Paste** (explicit system `PasteButton`) · **Think** turns reasoning on (the screen glows lavender) · **Search** lets Agello research the web when your message needs it (teal): the facts for a question, or the techniques and documentation for something to write or build. Greetings, small talk, and work on text you've given (rewrite, translate, summarize) are answered without searching · 🎙 dictates · ↑ sends, or the waveform starts voice mode when the composer is empty · ■ stops. You can type your next message while a reply streams. |
| **Talk** | In voice mode, just speak: the answer arrives as text and speech. Talk over it, or tap the orb, to interrupt. The camera button sends what you're looking at with your question. When a personal action needs approval, voice mode pauses barge-in and shows the confirmation card inline. |
| **A reply** | Use the row under it to copy, read aloud, regenerate, or share; ‹ › switches between versions. Replies that use tools can include interactive **Action Cards** — Apple Maps places (with Look Around and Directions), Weather forecasts and alerts, Calendar events, Reminders (with inline Complete, **Snooze +1h**, and **Tomorrow 9 AM**), Contacts, native SMS/Email Drafts, live Alarm/Timer countdowns (Pause/Resume/Cancel), and Shortcut Handoffs. |
| **Your message** | Long-press to copy or edit it; editing loads it back into the composer and branches the conversation. |
| **Drawer** | Chats grouped by date with pinned chats on top. Search all chats by words, plus **Related chats** by meaning ("Japan vacation" finds "Kyoto itinerary"). Long-press a chat to pin, rename, move to a project, or delete it; Settings sits at the bottom. |
| **A project** | Name, instructions, shared files, **Link folder** & **Sync** (link a local or iCloud Drive folder once via security-scoped bookmark and re-sync supported documents on tap), its chats, and "New chat in this project". Every chat in a project follows its instructions and can use its files. |
| **Files** | PDFs, text, Markdown, code, CSV, JSON and RTF, or scanned paper. Short files are read whole; long ones are searched by meaning and cited by page. "Summarize this" reads a long file section by section once, then reuses the summary. |

## Settings

Settings opens from the bottom of the drawer. The card on top shows the model and whether it's ready. How the model runs (its speed settings, its reasoning budget, image detail) isn't a setting: Agello chooses.

| Section | Options |
| --- | --- |
| **Personalization** | Name · about you · how to respond · response style (Default, Concise, Detailed, Friendly, Professional). Added to the system prompt. |
| **Memory** | On or off (off by default) · review, edit, add, or delete memories · delete all. A reply that saved a memory says so. |
| **Web search** | Allow web search · search automatically (off by default) · provider: Wikipedia, or SearXNG (your instance) |
| **Spotlight** | Show chats, projects, and attached documents in system search (on by default) |
| **Shortcuts** | Native Apple **Shortcuts** link (`ShortcutsLink`) opening Agello's actions in the Shortcuts app |
| **Models** | Download, pause, resume, or delete Gemma 4 E4B and EmbeddingGemma 2 |
| **On-device tools** | Turn the offline tools (date and time, calculator, unit converter, file & past-chat search, document page inspection, CSV/TSV/JSON table queries) on or off |
| **Personal tools** | Opt-in access across **7 toggles** (all off by default): **Calendar**, **Reminders**, **Contacts**, **Maps & Places**, **Weather**, **Alarms & Timers**, and **Photos (OCR)**. Creating, updating, completing, or deleting events, reminders, message drafts, timers, or alarms always shows an in-chat confirmation card first (red destructive card for deletes; multi-step plan card when several actions are proposed together). |
| **Automations & Shortcuts** | Allowlist specific Apple Shortcuts Agello can propose running (with curated starter templates for Apple Notes, Apple Home, Expense logging, and Focus Music) and launch 1-tap multi-step **Recipes** (*Morning Briefing*, *After-Meeting Wrap-Up*, *Commute & Nearby Check*, or your own custom recipes). Every Shortcut run requires explicit external confirmation before leaving Agello. |
| **Help** | Share diagnostics: the system's crash and performance reports and the app's log of the last hour, kept on the iPhone until you share them |

## Outside the app

- **Siri and Shortcuts.** Launch shortcuts (*"Ask Agello"*, *"New Chat"*, *"Talk to Agello"*, *"Snap & Ask Agello"*, *"Voice with Camera"*) plus composable Shortcuts actions: **"Search Agello Files"** (runs privately in the background on the Apple Neural Engine without opening the app), **"Ask Agello (Return Text)"**, **"Summarize Document with Agello"**, **"Extract Structured Data with Agello"** (strict JSON output), and **"Run Agello Recipe"**. All intents require unlocking your iPhone first.
- **Focus Filters.** In iOS **Settings → Focus**, add an **Agello Focus Filter** to automatically hide personal tools or choose a default project while a Focus mode is active.
- **Widgets, Control Center, and Live Activities.** Home Screen and Lock Screen widgets ("Ask Agello", "Talk", "Snap & Ask"), Control Center controls for a new chat, camera, or voice conversation, and Lock Screen / Dynamic Island **Live Activities** for long multi-document synthesis, web research, multi-step Think tool loops, and active **Alarms & Timers**.
- **Spotlight.** Your chats, projects, and attached documents appear in system search (a toggle in Settings), and tapping a result opens it in Agello.
- **Share sheet.** "Ask Agello" from any app with text, a link, an image, or a file; Agello answers when the app opens next.
- **Links.** `agello://new`, `agello://ask?q=…`, `agello://voice`, `agello://camera`, `agello://voice-camera`, and `agello://recipe/<id>` work from anywhere on the system.

## The models

| Model | Size | Role | License |
| --- | --- | --- | --- |
| **Gemma 4 E4B** | 3.7 GB | Chat: text, vision, audio, reasoning, and tool calling in one file. Context: 64K tokens (65,536), less when the iPhone is short of memory as the model loads | Apache 2.0 |
| **EmbeddingGemma 2** (text, 270M) | 128 MB | Turns passages, chats and memories into 768-dimension vectors on the Apple Neural Engine for retrieval and search by meaning. Downloads automatically after the chat model; keyword search fills in until then | Apache 2.0 |

- **Source.** Downloaded at runtime from Hugging Face, without an account. EmbeddingGemma 2 is a 4-bucket asymmetric INT4 Core AI Apple Neural Engine conversion of [`litert-community`'s build](https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm) ([`PowerBeef02/embeddinggemma-2-text-270m-coreai-ane`](https://huggingface.co/PowerBeef02/embeddinggemma-2-text-270m-coreai-ane), Apache 2.0). The chat model is [`litert-community`'s Gemma 4 E4B build](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm) with graph-only edits (`gemma-4-E4B-it-agello-v2.litertlm`: 1,536-slot local KV rings, 128K shared Dual-`GATHER` float16-exact rotary tables, and `verify_8`, with the same weights; [`PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope`](https://huggingface.co/PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope), see [the engineering notes](ENGINEERING.md#long-context-digits-on-the-gpu-litert-lm-3913)). Both downloads are pinned to a commit.
- **Downloads** run in a background `URLSession`: they continue while the app is in the background, resume after a relaunch, support pause and resume, check free space first, and are verified by HTTP status, file size and SHA-256 checksum. Models are stored in Application Support and excluded from iCloud backup. On a cellular or other metered network, or in Low Data Mode, a download over 200 MB (Gemma 4 E4B) asks first: **Download now**, or **Wait for Wi-Fi**.
- **Earlier versions.** Chats created with Gemma 4 E2B continue on E4B. Older model files (E2B, and the unpatched E4B) are deleted automatically, and the current file downloads once.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| The download stopped | Tap **Resume** in **Settings → Models**. Downloads continue in the background, but force-quitting the app cancels them. |
| *"Older messages were dropped from the model's memory"* | Expected in very long chats: the oldest turns make room for new ones (Agello recalls relevant details from evicted turns automatically when possible). Start a new chat to begin fresh. |
| *"This message is too long for the model's memory"* | The message alone doesn't fit the model's memory (about 56,000–60,000 tokens at 64K; about 11,000 tokens when the iPhone is short of memory as the model loads, and about 5,000 when it's very short of it). Attach the text as a file instead. |
| *"Web search failed … Answered without it"* | Offline, or the provider refused (rate limit). Try again, or choose another provider in **Settings → Web search**. |
| *"Waiting for Shortcut…"* after returning from Apple Shortcuts | Tap **Continue** on the banner if the Shortcut finished without returning output (or wait for the 120-second callback window to close). |

## Known limitations

- Force-quitting the app (swiping it away) cancels a model download, as iOS does for all background downloads.
- When you switch chats, only text history is replayed to the model, not images or audio.
- Voice recordings are not stored. They are marked in the chat, and replies to voice-only messages can't be regenerated.
- LiteRT-LM's Swift API does not yet support saving and restoring KV sessions, so reopening a long chat replays its history.
- Up to 60 pages per file are read with text recognition; up to 25 memories are used per chat (**10 most recent + 15 closest in meaning**).
- Search by meaning needs at least three chats; with fewer, search matches words only.
- Web pages are read without running JavaScript, so pages that build their content with scripts contribute only their search snippet.
- Search uses only sources whose terms allow an app like Agello, chosen by what you ask: Wikipedia and Wikidata for most questions, Wikivoyage for travel, Wiktionary for words, Wikiquote for quotations, Apple Weather and Apple Maps for weather and places (with your location for "near me" and "the nearest…", after you allow it; Apple Maps doesn't share opening hours with apps, so the reply links the place in Apple Maps, which shows them), the European Central Bank for exchange rates, Crossref and PubMed for studies, and Wikipedia's Current events for the last few days. General web search engines are not among them (none allows it for free), so product pages, forums and most news sites aren't searched. Opt-in **Weather** and **Maps & Places** personal tools also query Apple Weather and Apple Maps directly even when Web Search is off.
- Long document or multi-document synthesis, web research, and multi-step Think tool chains can continue in the background as a Live Activity (`BGContinuedProcessingTask`) where the iPhone supports background GPU/inference work (including iPhone 17 Pro on iOS 27). Plain text chat stops cleanly with a notice when you leave the app.
- Something shared to Agello is answered in a new chat the next time the app opens, not inside the share sheet.
- Agello needs an iPhone with 12 GB of memory (iPhone 17 Pro and Pro Max, iPhone Air, or later). On an iPhone with less it opens on a screen that says so.
