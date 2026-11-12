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
| **Composer** | `+` adds a photo, a file, a scanned document, or a voice message · **Think** turns reasoning on (the screen glows lavender) · **Search** lets Agello research the web when your message needs it (teal): the facts for a question, or the techniques and documentation for something to write or build. Greetings, small talk, and work on text you've given (rewrite, translate, summarize) are answered without searching · 🎙 dictates · ↑ sends, or the waveform starts voice mode when the composer is empty · ■ stops. You can type your next message while a reply streams. |
| **Talk** | In voice mode, just speak: the answer arrives as text and speech. Talk over it, or tap the orb, to interrupt. The camera button sends what you're looking at with your question. |
| **A reply** | Use the row under it to copy, read aloud, regenerate, or share; ‹ › switches between versions. |
| **Your message** | Long-press to copy or edit it; editing loads it back into the composer and branches the conversation. |
| **Drawer** | Chats grouped by date with pinned chats on top. Search all chats by words, plus **Related chats** by meaning ("Japan vacation" finds "Kyoto itinerary"). Long-press a chat to pin, rename, move to a project, or delete it; Settings sits at the bottom. |
| **A project** | Name, instructions, shared files, its chats, and "New chat in this project". Every chat in a project follows its instructions and can use its files. |
| **Files** | PDFs, text, Markdown, code, CSV, JSON and RTF, or scanned paper. Short files are read whole; long ones are searched by meaning and cited by page. "Summarize this" reads a long file section by section once, then reuses the summary. |

## Settings

Settings opens from the bottom of the drawer. The card on top shows the model and whether it's ready. How the model runs (its speed settings, its reasoning budget, image detail) isn't a setting: Agello chooses.

| Section | Options |
| --- | --- |
| **Personalization** | Name · about you · how to respond · response style (Default, Concise, Detailed, Friendly, Professional). Added to the system prompt. |
| **Memory** | On or off (off by default) · review, edit, add, or delete memories · delete all. A reply that saved a memory says so. |
| **Web search** | Allow web search · search automatically (off by default) · provider: DuckDuckGo, Wikipedia, SearXNG (your instance) |
| **Spotlight** | Show chats in system search (on by default) |
| **Models** | Download, pause, resume, or delete Gemma 4 E4B and EmbeddingGemma |
| **On-device tools** | Turn the tools (date and time, calculator) on or off |
| **Help** | Share diagnostics: the system's crash and performance reports and the app's log of the last hour, kept on the iPhone until you share them |

## Outside the app

- **Siri and Shortcuts.** "Ask Agello", "New Chat", and "Talk to Agello" work from Siri, the Shortcuts app, the Action Button, and Spotlight.
- **Widgets and Control Center.** Home Screen and Lock Screen widgets ("Ask Agello", "Talk"), and Control Center controls for a new chat or a voice conversation.
- **Spotlight.** Your chats appear in system search (a toggle in Settings), and tapping a result opens that chat.
- **Share sheet.** "Ask Agello" from any app with text, a link, an image, or a file; Agello answers when the app opens next.
- **Links.** `agello://new`, `agello://ask?q=…`, and `agello://voice` work from anywhere on the system.

## The models

| Model | Size | Role | License |
| --- | --- | --- | --- |
| **Gemma 4 E4B** | 3.7 GB | Chat: text, vision, audio, reasoning, and tool calling in one file. Context: 32K tokens, less when the iPhone is short of memory as the model loads | Apache 2.0 |
| **EmbeddingGemma 2** (text, 270M) | 165 MB | Turns passages and chats into 256-dimension vectors for retrieval and search by meaning. Downloads automatically after the chat model; keyword search fills in until then | Apache 2.0 |

- **Source.** Downloaded at runtime from Hugging Face, without an account. EmbeddingGemma is the [`litert-community`](https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm) build. The chat model is [`litert-community`'s Gemma 4 E4B build](https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm) with one fix: its rotary positions stay exact with 16-bit GPU activations, with the same weights ([`PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope`](https://huggingface.co/PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope); see [the engineering notes](ENGINEERING.md#long-context-digits-on-the-gpu-litert-lm-3913)). Both downloads are pinned to a commit.
- **Downloads** run in a background `URLSession`: they continue while the app is in the background, resume after a relaunch, support pause and resume, check free space first, and are verified by HTTP status, file size and SHA-256 checksum. Models are stored in Application Support and excluded from iCloud backup.
- **Earlier versions.** Chats created with Gemma 4 E2B continue on E4B. Older model files (E2B, and the unpatched E4B) are deleted automatically, and the current file downloads once.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Signing error *"PLA Update available"* | Accept the latest Program License Agreement at [developer.apple.com/account](https://developer.apple.com/account). |
| *"Failed to create a bundle instance … AgelloDeviceTests.xctest"* | The iPhone has an install from before that target existed. Run `xcrun devicectl device uninstall app --device <udid> com.patricedery.agello` and retry. This also removes downloaded models. |
| UI tests fail with *"Timed out while enabling automation mode"* | Unlock the iPhone and keep it unlocked during the run. |
| The download stopped | Tap **Resume** in **Settings → Models**. Downloads continue in the background, but force-quitting the app cancels them. |
| *"Older messages were dropped from the model's memory"* | Expected in long chats: the oldest turns make room for new ones. Start a new chat to begin fresh. |
| *"This message is too long for the model's memory"* | The message alone doesn't fit the model's memory (about 21,000 tokens, roughly 15,000 words; about 10,000 tokens when the iPhone is short of memory). Attach the text as a file instead. |
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
- DuckDuckGo results come from its HTML page (an unofficial interface); if it asks for a bot check, searches fall back to Wikipedia, or use your own SearXNG.
- Only long document summaries keep running when you leave the app, and only on iPhones that support background GPU use (the iPhone 17 Pro on iOS 27 doesn't: there the summary stops with a notice, like any other reply).
- Something shared to Agello is answered in a new chat the next time the app opens, not inside the share sheet.
- Agello needs an iPhone with 12 GB of memory (iPhone 17 Pro and Pro Max, iPhone Air, or later). On an iPhone with less it opens on a screen that says so.
