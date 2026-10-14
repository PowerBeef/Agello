---
name: iRTChat inference rules
description: Rules that keep LiteRT-LM from crashing or misbehaving in iRTChat. Read before changing ChatEngine.swift, AppState's generation or engine lifecycle, ContextBudget, InferencePlanner, helper tasks, tools, or anything that sends to the model.
---

# iRTChat inference rules

Each rule below comes from a failure reproduced on device. Breaking one
usually crashes the app (native heap corruption) or silently corrupts output,
and the simulator can't catch any of them.

## Ownership

- `LiteRTChatEngine` (actor, `iRTChat/Inference/ChatEngine.swift`) is the only
  code that touches LiteRT-LM's `Engine` and `Conversation`. Keep it that way.
- `AppState.serialized { }` runs engine operations (load, settings change,
  benchmark, delete, helpers) one at a time. The actor is reentrant across its
  long awaits, so without it two loads interleave and hold two engines. Never
  call `serialized` from inside a serialized operation: that deadlocks.
- LiteRT-LM keeps one live conversation per engine. `helperJSON`,
  `helperTexts`, and `transcribe` create throwaway conversations and leave the
  main one **empty**, so the caller must reseed history before the next send.

## Context window (KV cache)

- Overflowing the KV cache corrupts the native heap. Before every send:
  `fitContext` (may trim and reseed, or throw `messageTooLong`), then
  `runSend` caps output with `ContextBudget.outputCap` and throws
  `contextFull` when there's no room.
- With tools on, the remaining room is split: a quarter per generation, an
  eighth per tool result, at most two tool calls. A streaming guard ends the
  reply (`replyTruncated`) before output plus tool results exceed the room.
  Don't loosen these limits.
- `getTokenCount()` reads 0 until the first send, so `pendingSeedTokens`
  stands in. Update it whenever a conversation is created or reseeded.
- The token estimate is about 3 bytes per token, learned upward from exact
  runtime counts (`estimateCalibration`, clamped 1–3). Estimates must stay
  conservative.
- Chat uses an 8K cache. Settings can raise it to 16K, or 32K when the app
  may use at least 6.5 GB; nothing raises it automatically. A bigger cache
  slows every reply, so don't raise the default.
- At 3 bytes per token, about 4K tokens of English prose is the most one
  message can hold in 8K. Tests with longer prompts set
  `maxNumTokensOverride` (see `test15_LongContextDigitFidelity`).

## Engine lifecycle

- A load can "succeed" with parts of the model unmapped. Every new engine must
  pass `validate()` (a one-token generation) before use, retried once after
  750 ms. Loads try GPU then CPU, multimodal then text-only.
- `InferencePlanner.requiresEngineReload` lists the engine-level settings
  (backend, KV size, vision, audio, MTP). Changing any of
  them needs a full `load`. Everything else goes through
  `updateConversationOptions`, which reseeds the conversation.
- Engine-level `ExperimentalFlags` must be set before creating the engine.
- Settings changed just before sending must apply to that message
  (`scheduleApplyOptions`, then send).

## Cancellation and branches

- A cancelled conversation rejects the next message ("CANCELLED"). A cancel
  always ends as `generationCancelled`, and the caller reseeds from history
  before the next send. Stopped replies keep their partial text.
- Regenerate and edit rebuild the context from the turns before the changed
  turn, so abandoned branches never leak into the next answer.

## Precision and decoding

- **Only use the patched model file.** Google's Gemma 4 E4B file duplicates
  digits past position 2,048 with 16-bit GPU activations ("2026" becomes
  "202026"; LiteRT-LM #3913): it computes rotary angles from a float copy of
  the position, which FP16 can't hold exactly above 2,048.
  - `ModelCatalog.e4b` downloads a copy whose rotary positions are split
    (`2048·h + l`) so every float stays exact up to 32,767. It's pinned to a
    Hugging Face commit; probes 10–12 prove it.
  - The app runs in 16-bit activations everywhere, with no FP32 switch.
  - Don't point the catalog at the unpatched file, and don't add precision
    switching back.
  - When the model is updated, re-apply `patch_rope.py --split` (see
    `irtchat-litert-update`), then run `test15_LongContextDigitFidelity`
    and probe 12.
- Speculative decoding (MTP) breaks JSON-schema constrained decoding on
  device. `helperJSON` turns MTP off; plain-text helpers keep it.
- Don't trust the model file's `thinking` or `functionCalling` flags: Gemma 4
  files report both as unsupported, yet both work.

## Memory and background

- Replies stop only when available memory drops below 400 MB
  (`DeviceProfile.lowMemoryStopBytes`), not at the first memory warning.
- No GPU work in the background. A reply stops when the app leaves the
  foreground, except long file summaries running as a `BGContinuedProcessingTask`
  with background GPU.
- Extensions (widgets, share sheet) can't load the model. They hand off to the
  app.

## Verify

Engine changes need `scripts/device-harness.sh inference` (plus `files` or
`web` when retrieval is involved) on the iPhone. Unit tests run the scripted
`MockChatEngine` and don't exercise LiteRT-LM.
