---
name: agello-inference-rules
description: Rules that keep LiteRT-LM from crashing or misbehaving in Agello. Read before changing ChatEngine.swift, AppState's generation or engine lifecycle, ContextBudget, InferencePlanner, helper tasks, tools, or anything that sends to the model.
---

# Agello inference rules

Every rule below prevents a crash (native heap corruption, background GPU kill) or silent output/security regression. `AgelloSim` tests real UI, tools, and prompts via `agello serve`, not on-iPhone Metal/jetsam limits — confirm runtime/memory changes on physical hardware. Runtime internals live in `../LiteRT-LM/docs/agello/reference/` (`docs/LITERT-LM.md`); active binary & Swift patch pins live in [Vendor/README.md](../../../Vendor/README.md). **Before** proposing or implementing engine, KV/tool-budget, ANE/RAG, prompt, speculative-decode, constrained-decoding, or backend changes, consult [docs/BACKEND_KNOWLEDGE_BASE.md](../../../docs/BACKEND_KNOWLEDGE_BASE.md) (**Part 4 Worth Revisiting / `§4.1` M6-vs-iPhone Silicon Divergence Matrix** and **Part 6 "Do Not Repeat" Graveyard**) so rejected designs, Swift 6 `-O` traps, and M6-only wins are never repeated.

## Ownership & conversation lifecycle

- **Sole native owner:** `LiteRTChatEngine` (`Agello/Inference/ChatEngine.swift`) is the only actor touching LiteRT-LM `Engine` and `Conversation`.
- **Single-flight `AppState.serialized { }`:** Serialize engine lifecycle ops (load, settings apply, benchmark, delete, helpers) across actor `await`s. Never nest `serialized` (deadlocks).
- **Throwaway helpers & Metal 4 sparse KV snapshots:** `helperJSON`, `helperTexts`, and `transcribe` run in throwaway conversations. On exclusive helper switches, the runtime detaches/restores sparse global KV caches via `MTL4CommandQueue.copyBufferMappingsFromBuffer:` (zero-blit page-table handoff; only the 1,536-slot local rings blit on v2), restoring immediately in `endHelper`.
- **Keep-vs-drop & `afterHelper()` KV-bleed guard:** The engine keeps the main conversation beside a helper only when `GPUGate.isOpen` and snapshot + helper KV fit above `lowMemoryStopBytes` (`DeviceProfile.keepsConversationAcrossHelpers`: 31.5 MB rings + 8,192 B/tok up to 4,096 positions on v2 `>= 65_536`; 28,672 B/tok on 32K files). Otherwise it releases the main conversation *before* the helper and leaves an empty one. `AppState.afterHelper()` checks `lastHelperKeptConversation`, unbinds `conversationThreadID = nil` when false, and sets `conversationIsEmpty = false` (never `true`) so failed/cancelled helpers never leak stale KV into a new chat (`testCancelledHelperDoesNotLeakContextIntoNewChat`).
- **Helper cancel & scheduling:** While `helperActive`, `cancel()` cancels only the helper (never the kept main conversation). Failed/stopped helpers leave a valid conversation (`endHelperAfterFailure`) so the next send reseeds instead of reloading. Title/memory helpers run via `queueHelpers`/`runPendingHelpers` (on leaving chat or after `ThermalPolicy`-adjusted idle delay, never in voice mode or with a send pending).
- **Atomic `PreparedSend`:** Prepare and fit a send inside one `serialized` step so helpers or dictation cannot clear it in between.

## Context window (KV cache) & tool budgets

- **Never overflow KV:** Overflow corrupts native heap. Every send runs `fitContext` (trim + reseed, or throw `messageTooLong`), then `runSend` caps output with `ContextBudget.outputCap` and throws `contextFull` when full.
- **Allocated positions & MTP margin:** Budget against `ContextBudget.allocatedPositions` (65,536 on v2 128K; 32,000 on 32K files), keeping the 64-token margin so an MTP / `verify_8` round stays in bounds.
- **3-tier `ToolBudget.plan` (`ToolHost.swift`):** Whenever any tool is offered, split `room`:
  - `room < 16,384`: up to **2 calls**, `room / 8` tokens/result.
  - `16,384 <= room < 32,768`: up to **4 calls**, `room / 16` tokens/result.
  - `room >= 32,768` (64K chats): up to **5 calls**, `room / 20` tokens/result.
  - Round 1 gets `min(room - maxCalls * resultTokens - maxCalls * laterRound, room / 2 + thinkingBudget)`. Each round uses `ToolBudget.reasoning`, and post-tool rounds clamp reasoning to `ToolBudget.Plan.followUpThinkingBudget` (`followUpThinkingConfig`) so Think always leaves visible answer tokens. Keep the streaming guard active whenever tools are offered.
- **Exact token counts & evicted-turn recall:** Count via `Conversation.renderMessageIntoString` + `Engine.countTokens` (+1 BOS on first send; `seedTokens` = preface + 1). Use `ContextBudget.estimateTextTokens` (3 B/tok or 1 tok/digit/ideograph) only without a tokenizer (mock engine, file/web/tool budgets). `fitContext` trims history by exact per-turn counts (no hard 20-turn cap), records evicted turns in `lastEvictedHistory` for `KnowledgeBase.recallEvictedTurns` (`promptWithEvictedRecall`), and unbinds the chat on any fit error.
- **Neutralize chat markers:** Run external text (messages, system prompt, history, helpers, web/tool outputs) through `PromptText.neutralized` (ZWJ inside `<|`/`|>`) so Gemma control tokens cannot be injected.
- **Strip reasoning from KV:** `load` sets `ExperimentalFlags.filterChannelContentFromKvCache = true`. The runtime keeps `<thought>` live across intermediate tool calls within a turn and rewinds+refills once after the final answer (`ThinkingScenarioTests/test02_ReasoningStaysOutOfCache`).
- **Fixed 64K window & room step-down:** Context size is fixed at 65,536 on 12 GB iPhones (not a UI setting), capped by `ContextBudget.exportWindow(reported:)` and passed to every `InferencePlanner.resolve`. After dropping any prior engine, `load` checks `MemoryProbe.roomBytes` and steps down (`DeviceProfile.contextTokens`): 16K below `4.2 GB` (`roomForLargeContextBytes`), 8K below `3.5 GB`. Keep `loadedContextTokens` sticky across settings changes; budget from `resolved.maxNumTokens`, never defaults. Don't raise thresholds without passing the iPhone `memory` suite.
- **Think budget & reply reserve:** `DeviceProfile.defaultThinkingBudget` is fixed at `4,096` (`InferenceOptions.launch` preserves only Think). `ContextBudget.replyReserve` caps answer share at `4,096` + `thinkingBudget`, bounded by `maxNumTokens / 3`, unlocking ~56–60K single-prompt tokens at 64K (~10–11K at 16K; digits = 1 tok each).

## Engine lifecycle & caches

- **Validate every load; GPU only:** Every new engine must pass `validate()` (1-token generation, retried once after 750 ms). `InferencePlanner.attempts` tries GPU multimodal then GPU text-only (final attempt retried once). Never add a CPU fallback (`docs/BACKEND.md`). Vision runs on GPU (`VisionEncoder` + `VisionAdapter`); audio (`Conformer`) loads lazily on P-core XNNPACK (`USER_INTERACTIVE` QoS).
- **Reload vs reseed:** `InferencePlanner.requiresEngineReload` (KV size, vision, audio, MTP) requires `load`; all other changes go through `updateConversationOptions` (reseed). Set engine-level `ExperimentalFlags` before `Engine` init. Apply pending debounced `scheduleApplyOptions` before sending.
- **Cache isolation (`EngineCache`):** Use `directory()` for E4B (`kv-all-<id>`, content-keyed weights shared across KV sizes, versioned by `runtimeBuildID`), `embeddingDirectory()` for `LiteRTEmbedder` fallback, `EngineCache.disabled` for benchmarks. Never pass the cache root (`directory()` prunes foreign build folders).
- **Cancellation & branches:** Cancelled conversations reject future sends (`CANCELLED`); cancel ends as `generationCancelled`, keeps partial text, and unbinds so the next send reseeds. Regenerate/edit rebuild strictly from turns before the changed turn.

## Precision, constrained decoding & sampling

- **Shipped patched v2 model only:** Never point `ModelCatalog.e4b` at stock Google E4B (FP16 rotary rounding duplicates digits past 2,048, #3913) and never re-add an FP32 switch. `ModelCatalog.e4b` pins `gemma-4-E4B-it-agello-v2.litertlm` (1,536-slot rings, 128K Dual-`GATHER` FP16-exact rotary `<0.001 rad`, `verify_8`, `tools/model-surgery/build_v2.sh`). Re-verify `test15_LongContextDigitFidelity`, `test27_NeedleTable`, and `test28_WindowPositions` after model updates.
- **JSON constraints & MTP:** `LiteRTChatEngine.jsonHelpersSpeculate` defaults ON (`AGELLO_JSON_MTP != "0"`), backed by the runtime's `llguidance` `TokTrie` fix and recursive-descent LL(1) FC parser ([Vendor/README.md](../../../Vendor/README.md), `test16_MultiWordJsonEnumWithMTP`).
- **Sampling, telemetry & vision:** Ignore the model's `thinking`/`functionCalling` flags (both work). MTP forces greedy decoding; Regenerate disables MTP with an explicit `SamplerConfig(seed:)`. Stats use `RuntimeTelemetry` level 2 — **never** enable `ExperimentalFlags.enableBenchmark` on normal loads (makes GPU waits busy-spin; only `LiteRTLM.benchmark` toggles it). Visual soft tokens cap at `280` (`VisualDetail.offered(limit:)`).

## Agentic tool safety, confirmation tiers & Shortcuts bridge

- **Spotlighting & memory quarantine (`AgentSecurity.swift`):** Wrap every untrusted input (files, web results, photo OCR, Shortcut outputs, external tool outputs) in `<untrusted_data source="...">` after `PromptText.neutralized` (use `UntrustedContext.wrapFitted` with `ToolBudget` so `</untrusted_data>` is never clipped). Always run `UntrustedContext.stripUntrustedBlocks` before persistent memory extraction (`HelperTasks.swift`).
- **Taint & contact provenance:** Reset `TurnSecurityContext` at turn start; `UntrustedContext.wrap`/`wrapFitted` records sources so subsequent confirmations show an amber provenance warning. `prepare_message` checks recipients against `TurnContactRoster`.
- **Mutability & 3 risk tiers:** Every `Tool` declares `static let isReadOnly`:
  - `true`: eligible for parallel `withTaskGroup` execution.
  - `false`: **all 5 mutating tools** (`manage_calendar_event`, `manage_reminder`, `prepare_message`, `manage_alarm`, `run_shortcut`) MUST pass fail-closed `ToolConfirmationGate.confirm(...)` before mutating state (denied when backgrounded, stopped, or without UI presenter; request-ID matched; rendered in `ChatView` and `VoiceModeView`).
  - **`ToolConfirmationRequest.RiskTier`:** `.standard` (create/update), `.destructive` (red delete/cancel), `.external` (leaves sandbox: `prepare_message`, `run_shortcut`). Run **authoritative EventKit/AlarmKit lookups** by opaque `id` before confirming `update`/`delete`/`complete`/`cancel` so cards show ground-truth titles/times.
- **Multi-step `PlanConfirmationCard` & 1-to-1 parity (zero TOCTOU):** Multiple mutating calls in one round route through `ToolManager.BatchConfirmHandler` → `BatchConfirmationPlanner` (authoritative lookups up front) → `PlanConfirmationCard` (`.approvedSteps(Set<Int>)`). Approved steps get single-use `ToolConfirmationGate.grantBatchStep(toolName:)` (cleared in `clearBatchGrants()` on round end/stop/cancel). Every unchecked/denied step MUST emit `{"executed": false, "status": "skipped_by_user"}` (both `Conversation.swift` and `RemoteChatEngine.swift`) preserving 1-to-1 `<|tool_call>`/`<|tool_response>` parity.
- **Outbound Shortcuts (`RunShortcutTool` + `ShortcutCallbackBroker`):** 4-layer barrier: (1) user allowlist in `AutomationRegistry` (top-K `<= 10` prompt slot, 0 overhead when empty), (2) `.external` confirmation, (3) 256-bit CSPRNG hex nonce (`120 s` TTL, single-use, constant-time compare, RFC 3986 encoding on `agello://shortcut-result`), (4) `<untrusted_data source="shortcut:...">` spotlighting.
- **Errors & Focus Filter:** Never throw from `Tool.run()` — return `["error": "..."]` (`ToolManager.normalizeResult` stringifies non-finite floats). `AgelloFocusFilter` (`hidePersonalTools`) strips opt-in personal tool schemas with 0 tool tokens.

## Language-agnostic tools & prompts

- **Natural language in, user's language out:** Never require special syntax or tool names. Prefer structured parameters (`SearchPlacesTool.near`) and canonical API formats (`place`/`weather`/`currency` with local names intact) while keeping encyclopedia queries and replies in the user's language.
- **`LanguageSupport.swift` (13 languages):** Route all Swift multilingual parsing (`meansCurrentLocation`, `splitPlaceQuery`, `stripWeatherNoise`, `stripPlaceHoursNoise`, `normalizeTransportMode`, `parseLocalizedNumber`, `isDifferenceFollowUp`, `fold` incl. `ß → ss`) through it; never add English-only splitters or strip city names (`"Rio de Janeiro"`, `"La Paz"`).
- **Zero-cost conditional hints:** Don't bloat `SystemPrompt.base` ([docs/SYSTEM-PROMPT.md](../../../docs/SYSTEM-PROMPT.md)); inject 1-line hints only when relevant context exists (`.csv`/`.tsv`/`.json` files or non-empty `AutomationRegistry`).

## Memory, thermal policy & background GPU safety

- **No background GPU:** Replies stop on backgrounding except eligible `BackgroundWorkPlan` tasks (long doc synthesis, web research, multi-step Think) under `BGContinuedProcessingTask` (`.gpu` + `.inference`), OR an active **Shortcut handoff** where `AppState.enterBackground()` parks the turn while **closing `GPUGate`** (zero background GPU) and `enterForeground()` flushes buffered `ShortcutCallbackBroker` results. On submission failure while backgrounded, `BackgroundWork.onSubmissionFailure` closes `GPUGate` and drains immediately. `load()` tracks `loadingConversation` for clean teardown (`GPUGate.closedError`). Extensions never load models.
- **Memory warnings & `ThermalPolicy`:** `MemoryPolicy.action(level:)` stops a reply only below `400 MB` (`lowMemoryStopBytes`) and releases EmbeddingGemma; E4B stays loaded (`testMemoryWarningKeepsTheEngineLoaded`). `ThermalPolicy` adapts to `thermalState` + Low Power Mode: stream flushes at `100 / 200 / 250 ms`, helper idle delay `3 s → 15–30 s → paused` at `.critical`, and background ANE deferral/pause.

## Verify

Verify prompts, tools, confirmations, and UI in `AgelloSim` (`scripts/sim-launch.sh`) and `scripts/cli-test.sh` (`unit`, `inference`, `security`); confirm engine, memory, background-GPU, and thermal behavior on physical iPhone (`scripts/device-harness.sh gate`, `inference`, `files`, `memory`, `security`). Unit tests use `MockChatEngine` and never exercise LiteRT-LM. Record every new optimization, probe, fix, negative/reverted result, or M6-vs-iPhone divergence in [docs/BACKEND_KNOWLEDGE_BASE.md](../../../docs/BACKEND_KNOWLEDGE_BASE.md) (following **Part 7**) in the same commit.
