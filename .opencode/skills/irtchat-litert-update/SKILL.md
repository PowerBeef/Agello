---
name: iRTChat LiteRT-LM update
description: Update the vendored LiteRT-LM package (Vendor/LiteRT-LM), work in the PowerBeef/LiteRT-LM fork (../LiteRT-LM), or report and prepare fixes for upstream. Use when asked about LiteRT-LM versions, upgrades, patches, the fork, or upstream issues.
---

# Updating LiteRT-LM

`Vendor/LiteRT-LM` holds only the Swift package surface of
`google-ai-edge/LiteRT-LM`: `Package.swift` (with the checksummed
`CLiteRTLM.xcframework` release download), `swift/`, and `LICENSE`. It's
vendored because upstream Git LFS breaks Swift Package Manager resolution.

## The fork

`PowerBeef/LiteRT-LM` is a fork of `google-ai-edge/LiteRT-LM`, cloned beside
this repo at `../LiteRT-LM` (the OpenCode reference `litert-lm`):

| Item | Value |
| --- | --- |
| `origin` | `PowerBeef/LiteRT-LM` (push here) |
| `upstream` | `google-ai-edge/LiteRT-LM` (fetch only; push is disabled) |
| `irtchat` branch | Starts at tag `v0.18.0`, the version vendored here. Patches iRTChat needs go on it. |
| Release tags | Live on `release/vX.Y.Z` branches, not on `main` |

Set it up on a new machine. The partial clone keeps full history but fetches
file contents on demand, and LFS stays skipped: upstream's LFS holds GBs of
prebuilt binaries that nothing here needs.

```sh
cd ..   # beside the iRT repo
GIT_LFS_SKIP_SMUDGE=1 git clone --filter=blob:none https://github.com/PowerBeef/LiteRT-LM.git
cd LiteRT-LM
git lfs install --local --skip-smudge
git remote add upstream https://github.com/google-ai-edge/LiteRT-LM.git
git remote set-url --push upstream DISABLED
git fetch upstream --tags
git switch irtchat   # tracks origin/irtchat
```

Sync the fork's `main`: `git fetch upstream && git push origin upstream/main:main`.

### Contributing upstream

As of 2026-10-13, upstream's CONTRIBUTING.md says the repository is **not
accepting code contributions**: it asks for GitHub issues instead. All merged
pull requests come from Google's internal mirror (`copybara-service`); outside
pull requests have been closed, not merged. So:

1. Reproduce the bug on the iPhone (harness probes) and fix it on a branch
   off `upstream/main` (or off `irtchat` when it only matters here).
2. Push the branch to the fork and open an **issue** upstream with the
   reproduction, measurements, and a link to the branch or commit.
3. Open a pull request only after re-reading CONTRIBUTING.md on
   `upstream/main`, in case the policy has changed.

Pushing to the fork, and anything posted upstream, needs the user's go-ahead.

### Issue #3913 (float16 rotary positions)

- Analysis posted on 2026-10-13:
  https://github.com/google-ai-edge/LiteRT-LM/issues/3913#issuecomment-6157362598
  (pointer on #2814).
- Reproduction: the fork's `research/3913` branch, `research/issue-3913/`
  (graph-patch script, macOS runner, raw results, `summarize.py`).
- Re-test every new release or re-exported model on the iPhone:
  `ONLY=iRTChatDeviceTests/ProbeScenarioTests/test10_PositionBoundary scripts/device-harness.sh probes`.
  Once FP16 copies exactly past position 2,048, the app's FP32 switch can go.
  `test11_ShiftedRotaryPositions` needs a patched model copied to the app's
  `Documents/lab/ishift-2048.litertlm` (`patch_rope.py … -2048 … --int`).

### Using patches in iRTChat

- **Swift wrapper patches** (`swift/`): the refresh script below always
  downloads Google's tag, which would drop them. Vendor from the fork's
  `irtchat` branch instead; the script will need a repository and branch
  option for that.
- **C++ runtime patches** reach the app only through a rebuilt
  `CLiteRTLM.xcframework` (upstream builds it with Bazel). `Package.swift`
  points at Google's checksummed release binary, so using a patched runtime
  means building and hosting our own. That's a bigger commitment: decide with
  the user first.

## 1. Check upstream

- Latest release: GitHub MCP `get_latest_release` for
  `google-ai-edge/LiteRT-LM`. The current version is in `Vendor/README.md`.
- Read the release notes, and check issues the app works around, especially
  #3913 (GPU float16 digit duplication).
- Note any Swift API changes in `swift/` (Engine, Conversation, Config,
  ResponseFormat, Tool, EmbeddingEngine, ExperimentalFlags). In the fork:
  `git fetch upstream --tags && git diff v0.18.0 vX.Y.Z -- swift/`.
- After updating, move the fork's `irtchat` branch to the new tag, re-applying
  any patches on it.

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
