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
  conversations. On exclusive helper switches (`agello-one-20261122`+), the
  runtime keeps the main conversation beside them by detaching/restoring its
  sparse global KV caches via Metal 4 `MTL4CommandQueue.copyBufferMappingsFromBuffer:`
  (zero-blit page-table handoff; only the 1,536-slot local ring buffers blit on
  v2). `endHelper` switches back right away (the chat's `getTokenCount()` does
  it), so the detached snapshot lives only while the helper runs.
- The engine keeps the chat only when `GPUGate.isOpen` and the helper snapshot
  plus helper KV pages fit above `lowMemoryStopBytes`
  (`DeviceProfile.keepsConversationAcrossHelpers(usedTokens:exportWindow:)`:
  for the v2 ring-KV model with `exportWindow >= 65_536`, counts the fixed
  31.5 MB local rings + 8,192 B/token up to 4,096 helper positions; for 32K
  files without rings, 28,672 B/token).
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
  `ContextBudget.allocatedPositions` (the app's 64K request gets the full
  65,536 with the shipped v2 128K model, or 32,000 with older 32K files). The
  64-token margin is what keeps an MTP / `verify_8` round inside.
- With tools offered, the room is split (`ToolBudget.plan`): below `16,384`
  tokens of room, an eighth per tool result with at most 2 calls; at `>= 16,384`
  tokens (typical 64K chats), a sixteenth per tool result (1,000–4,000 tokens
  each) with up to 4 calls for multi-step Think + parallel read-only rounds.
  The first round, where nearly every reply is answered, gets half the room plus
  Think's reasoning budget on top; later rounds share what's left, at least
  their floor or reasoning budget plus 256 answer tokens when that fits. Each
  reply sends its own reasoning budget that leaves the answer room
  (`ToolBudget.reasoning`). A streaming guard (only with tools) ends the reply
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
  the chat after any fit error), trims the history by token budget with exact
  per-turn counts (`ContextBudget.trimHistory` returns `(kept, evicted)` and
  `makeConversation` no longer uses a hard 20-turn cap), records evicted turns
  in `lastEvictedHistory` so `AppState.promptWithEvictedRecall` can recall
  relevant snippets via `KnowledgeBase.recallEvictedTurns` and re-verify
  `fitContext`, and checks the rebuilt conversation, trimming by any overshoot.
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
  dropped at launch): a fixed 64K (65,536 requested) on the 12 GB iPhones
  (the floor, 11 GB or more of physical memory), capped by the model file: a
  load reads the file's export window (`ContextBudget.exportWindow(reported:)`
  from ModelInfo; the shipped v2 128K file runs at the full 65,536) and every
  plan uses it (`InferencePlanner.resolve(..., exportWindow:)`, in `load` and
  `plan(for:)` alike, or a settings change would reload).
  `DeviceProfile.defaultMaxTokens`' smaller values only serve the iPhone app run
  on a Mac with less. Global KV caches are Metal 4 sparse buffers trimmed on
  reset/rewind and local KV caches are 1,536-slot rings in v2: on iPhone 17 Pro
  (2026-11-22), full 65,536 context held `3.18–3.45 GB` (`2.99–3.26 GB` free
  below jetsam). Each load measures the room left (`MemoryProbe.roomBytes`: the
  app's memory limit less its footprint, nil where no limit is reported) after
  the old engine is gone, and steps down (`DeviceProfile.contextTokens`): 16K
  below **4.2 GB** (`DeviceProfile.roomForLargeContextBytes`, validated by the
  iPhone `memory` suite on 2026-11-22 with 0 warnings across `6.0 / 5.0 / 4.0 /
  3.5 GB`), 8K below 3.5 GB. Physical memory decides, not the reported limit,
  which has read 6.44 GB on the iPhone 17 Pro before rising to 8.59 GB. The
  engine keeps that window for later plans (`loadedContextTokens`), so a
  settings change doesn't reload to try a larger one. Budgets read the engine's
  `resolved.maxNumTokens`, never the default. Don't raise it without the memory
  suite.
- Think's reasoning budget is 4,096 tokens on every device
  (`DeviceProfile.defaultThinkingBudget`, the maintainer's choice on
  2026-11-10; 1,024 cut a coding plan mid-word on the iPhone 17 Pro), and not
  a setting since 2026-11-11, when the Advanced screen was removed. It's a
  ceiling, and the reply reserve below counts it. `InferenceOptions.launch`
  starts every launch from the defaults and keeps only Think: speculative
  decoding, the sampler, vision, audio, image detail and the system prompt
  are the app's choices, set in memory by tests and the Mac command line
  only.
- When history is trimmed, the reply reserve stays free
  (`ContextBudget.replyReserve`): the answer share is capped at
  `maxAnswerReserve = 4,096`, plus the reasoning budget, at most a third of the
  window (`min(maxNumTokens / 3, min(maxNumTokens / 4, 4_096) + (thinkingBudget ?? 0))`):
  4,096 tokens at 64K (8,192 with Think), 4,096 at 32K (8,192 with Think),
  4,096 at 16K (5,461 with Think), 2,048 at 8K (2,730 with Think). That unlocks
  ~56K–60K usable single-prompt tokens in a 64K chat (~10K–11K at 16K); digits
  cost a token each. Tests with longer prompts set `maxNumTokensOverride` in
  memory (see `test15_LongContextDigitFidelity`).

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
  - `ModelCatalog.e4b` downloads `gemma-4-E4B-it-agello-v2.litertlm` (1,536-slot
    local KV rings, 128K shared Dual-`GATHER` float16-exact rotary tables with
    <0.001 rad error across 0..131,071, and `verify_8`), built via
    `tools/model-surgery/build_v2.sh` and pinned to a Hugging Face commit;
    `test27_NeedleTable` (90/90) and `test28_WindowPositions` (12/12 exact up to
    65,534 on iPhone 17 Pro) prove it.
  - The app runs in 16-bit activations everywhere, with no FP32 switch.
  - Don't point the catalog at the unpatched file, and don't add precision
    switching back.
  - When the upstream model is updated, re-apply `patch_rope.py --split --block 512`
    then `build_v2.sh` (see `agello-litert-update`), then run
    `test15_LongContextDigitFidelity`, `test27_NeedleTable`, and
    `test28_WindowPositions`.
- **JSON-schema constrained decoding & MTP (P5.1):**
  - Fork `1382157b` fixed MTP + JSON grammar state sharing (each verify state
    keeps its own matcher/mask), and `LiteRT-LM@7d80c7ec` fixed
    `LlgConstraintProvider`'s `TokTrie` byte/special-token encoding (`▁` →
    `0x20`, `<0xXX>` → raw byte, `0xFF` on control/pipe tokens), unlocking
    multi-word JSON schema enums (`test16_MultiWordJsonEnumWithMTP`).
  - `LiteRTChatEngine.jsonHelpersSpeculate` now defaults ON (`AGELLO_JSON_MTP`
    != `"0"`). Note: until a dual-slice runtime release incorporating
    `7d80c7ec` is vendored into `Vendor/LiteRT-LM`, single-word enum values in
    existing shipped schemas remain compatible with `agello-one-20261122-2`.
- **Tool safety & mutability (`AgentSecurity.swift`):**
  - Spotlight every untrusted external text (attached files, web search results,
    shared text, and external tool outputs) inside `<untrusted_data>` after
    `PromptText.neutralized`, and strip untrusted blocks before memory
    extraction (`UntrustedContext.stripUntrustedBlocks`).
  - Mark every `Tool` struct with explicit `static let isReadOnly` (`true` for
    read-only tools eligible for parallel `withTaskGroup` execution; `false`
    for side-effectful tools like `create_calendar_event` and
    `create_reminder`). Every `isReadOnly == false` tool MUST call
    `ToolConfirmationGate.confirm(...)` before mutating state — fail-closed by
    default when backgrounded, stopped, or without an active UI presenter.
  - Never throw from `Tool.run()`: return an actionable `["error": "..."]`
    dictionary so LiteRT-LM lets the model recover instead of aborting the turn.

## Language-agnostic tools and prompts

Gemma 4 E4B covers 140+ languages, with English as its strongest structured and
tool-calling tier. Keep multilingual behavior seamless without degrading English
speed, token budget, or output quality:

- **Natural language in, user's language out.** Never require users to phrase
  requests in a special syntax or name tools to trigger features.
- **Keep machine-to-code boundaries structured or canonical.** Prefer explicit
  structured tool arguments (e.g. `SearchPlacesTool.near`) over parsing
  natural-language prepositions in Swift. In `WebContext.queryPrompt`, keep
  encyclopedia queries in the user's language while instructing structured API
  topics (`place`, `weather`, `currency`) to emit canonical formats with local
  place names intact.
- **Defense in depth via `LanguageSupport.swift`.** E4B can still emit localized
  terms even on English messages containing non-English proper nouns (e.g.
  `"Place des Arts"` → `"pharmacie près de Place des Arts"`). Route all
  Swift-side multilingual parsing through `Agello/Inference/LanguageSupport.swift`
  (`meansCurrentLocation`, `splitPlaceQuery`, `stripWeatherNoise`,
  `stripPlaceHoursNoise`, `normalizeTransportMode`, `parseLocalizedNumber`,
  `isDifferenceFollowUp`, `fold` including German `ß → ss`). Never add
  English-only regexes or splitters, and never strip bare month names or
  articles inside city names (`"Rio de Janeiro"`, `"La Paz"`).
- **Zero-cost conditional tool hints.** Don't bloat `SystemPrompt.base` (tuned
  against 142 checks in `docs/SYSTEM-PROMPT.md`). When non-English turns need
  stronger tool-selection grounding (e.g. E4B attempting mental math on an
  inlined CSV in Spanish), emit a crisp 1-line hint *only* when that context is
  present (`FileContext.prompt` for `.csv`/`.tsv`/`.json` files) and verify
  both English (`WebScenarioTests`) and natural multilingual prompts
  (`KnowledgeScenarioTests/test07_MultilingualNaturalToolIntent`).
- Don't trust the model file's `thinking` or `functionCalling` flags: Gemma 4
  files report both as unsupported, yet both work.
- With MTP on, `agello-one-20261115` used to rewrite a reply's last token in
  the KV cache when the reply stopped inside a round (probe 35, 2026-11-17).
  Fixed in fork `e62e6ff1` and shipped in `agello-one-20261122`.
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
