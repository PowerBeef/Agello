---
name: iRTChat LiteRT-LM update
description: Update the vendored LiteRT-LM package (Vendor/LiteRT-LM) to a new upstream release, or check whether one is available. Use when asked about LiteRT-LM versions, upgrades, or upstream fixes.
---

# Updating LiteRT-LM

`Vendor/LiteRT-LM` holds only the Swift package surface of
`google-ai-edge/LiteRT-LM`: `Package.swift` (with the checksummed
`CLiteRTLM.xcframework` release download), `swift/`, and `LICENSE`. It's
vendored because upstream Git LFS breaks Swift Package Manager resolution.

## 1. Check upstream

- Latest release: GitHub MCP `get_latest_release` for
  `google-ai-edge/LiteRT-LM`. The current version is in `Vendor/README.md`.
- Read the release notes, and check issues the app works around, especially
  #3913 (GPU float16 digit duplication).
- Note any Swift API changes in `swift/` (Engine, Conversation, Config,
  ResponseFormat, Tool, EmbeddingEngine, ExperimentalFlags).

## 2. Refresh

```sh
TAG=v0.19.0 ./Vendor/refresh-litert-lm.sh
```

Then update the tag in `Vendor/README.md`, the README badge and the
"Vendored LiteRT-LM" section, and `NOTICE` if the license or copyright
changed.

## 3. Build and fix

Build for the iPhone. Fix API changes only inside `LiteRTChatEngine`
(`iRTChat/Inference/ChatEngine.swift`) and `LiteRTEmbedder`
(`iRTChat/Knowledge/Embedding.swift`), the only files that import LiteRTLM.
Keep every rule in the `irtchat-inference-rules` skill.

## 4. Re-check the privacy manifest

`CLiteRTLM.framework` is embedded without its own privacy manifest, so the
app's `iRTChat/PrivacyInfo.xcprivacy` declares its required-reason APIs. After
the build, list the binary's references:

```sh
F=$(find ~/Library/Developer/Xcode/DerivedData/iRTChat-*/SourcePackages/artifacts/litert-lm \
  -path "*ios-arm64/CLiteRTLM.framework/CLiteRTLM" | head -1)
nm -u "$F" | grep -E "_(stat|fstat|fstatat|lstat|getattrlist.*|statfs|fstatfs|statvfs|fstatvfs|mach_absolute_time)$|NSUserDefaults|systemUptime"
find "$(dirname "$F")" -name "*.xcprivacy"
```

v0.18.0 references `stat`, `fstat`, `fstatat`, `lstat` (file timestamp,
declared `C617.1`) and `mach_absolute_time` (system boot time, `35F9.1`). Any
new category needs an entry in the app's manifest. If the framework starts
shipping its own manifest, keep the app's entries for the app's own code
(UserDefaults `CA92.1`, disk space `E174.1`, file sizes `C617.1`).

## 5. Verify on the iPhone

Run these in order (see `irtchat-device-testing`):

1. `scripts/device-harness.sh probes`: LiteRT-LM feature probes (helper
   conversation, JSON, embeddings).
2. `inference`, then `files`.
3. `calibrate` when performance or memory may have changed. Compare with the
   README's Performance table.
4. If #3913 is fixed upstream, test whether the FP32 switch in `AppState`
   (`highPrecisionOnTokens`) is still needed before removing it.

Commit the refresh and the fixes separately.
