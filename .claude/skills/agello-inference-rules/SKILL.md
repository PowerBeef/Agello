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
- Google's LiteRT-LM keeps one live conversation per engine. `helperJSON`,
  `helperTexts`, and `transcribe` create throwaway conversations, which wipe
  the main one (v0.18.0's session restore leaves the helper's KV cache in the
  GPU buffers): the engine replaces it with an **empty** one, and the caller
  must reseed history before the next send.
- Our runtime (a build with a build id, `EngineCache.runtimeBuildID`) keeps
  the main conversation: it copies its KV cache aside while the helper runs
  and restores it when the engine switches back (about 0.1 s, against 2.9 s
  to reseed 8K tokens on the Mac). `endHelper` switches back right away (the
  chat's `getTokenCount()` does it), so the copy, one KV cache, lives only
  while the helper runs; otherwise it would wait for the next message. The
  engine keeps the chat only when one cache fits above `lowMemoryStopBytes`
  (`DeviceProfile.keepsConversationAcrossHelpers`); otherwise it releases the
  main conversation *before* the helper and leaves an empty one, as with
  Google's. Callers ask `lastHelperKeptConversation` (`AppState.afterHelper`)
  and unbind the chat only when it's false; a failed helper reports false.
- While a helper runs, `cancel()` cancels the helper's conversation, never
  the kept main one (a cancelled conversation rejects the next message), even
  before the helper's conversation exists (`helperActive`). A helper that
  fails or is stopped still leaves a conversation (`endHelperAfterFailure`),
  so the next send reseeds instead of reloading the engine.
- Title and memory helpers run on a schedule (`queueHelpers`,
  `runPendingHelpers`): when the user leaves the chat or after
  `HelperTasks.idleDelay` (3 s on our runtime, 60 s on Google's, where each
  helper costs a full re-prefill), never right after each reply, never in
  voice mode, never with a send pending.
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
  off). At the next message (Google's v0.18.0; our build does it right after
  the reply) the runtime rewinds and refills the answer without its
  reasoning, which matches a reseed from SwiftData history.
  Measured on the iPhone (two Think turns): 399 cached tokens with the
  filter, 536 with it explicitly off; `ThinkingScenarioTests/test02`
  guards it with `cachedTokenCount()`.
- Chat's cache isn't a setting (since 2026-11-02; a saved custom window is
  dropped at launch): 32K (32,000 allocated, the model file's most) on
  devices with 11 GB or more of physical memory (the 12 GB iPhones, the floor;
  the maintainer's choice, 2026-11-09), 16K on 8 GB devices. On our runtime
  decode hardly depends on the window (iPhone 17 Pro: 39 / 42 / 42 tok/s at
  8K / 16K / 32K); 16K peaks at 1.9 GB and 32K at 3.5 GB. Each load measures
  the room left (`MemoryProbe.roomBytes`: the jetsam limit or Metal's working
  set, less the footprint) after the old engine is gone, and steps down
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
- Think's reasoning budget is a setting (Advanced, 128–4,096) with a default of
  4,096 on every device (`DeviceProfile.defaultThinkingBudget`, the
  maintainer's choice on 2026-11-10; 1,024 cut a coding plan mid-word on the
  iPhone 17 Pro). It's a ceiling: at 16K the reply reserve grows from 5,120 to
  5,461 tokens, at 8K not at all. `InferenceOptions.launch` moves a budget
  saved at the old 1,024 once (`thinkingBudgetIs4096` in UserDefaults); a
  budget chosen afterwards stays.
- When history is trimmed, the reply reserve stays free: a quarter of the
  window plus the reasoning budget, at most a third (4,096 or 5,120 tokens at
  16K; 512 plus reasoning before 2026-11-02). A message fits when it leaves
  that reserve after the preamble: about 10K tokens of English at 16K; digits
  cost a token each. Tests with longer prompts set
  `maxNumTokensOverride` in memory (see `test15_LongContextDigitFidelity`).

## Engine lifecycle

- A load can "succeed" with parts of the model unmapped. Every new engine must
  pass `validate()` (a one-token generation) before use, retried once after
  750 ms. Loads try GPU then CPU, multimodal then text-only.
- `InferencePlanner.requiresEngineReload` lists the engine-level settings
  (backend, KV size, vision, audio, MTP). Changing any of
  them needs a full `load`. Everything else goes through
  `updateConversationOptions`, which reseeds the conversation.
- Engine-level `ExperimentalFlags` must be set before creating the engine.
- Engine caches go through `EngineCache`: `directory(maxNumTokens:)` for any
  E4B engine, `embeddingDirectory()` for EmbeddingGemma, `EngineCache.disabled`
  for one-off engines like the benchmark. Never hand an engine the cache root.
  Google's LiteRT-LM keeps another weight copy per context size in one file
  (each folder held about 2.5 GB for E4B) and never trims it (probe 14), so
  with it each size has a folder (the two most recently used kept). Ours keys weights by content (T11): one folder,
  `kv-all-<id>`, for every size. LiteRT-LM's cache keys ignore the runtime
  build, so builds that report an id (ours) get folders of their own and
  another build's folders are deleted (`EngineCache.runtimeBuildID`).
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
  device, in Google's binary and in ours: the draft and verify states share
  one grammar matcher, so verify masks come from the wrong position and a
  rejected draft stays committed (reference `troubleshooting.md`).
  `helperJSON` turns MTP off; plain-text helpers keep it.
- JSON-schema enums take one-word values: on our runtime a space inside an
  enum or const value fails the grammar ("Failed to commit token: ▁talk",
  the tokenizer's word-start marker read as its own bytes; 2026-11-02, the
  Search plan's `kind`). Free strings are fine.
- Don't trust the model file's `thinking` or `functionCalling` flags: Gemma 4
  files report both as unsupported, yet both work.
- Sampling (probe 18, Google's v0.18.0): with MTP on, every reply is greedy
  whatever the preset; with MTP off the conversation's sampler applies, but
  every conversation starts at seed 0, so a rebuilt conversation repeats the
  same reply. A varied reply needs MTP off and a seed of its own
  (`SamplerConfig(seed:)`); that's how Regenerate samples. Our build does the
  same since `agello-next` `f1b88286` (4.1c); before it, the engine's first
  conversation (the load's validation, greedy) fixed the sampler for every
  conversation, so presets and Regenerate's seeds never applied (probe 18 on
  the M6, 2026-10-24).
- Reply stats: Google's binary gives them only in benchmark mode
  (`ExperimentalFlags.enableBenchmark`, `getBenchmarkInfo`). On ours benchmark
  mode makes every GPU wait spin (Mac calibration, 2026-10-24: 7.5–8.7 ms of
  CPU per decoded token, against 0.7 ms with it off), so `load` leaves it off
  and `RuntimeTelemetry` takes a reply's tokens and decode speed from the
  runtime's telemetry totals before and after it (level 2, for decode times).
  Don't turn benchmark mode on for ours; `LiteRTLM.benchmark` sets it for
  itself and restores it.
- Visual tokens per image: E4B's file accepts at most 280
  (`VisualDetail.offered(limit:)`); a file that can't be inspected gets 280.

## Memory and background

- Replies stop only when available memory drops below 400 MB
  (`DeviceProfile.lowMemoryStopBytes`), not at the first memory warning.
- No GPU work in the background. A reply stops when the app leaves the
  foreground, except long file summaries running as a `BGContinuedProcessingTask`
  with background GPU. `GPUGate` (separate from `isBusy`) is closed in the
  background: helpers, dictation and indexing are cancelled and re-queued, and
  a load interrupted by backgrounding stops rather than falling back to the
  CPU for good (`GPUGate.closedError`).
- Extensions (widgets, share sheet) can't load the model. They hand off to the
  app.
- Memory warnings go through `MemoryPolicy.action(level:isBusy:)` and
  `AppState.relieveMemoryPressure(level:)`: a warning (all iOS sends) stops a
  reply only below the 400 MB line and releases EmbeddingGemma; critical
  pressure (the Mac's) also unloads E4B, only when nothing uses it (no reply,
  voice mode, benchmark or dictation, checked again inside `serialized`). The
  next message reloads it from the engine cache. Probe 22 checks it on the real
  engine.

## Verify

Engine changes need `scripts/device-harness.sh inference` (plus `files` or
`web` when retrieval is involved) on the iPhone. Unit tests run the scripted
`MockChatEngine` and don't exercise LiteRT-LM.
