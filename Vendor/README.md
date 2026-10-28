# Vendored LiteRT-LM (Swift package surface only)

`Vendor/LiteRT-LM` is a pruned copy of our LiteRT-LM fork,
https://github.com/PowerBeef/agello-litert-lm, branch `agello-next`, at commit
**f1b88286** (Google's LiteRT-LM 0.19.0-nightly.20261013 plus our commits). It
contains only what the Xcode build needs:

- `Package.swift` (pins the `CLiteRTLM.xcframework.zip` of our release
  [`agello-next-20261024`](https://github.com/PowerBeef/agello-litert-lm/releases/tag/agello-next-20261024),
  checksummed)
- `swift/` (the `LiteRTLM` Swift wrapper sources)
- `LICENSE` (Apache 2.0, Google LLC)

## The runtime

The release's `CLiteRTLM.xcframework` has an iPhone slice and a Mac slice (a
versioned framework), both on Metal. It's built from the same commit, with our
forks of LiteRT (`PowerBeef/LiteRT`) and ML Drift (`PowerBeef/ml-drift`, both
on branch `agello-next`) linked statically: build id `99b8f5f6ea49`, whose
`BUILD-INFO.txt` in the release names every commit. Its third-party notices
are in `NOTICE`. Besides the Swift patches below, it carries our runtime
fixes:

- speculative decoding (MTP) never drafts past the end of the KV cache;
- a conversation send ends with exactly one final chunk, for every binding;
- the sampler follows the active session, so a chat's sampler settings and
  Regenerate's seeds apply;
- build information (`LiteRTLM.BuildInfo`, which `EngineCache` keys its
  folders by) and telemetry (`LiteRTLM.Telemetry`), which gives Agello its
  reply stats without benchmark mode.

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
   Cancelling also stops a stream between tool rounds; a reader that stops
   iterating cancels the native work; an unreadable chunk ends the stream and
   cancels the decode; `sendMessageStream` gains `followUpMaxOutputTokens` and
   `maxToolRounds`. `StreamRegistryTests` drives it without a model.
4. `swift/Engine.swift`: `tokenize` and `countTokens`
   (`litert_lm_engine_tokenize`); `swift/EmbeddingEngineConfig.swift`:
   `EmbeddingOptions.inputOverflowStrategy` (truncate long inputs instead of
   failing the batch).

The fork's `agello` branch keeps the same Swift patches on Google's v0.18.0,
for Google's prebuilt binary.

## Why vendored instead of a remote SPM dependency?

The upstream repo stores ~GBs of prebuilt binaries in Git LFS, and GitHub's
LFS batch endpoint for that repo intermittently fails, which makes
`xcodebuild` package resolution fail. The build never touches those LFS files
(it uses the release-attached XCFramework), so vendoring the Swift surface
sidesteps it.

## Updating

A new runtime: publish a release from the fork (`agello/release-xcframework.sh
<tag> --publish` on `agello-next`; the fork's `docs/agello/BUILD.md` has the
steps), then vendor it:

```sh
REF=<agello-next commit> TAG=<tag> ./Vendor/use-release-litert.sh
```

Then update this file and `NOTICE` (from the release's
`THIRD_PARTY_NOTICES.md`; copy it to `Agello/Resources/NOTICE.txt`), and run
the suites on this Mac and the iPhone.

- **A local build, for test runs:** `Vendor/use-local-litert.sh` (never commit
  `Vendor/LiteRT-LM` while it points at `dist/`).
- **Google's binary again:** `REF=<agello commit> ./Vendor/refresh-litert-lm.sh`
  vendors the `agello` branch (v0.18.0 plus the Swift patches) with Google's
  release XCFramework. The Mac app doesn't run on it.
