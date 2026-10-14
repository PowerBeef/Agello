# Vendored LiteRT-LM (Swift package surface only)

`Vendor/LiteRT-LM` is a pruned copy of LiteRT-LM **v0.18.0** from our fork,
https://github.com/PowerBeef/LiteRT-LM, branch `agello`, at commit
**a3c0d0ef** (v0.18.0 plus the patches below). It contains only what the Xcode
build needs:

- `Package.swift` (pins Google's `CLiteRTLM.xcframework.zip` release binary, checksummed)
- `swift/` (the `LiteRTLM` Swift wrapper sources)
- `LICENSE` (Apache 2.0, Google LLC)

## Patches on the fork's `agello` branch

1. `swift/Conversation.swift`: a tool call that fails (a tool name the model
   invented, arguments that don't decode, or a tool that throws) is answered
   with an `error` tool response the model can read, instead of throwing
   `toolExecutionError` and ending the reply. Probe 15 checks it on device.

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
