---
name: agello-inference-rules
description: Rules that keep LiteRT-LM from crashing or misbehaving in Agello. Read before changing ChatEngine.swift, AppState's generation or engine lifecycle, ContextBudget, InferencePlanner, helper tasks, tools, or anything that sends to the model.
---

# Agello inference rules

Each rule below comes from a failure reproduced on device. Breaking one
usually crashes the app (native heap corruption) or silently corrupts output,
and the simulator can't catch any of them. The runtime mechanisms behind them
are in the fork's reference (`../LiteRT-LM/docs/agello/reference/`; map in
`docs/LITERT-LM.md`).

## Ownership

- `LiteRTChatEngine` (actor, `Agello/Inference/ChatEngine.swift`) is the only
  code that touches LiteRT-LM's `Engine` and `Conversation`. Keep it that way.
- `AppState.serialized { }` runs engine operations (load, settings change,
  benchmark, delete, helpers) one at a time. The actor is reentrant across its
  long awaits, so without it two loads interleave and hold two engines. Never
  call `serialized` from inside a serialized operation: that deadlocks.
- `helperJSON`, `helperTexts`, and `transcribe` run in throwaway
  conversations. The runtime keeps the main conversation beside them: it
  copies its KV cache aside while the helper runs and restores it when the
  engine switches back (about 0.1 s, against 2.9 s to reseed 8K tokens on the
  Mac; the copy is 917.5 MB at a 32,000-token window). `endHelper` switches
  back right away (the chat's `getTokenCount()` does it), so the copy, one KV
  cache, lives only while the helper runs; otherwise it would wait for the
  next message.
- The engine keeps the chat only when one cache fits above
  `lowMemoryStopBytes` (`DeviceProfile.keepsConversationAcrossHelpers`).
  Otherwise it releases the main conversation *before* the helper and leaves
  an **empty** one, and the caller must reseed history before the next send.
  Callers ask `lastHelperKeptConversation` (`AppState.afterHelper`) and
  unbind the chat only when it's false; a failed helper reports false.
- While a helper runs, `cancel()` cancels the helper's conversation, never
  the kept main one (a cancelled conversation rejects the next message), even
  before the helper's conversation exists (`helperActive`). A helper that
  fails or is stopped still leaves a conversation (`endHelperAfterFailure`),
  so the next send reseeds instead of reloading the engine.
- Title and memory helpers run on a schedule (`queueHelpers`,
  `runPendingHelpers`): when the user leaves the chat or after
  `HelperTasks.idleDelay` (3 s), never right after each reply, never in voice
  mode, never with a send pending.
- A send prepares and fits its conversation in one `serialized` step
  (`PreparedSend`): a helper or dictation can't empty it in between.

## Context window (KV cache)

- Overflowing the KV cache corrupts the native heap. Before every send:
  `fitContext` (may trim and reseed, or throw `messageTooLong`), then
  `runSend` caps output with `ContextBudget.outputCap` and throws
  `contextFull` when there's no room.
- Budgets use the positions LiteRT-LM allocates, not the request:
  `ContextBudget.allocatedPositions` (a 32K request gets 32,000, both
  runtimes). The 64-token margin is what keeps an MTP verify round inside.
- With tools offered, the room is split (`ToolBudget.plan`): an eighth per
  tool result (budgeted in estimated tokens), at most two calls; the first
  round, where nearly every reply is answered, gets half the room plus Think's
  reasoning budget on top; the two later rounds share what's left, at least a
  sixteenth each, or their reasoning budget plus 256 answer tokens when that
  fits (tool rounds reason with the conversation's budget: the wrapper sends
  them no thinking config). Each reply sends its own reasoning budget that
  leaves the answer room (`ToolBudget.reasoning`). Until 2026-11-02 the first
  round got a quarter with the reasoning inside it: probe 23 measured every
  long answer with Think cut at about 1,960 tokens in an 8K chat. A streaming guard (only with tools) ends the reply
  (`replyTruncated`) before output plus tool results exceed the room; without
  tools the runtime's cap is exact. Don't loosen these limits.
- Counts are exact (probe 17): `Conversation.renderMessageIntoString`
  renders a message as it will be prefilled (on a new conversation that
  includes the preamble, tool schemas and replayed history) and
  `Engine.countTokens` counts it; the first send adds one token (BOS) the
  text doesn't show. `tokensAfterPrefill` = cached tokens + that. `seedTokens`
  is the rendered preface + 1. Byte estimates
  (`ContextBudget.estimateTextTokens`: 3 bytes a token, or a token per digit
  or ideograph, whichever is more) stand in only where the tokenizer isn't
  there (scripted engine, file and web budgets, tool results).
- `fitContext`: if the message fits after what's cached, nothing happens.
  Otherwise it measures the message on an empty conversation (too long:
  `messageTooLong`, and the conversation is left empty, so AppState unbinds
  the chat after any fit error), trims the history with exact per-turn counts
  and checks the rebuilt conversation, trimming by the overshoot.
- Text from outside the app's prompts can't carry chat markers:
  `PromptText.neutralized` puts a zero-width joiner inside `<|` and `|>` in the
  message, system prompt, replayed history, helper prompts and web results
  (probe 19: `<|turn>` typed as text is control token 105 otherwise).
- Reasoning never stays in the KV cache: `load` sets
  `ExperimentalFlags.filterChannelContentFromKvCache = true` explicitly (the
  runtime's builder defaults to true; an unset flag means that default, not
  off). Right after the reply the runtime rewinds and refills the answer
  without its reasoning, which matches a reseed from SwiftData history.
  Measured on the iPhone (two Think turns): 399 cached tokens with the
  filter, 536 with it explicitly off; `ThinkingScenarioTests/test02`
  guards it with `cachedTokenCount()`.
- Chat's cache isn't a setting (since 2026-11-02; a saved custom window is
  dropped at launch): 32K (32,000 allocated, the model file's most) on
  the 12 GB iPhones (the floor, 11 GB or more of physical memory; the
  maintainer's choice, 2026-11-09). `DeviceProfile.defaultMaxTokens`' smaller
  values only serve the iPhone app run on a Mac with less. On our runtime
  decode hardly depends on the window (iPhone 17 Pro: 39 / 42 / 42 tok/s at
  8K / 16K / 32K); 16K peaks at 1.9 GB and 32K at 3.5 GB. Each load measures
  the room left (`MemoryProbe.roomBytes`: the app's memory limit less its
  footprint, nil where no limit is reported) after the old engine is gone, and
  steps down
  (`DeviceProfile.contextTokens`): 16K below 5.1 GB (an estimate: 3.5 GB
  plus 32K's extra 1.6 GB; the memory suite's 6.0 GB envelope passed with
  1.3 GB to spare on 2026-11-10, nothing lower is measured), 8K below
  3.5 GB (at 3.38 GB a 16K load, an image and a 2K-token prompt were killed,
  memory suite at 3.5 GB usable). Physical memory decides, not the reported
  limit, which has read 6.44 GB on the iPhone 17 Pro before rising to
  8.59 GB. The engine keeps that window for later plans
  (`loadedContextTokens`), so a settings change doesn't reload to try a
  larger one. Budgets read the engine's `resolved.maxNumTokens`, never the
  default. Don't raise it without the memory suite.
- Think's reasoning budget is 4,096 tokens on every device
  (`DeviceProfile.defaultThinkingBudget`, the maintainer's choice on
  2026-11-10; 1,024 cut a coding plan mid-word on the iPhone 17 Pro), and not
  a setting since 2026-11-11, when the Advanced screen was removed. It's a
  ceiling, and the reply reserve below counts it. `InferenceOptions.launch`
  starts every launch from the defaults and keeps only Think: speculative
  decoding, the sampler, vision, audio, image detail and the system prompt
  are the app's choices, set in memory by tests and the Mac command line
  only.
- When history is trimmed, the reply reserve stays free: a quarter of the
  window plus the reasoning budget, at most a third
  (`ContextBudget.replyReserve`): 8,000 tokens at 32K and 10,666 with Think,
  4,096 and 5,461 at 16K, 2,048 and 2,730 at 8K (512 plus reasoning before
  2026-11-02). A message fits when it leaves that reserve after the preamble:
  about 21K tokens of English at 32K, about 10K at 16K; digits cost a token
  each. Tests with longer prompts set
  `maxNumTokensOverride` in memory (see `test15_LongContextDigitFidelity`).

## Engine lifecycle

- A load can "succeed" with parts of the model unmapped. Every new engine must
  pass `validate()` (a one-token generation) before use, retried once after
  750 ms. Loads run on the GPU only: multimodal, then text-only
  (`InferencePlanner.attempts`). The last attempt gets a second try whatever
  the error, then the load fails and is reported: there is no CPU backend to
  fall back to (removed 2026-11-11, `docs/BACKEND.md`), so don't add one. The
  image and audio encoders still run on the CPU; that's a B5 thread.
- `InferencePlanner.requiresEngineReload` lists the engine-level settings
  (KV size, vision, audio, MTP). Changing any of
  them needs a full `load`. Everything else goes through
  `updateConversationOptions`, which reseeds the conversation.
- Engine-level `ExperimentalFlags` must be set before creating the engine.
- Engine caches go through `EngineCache`: `directory()` for any E4B engine,
  `embeddingDirectory()` for EmbeddingGemma, `EngineCache.disabled` for
  one-off engines like the benchmark. Never hand an engine the cache root:
  `directory()` deletes everything in it that isn't this build's.
  The runtime keys weights by content (T11): one folder, `kv-all-<id>`, and
  one copy for every context size (probe 14 guards it; upstream's keying
  wrote 2.2 GB more per size). LiteRT-LM's cache keys ignore the runtime
  build, so the folders carry the build's id (`EngineCache.runtimeBuildID`)
  and another build's folders are deleted at the next load.
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
    (`512·h + l`) so the rotary math stays exact up to 32,767, M1-class GPUs
    included (2,048-token blocks, the first revision, still missed digits
    there). It's pinned to a Hugging Face commit; probes 10–12 prove it.
  - The app runs in 16-bit activations everywhere, with no FP32 switch.
  - Don't point the catalog at the unpatched file, and don't add precision
    switching back.
  - When the model is updated, re-apply `patch_rope.py --split --block 512` (see
    `agello-litert-update`), then run `test15_LongContextDigitFidelity`
    and probe 12.
- Speculative decoding (MTP) breaks JSON-schema constrained decoding on
  device: the draft and verify states share
  one grammar matcher, so verify masks come from the wrong position and a
  rejected draft stays committed (reference `troubleshooting.md`).
  `helperJSON` turns MTP off; plain-text helpers keep it.
- JSON-schema enums take one-word values: on our runtime a space inside an
  enum or const value fails the grammar ("Failed to commit token: ▁talk",
  the tokenizer's word-start marker read as its own bytes; 2026-11-02, the
  Search plan's `kind`). Free strings are fine.
- Don't trust the model file's `thinking` or `functionCalling` flags: Gemma 4
  files report both as unsupported, yet both work.
- Sampling (probe 18): with MTP on, every reply is greedy whatever the
  preset; with MTP off the conversation's sampler applies, but every
  conversation starts at seed 0, so a rebuilt conversation repeats the same
  reply. A varied reply needs MTP off and a seed of its own
  (`SamplerConfig(seed:)`); that's how Regenerate samples. This holds since
  `agello-next` `f1b88286` (4.1c); before it, the engine's first conversation
  (the load's validation, greedy) fixed the sampler for every conversation,
  so presets and Regenerate's seeds never applied (probe 18 on the M6,
  2026-10-24).
- Reply stats come from the runtime's telemetry: `RuntimeTelemetry` takes a
  reply's tokens and decode speed from the totals before and after it (level
  2, for decode times). Benchmark mode (`ExperimentalFlags.enableBenchmark`,
  `getBenchmarkInfo`) makes every GPU wait spin (Mac calibration, 2026-10-24:
  7.5–8.7 ms of CPU per decoded token, against 0.7 ms with it off), so `load`
  turns it off. Don't turn it on; `LiteRTLM.benchmark` sets it for itself and
  restores it.
- Visual tokens per image: E4B's file accepts at most 280
  (`VisualDetail.offered(limit:)`); a file that can't be inspected gets 280.

## Memory and background

- Replies stop only when available memory drops below 400 MB
  (`DeviceProfile.lowMemoryStopBytes`), not at the first memory warning.
- No GPU work in the background. A reply stops when the app leaves the
  foreground, except long file summaries running as a `BGContinuedProcessingTask`
  with background GPU. `GPUGate` (separate from `isBusy`) is closed in the
  background: helpers, dictation and indexing are cancelled and re-queued, and
  a load interrupted by backgrounding stops (`GPUGate.closedError`) and runs
  again when the app is back.
- Extensions (widgets, share sheet) can't load the model. They hand off to the
  app.
- Memory warnings go through `MemoryPolicy.action(level:)` and
  `AppState.relieveMemoryPressure(level:)`: a warning stops a reply only below
  the 400 MB line and releases EmbeddingGemma. E4B stays loaded
  (`AppStateTests.testMemoryWarningKeepsTheEngineLoaded`).

## Verify

Engine changes need `scripts/device-harness.sh inference` (plus `files` or
`web` when retrieval is involved) on the iPhone. Unit tests run the scripted
`MockChatEngine` and don't exercise LiteRT-LM.
