# Vendored LiteRT-LM (Swift package surface only)

`Vendor/LiteRT-LM` is a pruned copy of LiteRT-LM **v0.18.0** from our fork,
https://github.com/PowerBeef/agello-litert-lm, branch `agello`, at commit
**17056fc1** (v0.18.0 plus the patches below). It contains only what the Xcode
build needs:

- `Package.swift` (pins Google's `CLiteRTLM.xcframework.zip` release binary, checksummed)
- `swift/` (the `LiteRTLM` Swift wrapper sources)
- `LICENSE` (Apache 2.0, Google LLC)

## Patches on the fork's `agello` branch

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

## Why vendored instead of a remote SPM dependency?

The upstream repo stores ~GBs of prebuilt binaries in Git LFS, and GitHub's
LFS batch endpoint for that repo intermittently fails, which makes
`xcodebuild` package resolution fail. The iOS build never touches those LFS
files (it uses the release-attached xcframework), so vendoring the Swift
surface sidesteps it.

## Refreshing

Commit patches to the fork's `agello` branch, then vendor that commit:

```sh
REF=<commit> ./Vendor/refresh-litert-lm.sh                              # the fork (default)
REPO=google-ai-edge/LiteRT-LM REF=v0.19.0 ./Vendor/refresh-litert-lm.sh  # an upstream tag, unpatched
```

Then update the commit in this file and run the test suites.
