# Vendored LiteRT-LM (Swift package surface only)

`Vendor/LiteRT-LM` is a pruned copy of our LiteRT-LM fork,
https://github.com/PowerBeef/agello-litert-lm (one branch, `main`): its `swift/` and the binary of
release `agello-one-20261124`, built from **c819aecb** (Google's LiteRT-LM
0.19.0-nightly.20261013 plus our commits, with LiteRT and ML Drift as folders of the same
repository). It contains only what the Xcode build needs:

- `Package.swift` (pins the `CLiteRTLM.xcframework.zip` of our release
  [`agello-one-20261124`](https://github.com/PowerBeef/agello-litert-lm/releases/tag/agello-one-20261124),
  checksummed)
- `swift/` (the `LiteRTLM` Swift wrapper sources)
- `LICENSE` (Apache 2.0, Google LLC)

## The runtime

The release's `CLiteRTLM.xcframework` has an iPhone slice and a Mac slice (a
versioned framework), both on Metal. It's built from the same commit, with LiteRT and ML Drift
linked statically (folders of the same repository since 2026-11-11, `agello/litert` and
`agello/ml_drift`; our earlier forks `PowerBeef/LiteRT` and `PowerBeef/ml-drift` were archived
on 2026-11-15): build id `8a7e34594612`, whose `BUILD-INFO.txt` in the release names every commit. Its
third-party notices are in `NOTICE`. Besides the Swift patches below, it carries our runtime
fixes:

- speculative decoding (MTP) never drafts past the end of the KV cache and enables 7-draft
  `verify_8` ContextDrafts rounds when the model supplies a `verify_8` signature;
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
  continuity across intermediate tool calls with one post-answer rewind+refill, parallel
  `withTaskGroup` read-only tool dispatch (`Tool.isReadOnly`), and a self-contained
  recursive-descent FC parser supporting paired `<|"|>`/`<escape>`/`ctrl46` delimiters alongside
  RFC 8259 JSON double-quoted strings/keys;
- verified on iPhone 17 Pro (A19 Pro, 12 GB, iOS 27.2.1): `file-report` prefill +9.2 % (`1,443`
  tok/s, TTFT −9.3 %), `email` +5.5 %, `typo-fix` +4.8 % prefill / +2.9 % decode, 85 % undisturbed
  runs (vs 60 % on `agello-one-20261115`), v2 64K exact to position 65,534 at `3.18–3.45 GB`,
  warm GPU ViT init `0.90 s`, `memory` 4/4 with 0 warnings (`0.83 GB` net footprint at `65K`), and
  Phase 5 hardware gate 100 % pass (`security` 100 %, `files` 8/8, `web` 2/2 [21/21 + 13/13],
  targeted `inference` 6/6, `thinking` 3/3).

## Swift patches

1. `swift/Conversation.swift`: a tool call that fails (a tool name the model
   invented, arguments that don't decode, or a tool that throws) is answered
   with an `error` tool response the model can read, instead of throwing
   `toolExecutionError` and ending the reply. Probe 15 checks it on device.
2. `swift/Conversation.swift`: a stream holds its conversation weakly. Held
   strongly, a conversation the app had already dropped (a stream abandoned
   early, or a conversation replaced while its cancelled stream was finishing)
   was released inside LiteRT-LM's final stream callback, and deleting it there
   waited for the very task running that callback: the engine stalled until
   LiteRT-LM's 10-minute timeout. Probe 9 checks it.
3. `swift/ConversationStream.swift` (new) and `swift/Conversation.swift`:
   streams are kept in a table keyed by an integer ID that each native send
   passes as its callback's user data, instead of a retained pointer.
   LiteRT-LM reports a rejected tool call up to three times as a final error,
   and the wrapper released the stream on each, so the second report was a
   use-after-free. Now a stream ends once and late chunks find nothing.
   Cancelling also stops a stream between tool rounds (including while an
   async tool call executes, via `StreamTable.activeToolRounds` and
   `toolRoundTask`); a reader that stops iterating cancels the native work;
   an unreadable chunk ends the stream and cancels the decode;
   `Conversation.waitUntilDone()` exposes `litert_lm_conversation_wait_until_done`
   so the app can drain in-flight GPU threads before background suspension;
   `sendMessageStream` gains `followUpMaxOutputTokens` and `maxToolRounds`.
   `StreamRegistryTests` drives it without a model.
4. `swift/Engine.swift`: `tokenize` and `countTokens`
   (`litert_lm_engine_tokenize`); `swift/EmbeddingEngineConfig.swift`:
   `EmbeddingOptions.inputOverflowStrategy` (truncate long inputs instead of
   failing the batch); `EmbeddingEngineConfig.activationDataType`, the text encoder's activation
   type through the C API's `litert_lm_embedding_engine_settings_set_activation_data_type` (probe
   32 measures float16 against float32).
5. Swift 6 language mode (`Package.swift` at tools 6.0, fork `24f35f81`): `ExperimentalFlags`
   keeps its values behind an `NSLock` instead of unprotected static vars (same public API; a
   `Mutex` in a static crashed optimized builds on their first conversation, fork `82b05ea1`);
   the immutable native handles of `Conversation`, `Engine` and `EmbeddingEngine` and
   `ToolManager`'s registry are `nonisolated(unsafe)`, each with why; a stream's `yield` takes
   its message as `sending`.
6. `swift/Config.swift` and `swift/Engine.swift`: optional `ConversationConfig.rawToolsJSON`
   passes a dynamic OpenAI-style JSON tool-declaration array directly to
   `litert_lm_conversation_config_set_tools` when supplied (used by `agello serve` for external
   evaluation harnesses such as `gbench`; `nil` preserves `ToolManager`'s schema generation).

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
