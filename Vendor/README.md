# Vendored LiteRT-LM (Swift package surface only)

`Vendor/LiteRT-LM` is a pruned copy of our LiteRT-LM fork,
https://github.com/PowerBeef/agello-litert-lm (one branch, `main`, Google's LiteRT-LM
0.19.0-nightly.20261013 plus our commits, with LiteRT and ML Drift as folders of the same
repository). It is the canonical inventory for both the shipped binary release and the vendored
Swift wrapper:

- **Binary release (`CLiteRTLM.xcframework`):**
  [`agello-one-20261127`](https://github.com/PowerBeef/agello-litert-lm/releases/tag/agello-one-20261127),
  built from **`3af6200d`** (Build ID `8931ed8d5a23`, SwiftPM checksum
  `7ee6b8716c8388f6e367189252ecde8d7acce98f9ae470b0113fcaa7a423087d`), pinned in `Package.swift`.
  Ships dual-slice `ios-arm64` (`22.7 MiB`, UUID `2C1A0A09-A3BB-330D-B30A-44AC0A53C8E0`) and
  `macos-arm64` (`23.3 MiB`, UUID `D51F1DDA-EFCF-35A3-95A7-CD92E8287D1E`) with strict
  `_litert_lm_*`-only symbol hiding (220 exports), bundled `.dSYM`s, embedded
  `PrivacyInfo.xcprivacy` (`C617.1`/`35F9.1`), and zero forbidden frameworks.
- **Vendored Swift wrapper (`swift/`):** tracks fork `main` at **`3af6200d`** (synced verbatim to
  the published `agello-one-20261127` release, including `9f8c904e..3af6200d` and `5e60ce70` Wave
  1+2 `ConversationSendGate`, `BatchConfirmationOutcome`/`isRegistered`, overflow-safe 64-bit
  integer coercion, and `Sendable` config conformances), kept byte-identical to `../LiteRT-LM/swift/`
  (including `swift/BUILD`).
- `LICENSE` (Apache 2.0, Google LLC)

## The runtime

The release's `CLiteRTLM.xcframework` has an iPhone slice and a Mac slice (a
versioned framework), both on Metal. It's built from `3af6200d`, with LiteRT and ML Drift
linked statically (folders of the same repository since 2026-11-11, `agello/litert` and
`agello/ml_drift`; our earlier forks `PowerBeef/LiteRT` and `PowerBeef/ml-drift` were archived
on 2026-11-15): build id `8931ed8d5a23`, whose `BUILD-INFO.txt` in the release names every commit. Its
third-party notices are in `NOTICE`. Besides the Swift patches below, it carries our runtime
fixes:

- speculative decoding (MTP) never drafts past the end of the KV cache and enables 7-draft
  `verify_8` ContextDrafts rounds by default when the model supplies a `verify_8` signature;
- a conversation send ends with exactly one final chunk, for every binding, with intra-MTP and
  post-Think cancellation plus `litert_lm_conversation_wait_until_done` background GPU drain;
- zero-copy ARM64 NEON FP16 greedy sampling directly from shared Metal logits buffers (`0` host
  read copies), and the sampler follows the active session;
- build information (`LiteRTLM.BuildInfo`, which `EngineCache` keys its folders by) and telemetry
  (`LiteRTLM.Telemetry`), which gives Agello its reply stats without benchmark mode;
- process-wide PSO deduplication with a persistent `MTLBinaryArchive`, MSL 4.1 cooperative-tensor
  `agello_flash_attention` (`D=256/512`), fused FP32 `RMSNorm + gamma/beta`, SWAR weight conversion,
  and Apple10-tuned `ConvAppleMPP`;
- the global KV caches are Metal placement sparse buffers, mapped 4,096 positions ahead of the fill,
  trimmed immediately on reset/rewind, with Metal 4 `copyBufferMappingsFromBuffer:` zero-blit helper
  snapshots; prefill graphs' memory pools are released after each prompt and `verify_8` shares its
  intermediate pool with `verify` and `decode`;
- the model's window is read from its file (128K v2 model runs at 65,536 tokens on 12 GB iPhones);
  ring caches survive a long rewind, and prefill can stop between its runs;
- GPU vision (`ConvAppleMPP` INT8×INT8 + `BatchedMatMul` MPP with `metal::dynamic_extent`,
  `VisionAdapter` on GPU, `OneHot` rank fix), lazy load/unload for static `AudioExecutor`
  (`3.2–4.3 ms` warm reload on iPhone 17 Pro, `0.0 ms` `session.create`), and Apple
  `QOS_CLASS_USER_INTERACTIVE` promotion for XNNPACK audio workers;
- `LlgConstraintProvider` `TokTrie` byte/special-token encoding (`▁` → `0x20`, `<0xXX>` → raw
  byte, `0xFF` special-token marker) unlocking multi-word JSON enums under default MTP,
  `SuppressTokensConstraint` wrapped inside `ThinkingBudgetConstraint`, live `<thought>`
  continuity across intermediate tool calls with one post-answer rewind+refill, and a self-contained
  recursive-descent LL(1) FC parser supporting paired `<|"|>`/`<escape>`/`ctrl46` delimiters
  alongside RFC 8259 JSON double-quoted strings/keys;
- Full-Stack Audit Wave 2 hardening (`c819aecb`): ML Drift Metal 4 / MSL 4.1 kernel & residency
  fixes (clamped `Softmax`/`Gather` coords, `OneHot`/`BatchedMatMul`/`ConvAppleMPP` guards, FP32
  `SoftmaxReduce` `src_exp`, D=512 FlashAttention underflow & row guards, aligned
  `MTLBinaryArchive` PSO hints, locked `MTLResidencySet` & `SharedMemoryManager`, descending
  `verify_N` priority); `SparseKvMapper` shared mutex, OOM tile rollback, and clean drain/unmap;
  `MetalResidentRound` drain & power-of-2 lanes; executor concurrency, rollback, and RAII lazy
  Vision/Audio cleanup; RFC 3629 `IsValidUtf8` guards before `cxx` `rust::Str` across all tool
  parsers; `ThinkingBudgetConstraint` KMP end-marker fallback & `budget == 0` handling; and
  tokenizer-gated `LlgConstraintProvider`;
- Custom Runtime Audit Waves 1–2 (`5e60ce70`, `9d0bf058`, `3af6200d`, released in
  `agello-one-20261127` / Build `8931ed8d5a23`): Metal/MSL 4.1 kernel bounds & D=512
  FlashAttention/Quantization fixes, sparse KV & weight/program cache safety, MTP drafter &
  resident-round lifecycle fixes, `Conversation` teardown/constraint/rewind+refill/UTF-8 C-ABI &
  Gemma 4 multimodal delimiter/Jinja hardening, strict `_litert_lm_*`-only symbol export
  (`CLiteRTLM.exp`, 220 symbols), bundled `.dSYM`s, embedded `PrivacyInfo.xcprivacy`
  (`C617.1`/`35F9.1`, zero forbidden frameworks), and exact FP64 Dual-`GATHER` RoPE model-surgery
  assertions;
- verified on physical iPhone 17 Pro (A19 Pro, 12 GB, iOS 27.2.1): Release v2 64K `phone-bench.sh`
  (`20261122-152247`, 24/24 nominal, 23/24 undisturbed) measured `file-report` `1,654` median /
  `1,668` peak tok/s prefill (`3.80–3.84 s` TTFT, `56.5–56.9` tok/s decode, `0.98 GB` steady /
  `1.70 GB` peak footprint), `email` `1,556–1,599` tok/s prefill / `57.3–57.8` tok/s decode, and
  `explain` `50.6–51.9` tok/s decode; Custom Runtime Audit Waves 1–2 hardware sign-off on
  `agello-one-20261127` (`8931ed8d5a23`) passed on physical iPhone 17 Pro across `ui` **37/37**,
  `unit` **508/508**, `security` **12/12 (`V1–V12`, 0% breach)**, `inference` **25/25**, `files`
  **8/8**, `thinking` **3/3**, `memory` **4/4**, `probes` **18/18**, 200-turn soak
  `test38_PoolSoak` **1/1** (`0.319 GB` flat graphics, `470 MB` steady footprint), and rebuilt v2
  64K `test27_NeedleTable` **90/90** + `test28_WindowPositions` **12/12 exact** (`web` 8/9, 12/13
  live sources in `test06` with benign phrasing diff on Walmart hours).

## Swift patches

1. `swift/Conversation.swift` & `swift/tools/Tool.swift` (`f3408e06`, `7d80c7ec`, `c819aecb`):
   a tool call that fails (a tool name the model invented, arguments that don't decode, or a tool
   that throws) is answered with an `error` tool response the model can read, instead of throwing
   `toolExecutionError` and ending the reply (Probe 15 checks it on device). Phase 5 (`7d80c7ec`)
   adds `Tool.isReadOnly` and runs multi-call read-only rounds concurrently via
   `withThrowingTaskGroup` in original call order. Wave 2 (`c819aecb`) adds `Conversation.safeJSONData`,
   `ToolManager.normalizeResult` non-finite float stringification, parallel fallback error dicts,
   and `CancellationError` propagation across tool loops.
2. `swift/Conversation.swift` (`0b2ca12f`): a stream holds its conversation weakly. Held strongly,
   a conversation the app had already dropped (a stream abandoned early, or a conversation replaced
   while its cancelled stream was finishing) was released inside LiteRT-LM's final stream callback,
   and deleting it there waited for the very task running that callback: the engine stalled until
   LiteRT-LM's 10-minute timeout. Probe 9 checks it.
3. `swift/ConversationStream.swift` (new) and `swift/Conversation.swift` (`4ca2cf33`, `517ab613`,
   `c819aecb`): streams are kept in a table keyed by an integer ID that each native send passes as
   its callback's user data, instead of a retained pointer, so a stream ends once and late chunks
   find nothing (avoiding use-after-free on repeated tool-rejection errors). Cancelling stops a
   stream between and during async tool rounds via generation-tagged `StreamTable.activeToolRounds`,
   `toolRoundTask`, and `Conversation.sendGateLock` (`c819aecb`); abandoning iteration cancels native
   work; unreadable chunks end the stream and cancel decode; `Conversation.waitUntilDone()` drains
   in-flight GPU threads before background suspension; `sendMessageStream` adds
   `followUpMaxOutputTokens`, `followUpThinkingConfig` & `extraContext` propagation across tool
   rounds (`c819aecb`), and `maxToolRounds`. `StreamRegistryTests` drives it without a model.
4. `swift/Engine.swift` & `swift/EmbeddingEngineConfig.swift` (`4ca2cf33`, `1a90cdb4`): `tokenize`
   and `countTokens` (`litert_lm_engine_tokenize`); `EmbeddingOptions.inputOverflowStrategy`
   (truncate long inputs instead of failing the batch); `EmbeddingEngineConfig.activationDataType`
   (`litert_lm_embedding_engine_settings_set_activation_data_type`, measured in probe 32).
5. Swift 6 language mode (`Package.swift` at tools 6.0, `24f35f81`, `82b05ea1`): `ExperimentalFlags`
   keeps its values behind an `NSLock` instead of unprotected static vars (same public API; a
   `Mutex` in a static crashed optimized Release builds on their first conversation, `82b05ea1`);
   the immutable native handles of `Conversation`, `Engine` and `EmbeddingEngine` and
   `ToolManager`'s registry are `nonisolated(unsafe)`, each with why; a stream's `yield` takes
   its message as `sending`.
6. `swift/Config.swift` and `swift/Engine.swift` (`9f8c904e`): optional
   `ConversationConfig.rawToolsJSON` passes a dynamic OpenAI-style JSON tool-declaration array
   directly to `litert_lm_conversation_config_set_tools` when supplied (used by `agello serve` for
   external evaluation harnesses such as `gbench` and for `AgelloSim`; `nil` preserves
   `ToolManager`'s schema generation).
7. `Package.swift`, `swift/tools/`, `swift/LiteRTLMError+Native.swift`, `swift/LiteRTLMExports.swift`,
   `swift/ConversationStream.swift`, `swift/Conversation.swift` (`f98bbd46`): splits pure-Swift
   tool/error types (`Tool`, `ToolManager`, `ExperimentalFlags`, `LiteRTLMError`) into a
   `LiteRTLMTools` library product with no `CLiteRTLM` binary dependency (re-exported by `LiteRTLM`
   via `@_exported import LiteRTLMTools`), allowing `AgelloSim` to link all 21 Swift tools cleanly
   on the iOS Simulator without shipping a simulator slice of `CLiteRTLM.xcframework`; also honors
   `automaticToolCalling == false` in `sendMessageStream` so external clients (`agello serve` SSE)
   receive `tool_calls` chunks instead of auto-executing them.
8. `swift/tools/Tool.swift` and `swift/tools/ToolManager.swift` (`99fc72a8`): adds
   `@ToolParam(allowedValues:)` emitting `"enum"` constraints directly in generated JSON tool
   schemas, plus schema-aware scalar coercion in `ToolManager.coerceArgument` (`"5"` → `5` / `5.0`,
   `"true"` → `true`, numeric → string) before `JSONDecoder` decodes model tool arguments.
9. `swift/tools/ToolManager.swift` and `swift/Conversation.swift` (`9c8c783d`, `eb7ba0b2`,
   `5e60ce70`): adds `PendingToolInvocation`, `BatchConfirmationOutcome`, `ToolManager.isRegistered`,
   and `ToolManager.BatchConfirmHandler` (`setBatchConfirmHandler` / `confirmBatch` / `endBatch`)
   for grouped multi-step confirmation of registered mutating tool rounds, emitting
   `{"executed": false, "status": "skipped_by_user"}` only for user-skipped indices while preserving
   normal error responses for invalid/unregistered calls. Uses an `NSLock`-backed `BatchConfirmStore`
   (avoiding Patch 5's static `Mutex` crash).
10. `swift/Conversation.swift`, `swift/Config.swift`, `swift/ResponseFormat.swift`, and
    `swift/tools/ToolManager.swift` (`5e60ce70`): replaces `sendGateLock` with
    `ConversationSendGate` (`NSCondition`) latching `cancel()` across both `sendToStream` and
    off-pool blocking `sendMessage` (with `withTaskCancellationHandler` and `waitUntilDone()`
    re-issue drain), adds `Sendable` to pure config structs (`SamplerConfig`, `ThinkingConfig`,
    `RepetitionPenaltyConfig`, `NoRepeatNgramConfig`, `SuppressTokensConfig`, `ResponseFormat`),
    and makes 64-bit integer coercion in `ToolManager.coerceArgument` overflow- and precision-safe
    via `Int(exactly:)` + `CFNumberIsFloatType`.

## Why vendored instead of a remote SPM dependency?

The upstream repo stores ~GBs of prebuilt binaries in Git LFS, and GitHub's
LFS batch endpoint for that repo intermittently fails, which makes
`xcodebuild` package resolution fail. The build never touches those LFS files
(it uses the release-attached XCFramework), so vendoring the Swift surface
sidesteps it.

## Updating

A new runtime: publish a release from the fork (`agello/release-xcframework.sh
<tag> --publish` on `main`; the fork's `docs/agello/BUILD.md` has the
steps), then vendor it:

```sh
REF=<commit> TAG=<tag> ./Vendor/use-release-litert.sh
```

Then update this file and `NOTICE` (from the release's
`THIRD_PARTY_NOTICES.md`; copy it to `Agello/Resources/NOTICE.txt`), and run
the suites on the iPhone.

- **A local build, for test runs:** `Vendor/use-local-litert.sh` (never commit
  `Vendor/LiteRT-LM` while it points at `dist/`).
- **Google's binary** isn't vendored any more (2026-11-11, [docs/BACKEND.md](../docs/BACKEND.md)):
  the app has no code for it. The script that did it is in the git history.
