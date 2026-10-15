# Engineering notes

How Agello keeps a 4-billion-parameter model fast, correct and stable on a phone. Every safeguard here comes from a failure reproduced on a real iPhone by the [test harness](TESTING.md).

- [Fixing long-context math on the GPU (LiteRT-LM #3913)](#fixing-long-context-math-on-the-gpu-litert-lm-3913)
- [A context window that never overflows](#a-context-window-that-never-overflows)
- [One engine, one conversation](#one-engine-one-conversation)
- [Branching conversations](#branching-conversations)
- [Retrieval with citations](#retrieval-with-citations)
- [Memory, background and lifecycle](#memory-background-and-lifecycle)
- [Model quirks we don't trust](#model-quirks-we-dont-trust)

## Fixing long-context math on the GPU (LiteRT-LM #3913)

**Symptom.** On the iPhone GPU, Gemma 4 E4B started duplicating digits once a chat passed a few thousand tokens: "March 2026" became "March 202026". The CPU and 32-bit GPU activations were correct, so the app first worked around it by rebuilding the engine in float32 for long chats, at about half the decode speed.

**Root cause.** A device probe that copies a 48-digit number from increasing positions showed the errors start at exactly **position 2,048**. The model computes rotary angles from a float copy of the token position. With 16-bit activations that copy is float16, whose 11-bit significand holds every integer only up to 2,048; past it, positions round to even numbers and attention sees the wrong angle. The full analysis is [on the upstream issue](https://github.com/google-ai-edge/LiteRT-LM/issues/3913#issuecomment-6157362598).

**Fix: rewrite the graph, not the runtime.** LiteRT-LM's runtime is a prebuilt binary, so the fix edits the model file instead ([`patch_rope.py`](https://github.com/PowerBeef/agello-litert-lm/tree/research/3913/research/issue-3913)). It splits every position as `2048·h + l`:

- `l` (0–2,047, exact in float16) goes through the model's existing MUL / SIN / COS;
- the phase of `2048·h` comes from small precomputed tables selected with `onehot(h)`;
- angle addition combines them, using only values in [−1, 1].

Every float stays exact up to position 32,767. The weights are untouched, the main model and its speculative-decoding drafter are both patched, and the output is reproducible byte for byte from Google's file. A first attempt (shifting positions by −2,048) only doubled the exact range, to 4,096, which is why the split was needed.

**Results on iPhone 17 Pro** ([follow-up on the issue](https://github.com/google-ai-edge/LiteRT-LM/issues/3913#issuecomment-6159684389)):

| | Patched, float16 | Original, float32 (old workaround) | Original, float16 |
| --- | --- | --- | --- |
| Exact 48-digit copies, 0.7K–30K tokens | **14 / 14**, identical text to float32 | 14 / 14 | 0 / 3 |
| Prefill / decode at 8K tokens (tok/s) | **385 / 16.1** | 229 / 13.7 | 378 / 16.0 |
| Decode with speculative decoding at 16K (tok/s) | **34.7** | 17.1 | n/a |
| Memory after loading | **2.04 GB** | 2.76 GB | |

So every chat now runs at full float16 speed with no precision switch: 1.7–2.1× faster prefill, up to 2× faster decoding, 0.7 GB less memory, and no engine reload when a chat grows. The app downloads [the patched model](https://huggingface.co/PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope), pinned to a commit; `test15_LongContextDigitFidelity` and probe 12 guard it.

## A context window that never overflows

Overflowing LiteRT-LM's KV cache corrupts its native heap and crashes the app, so every message is budgeted before it is sent:

- **Measure, then estimate.** The tokens already cached are read from the runtime; the new message is estimated at 3 bytes per token, a deliberately conservative figure that is calibrated upward from exact runtime counts and never relaxed below it.
- **Fit or explain.** If the message plus a reply reserve doesn't fit, older turns are trimmed (the latest reply is truncated rather than dropped) and the conversation is reseeded. A message that can never fit is rejected with an explanation instead of crashing.
- **Cap the reply.** The reply is capped to the room that's left. The preamble estimate includes the whole system prompt, personalization and project instructions included.
- **Tool budgets.** LiteRT-LM runs tool calls by itself while streaming, so each generation round gets a quarter of the remaining room, each tool result an eighth, with at most two calls. A streaming guard ends a reply cleanly before output plus tool results could overflow.
- **Context sizes.** Chat uses an 8K cache: a bigger one slows every reply (43 → 27 tok/s from 4K to 32K). Settings can raise it to 16K, or 32K when the app may use at least 6.5 GB.

## One engine, one conversation

`LiteRTChatEngine` (an actor) is the only code that touches LiteRT-LM's `Engine` and `Conversation`:

- **Serialized lifecycle.** Loads, settings changes, benchmarks, helpers and deletes run one at a time through `AppState.serialized`. The actor is reentrant across its long awaits; without the queue, two loads could interleave and hold two 3.7 GB engines.
- **Validated loads.** LiteRT-LM can report a successful load after failing to map parts of the model file. Each new engine must complete a one-token generation before use. Loads fall back GPU → CPU and multimodal → text-only.
- **A bounded GPU cache.** LiteRT-LM's GPU cache makes a load take 0.8 s instead of 7.5 s, but it stores a full 2.2 GB copy of the E4B weights for every context size an engine is created with, in one file it never trims ([probe 14](../AgelloDeviceTests/WeightCacheProbe.swift)); one test run grew it to 10.25 GB and filled the phone. `EngineCache` gives each context size its own folder and keeps the two most recently used, the benchmark's one-off engine isn't cached, and EmbeddingGemma has a folder of its own.
- **Throwaway helpers.** Titles and memories use JSON-schema constrained decoding in a throwaway conversation, with speculative decoding off (it corrupts the grammar mask on device). LiteRT-LM keeps one live conversation per engine, so the chat is rebuilt from history afterwards.
- **Tool failures don't end replies.** LiteRT-LM v0.18.0 ends the whole reply when a tool call fails: a tool name the model invents, arguments that don't decode, or a tool that throws. Our fork's wrapper answers the call with an error the model reads instead, and the calculator returns its errors (with the syntax it accepts) rather than throwing. It takes what models write for money questions: `^` powers, `18%` percent, `$` and thousands separators.
- **No 10-minute stall after a dropped stream.** LiteRT-LM's Swift wrapper releases a stream's last reference to its conversation inside the native callback. When nothing else still holds the conversation (a stream abandoned early, or a conversation replaced while its cancelled stream was finishing), its deletion waits for the very task running that callback, and the engine stalls until LiteRT-LM's 10-minute timeout ([probe 9](../AgelloDeviceTests/ProbeScenarioTests.swift) waited 600 s for a first token). Our fork's wrapper holds the conversation weakly in the stream, so it's deleted where the app drops it, after its stream's work finishes, never inside the callback.
- **Stop and resume.** A cancelled conversation rejects the next message, so a stopped reply keeps its text and the conversation is rebuilt before the next send.
- **Settings apply when you send.** A setting changed just before sending, like **Think**, applies to that message. Engine-level changes (backend, cache size, vision, audio, speculative decoding) reload the engine; everything else just reseeds the conversation.

## Branching conversations

Chat history is a SwiftData `VersionedSchema` with a migration plan (V1 → V3). Turns form a tree through `parentID`, and each thread's active leaf selects the visible branch. That is what makes edit, regenerate and the ‹ 2/3 › version switcher work. Regenerate and edit rebuild the model's context from the turns *before* the changed one, so abandoned versions never leak into the next answer. Migrations are tested against real on-disk stores, and a store that can't open is set aside rather than crashing the app.

## Retrieval with citations

Attached files are read with PDFKit and on-device Vision text recognition, split into ~400-token passages that keep their page numbers, and embedded in the background with EmbeddingGemma (256-dimension vectors stored in SwiftData, searched with vDSP; keyword ranking fills in until embeddings exist). `FileContext` decides what the model reads within half the context window: whole files, cited excerpts, or a cached section-by-section summary. Answers cite pages, like *(report.pdf, p. 23)*.

Web search follows the same shape: a provider chain with bot-check and rate-limit detection (your SearXNG, Brave or Tavily, then DuckDuckGo, then Wikipedia), five pages read in parallel with a built-in readable-text extractor, passages ranked with EmbeddingGemma, and numbered sources.

## Memory, background and lifecycle

- **Memory limits.** The memory entitlements raise the app's limit to about 8.6 GB on a 12 GB iPhone 17 Pro and prevent address-space exhaustion when engines are rebuilt. A reply stops only when available memory falls below 400 MB, not at the first memory warning. The 8 GB floor (iPhone 15 Pro) was validated by simulating 5.0, 4.0 and 3.5 GB of usable memory.
- **Background GPU.** iOS doesn't allow GPU work in the background, so a reply stops cleanly when the app leaves the foreground, except long document summaries: they run as a continued processing task with background GPU, where the device supports it, with progress in a Live Activity that can cancel them. The iPhone 17 Pro on iOS 27 doesn't (`BGTaskScheduler.supportedResources` is empty, with the entitlement signed in), so there a summary stops with a notice like any other reply.
- **Extensions hand off.** Widgets, Control Center, Siri and the share sheet can't load a 3.7 GB model, so they hand their request to the app (App Intents, `agello://` links, and an App Group inbox for shared items).

## Model quirks we don't trust

- The model file reports *thinking* and *function calling* as unsupported, yet Gemma 4 reasons and calls tools on device; the app ignores those flags.
- Speculative decoding breaks JSON-constrained decoding on device, so structured helpers turn it off.
