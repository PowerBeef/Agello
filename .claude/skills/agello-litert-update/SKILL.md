---
name: agello-litert-update
description: Update the vendored LiteRT-LM package (Vendor/LiteRT-LM), work in the PowerBeef/agello-litert-lm fork (../LiteRT-LM), or report and prepare fixes for upstream. Use when asked about LiteRT-LM versions, upgrades, patches, the fork, or upstream issues.
---

# Updating LiteRT-LM

`Vendor/LiteRT-LM` holds only the Swift package surface of
`google-ai-edge/LiteRT-LM`: `Package.swift` (with the checksummed
`CLiteRTLM.xcframework` release download), `swift/`, and `LICENSE`. It's
vendored because upstream Git LFS breaks Swift Package Manager resolution.

## The fork

`PowerBeef/agello-litert-lm` (renamed from `PowerBeef/LiteRT-LM` on 2026-10-14; old
URLs redirect) is a fork of `google-ai-edge/LiteRT-LM`, cloned beside
this repo at `../LiteRT-LM`. `.claude/settings.json` lists it in
`additionalDirectories`, so its C++ and Swift sources are readable from this
project (its own CLAUDE.md and skills don't load):

| Item | Value |
| --- | --- |
| `origin` | `PowerBeef/agello-litert-lm` (push here) |
| `upstream` | `google-ai-edge/LiteRT-LM` (fetch only; push is disabled) |
| `agello` branch | Tag `v0.18.0` plus Agello's Swift patches (see below); `Vendor/LiteRT-LM` is vendored from it. Also holds `docs/agello/` and `tools/agello-bench`. |
| `agello-next` branch | The source build (below): upstream's 0.19.0 nightly source (tag `agello-base-20261013`) plus our patches. Worktree at `../agello-arms/next/LiteRT-LM`. Not in the app yet. |
| `research/3913` tag | The #3913 research (below); a branch until 2026-10-15, so links to `tree/research/3913` still resolve |
| Release tags | Live on upstream's `release/vX.Y.Z` branches (fetch from `upstream`), not on `main` |

Branch policy (decided 2026-10-15): each fork (this one, `PowerBeef/LiteRT`,
`PowerBeef/ml-drift`) keeps `main`, an upstream mirror, plus our branches; the
branches Google's repos had when the forks were made don't belong there. Once
the iPhone validates our build and the app ships it, `agello` and
`agello-next` merge into one `agello` (tag the old `agello` tip first: the
app's vendored commit must stay reachable).

Set it up on a new machine. The partial clone keeps full history but fetches
file contents on demand, and LFS stays skipped: upstream's LFS holds GBs of
prebuilt binaries that nothing here needs.

```sh
cd ..   # beside this repo
GIT_LFS_SKIP_SMUDGE=1 git clone --filter=blob:none https://github.com/PowerBeef/agello-litert-lm.git LiteRT-LM
cd LiteRT-LM
git lfs install --local --skip-smudge
git remote add upstream https://github.com/google-ai-edge/LiteRT-LM.git
git remote set-url --push upstream DISABLED
git fetch upstream --tags
git switch agello   # tracks origin/agello
```

Sync the fork's `main`: `git fetch upstream && git push origin upstream/main:main`.

### Contributing upstream

As of 2026-10-13, upstream's CONTRIBUTING.md says the repository is **not
accepting code contributions**: it asks for GitHub issues instead. All merged
pull requests come from Google's internal mirror (`copybara-service`); outside
pull requests have been closed, not merged. So:

1. Reproduce the bug on the iPhone (harness probes) and fix it on a branch
   off `upstream/main` (or off `agello` when it only matters here).
2. Push the branch to the fork and open an **issue** upstream with the
   reproduction, measurements, and a link to the branch or commit.
3. Open a pull request only after re-reading CONTRIBUTING.md on
   `upstream/main`, in case the policy has changed.

Pushing to the fork, and anything posted upstream, needs the user's go-ahead.

### Issue #3913 (float16 rotary positions)

- Analysis posted on 2026-10-13:
  https://github.com/google-ai-edge/LiteRT-LM/issues/3913#issuecomment-6157362598
  (pointer on #2814). Follow-up with the model-side fix:
  https://github.com/google-ai-edge/LiteRT-LM/issues/3913#issuecomment-6159684389
- As of 2026-10-13 the issue is open and Google hasn't replied to either
  comment. Check for replies with
  `gh api repos/google-ai-edge/LiteRT-LM/issues/3913/comments`.
- The follow-up also describes two WebGPU delegate bugs found while building
  the patch (FULLY_CONNECTED with float weights; REDUCE_MAX over a non-last
  axis). They don't reproduce as single ops: on 2026-10-13, standalone models
  with those exact patterns were exact on v0.18.0's WebGPU accelerator, fully
  accelerated, up to N=2048 and F=256. The failures came from the surrounding
  graph (INT32/BOOL producers: broadcast ADD, comparisons, CAST, SELECT_V2).
  The user decided not to file them, and posted a correction:
  https://github.com/google-ai-edge/LiteRT-LM/issues/3913#issuecomment-6160403434
  The check lives on the fork's `research/3913` tag, in
  `research/issue-3913/webgpu-op-check/` (commit `7cebaa0c`).
- Reproduction: the fork's `research/3913` tag, `research/issue-3913/`
  (graph-patch script, macOS runner, raw results, `summarize.py`).
- **The app ships our fix.** `ModelCatalog.e4b` downloads
  `PowerBeef02/gemma-4-E4B-it-litert-lm-fp16-rope`, pinned to a commit.
  - It's the litert-community file run through the fork's
    `tools/model-surgery/patch_rope.py --split --block 512`: rotary positions
    split as `512·h + l`, exact in FP16 up to 32,767 on every GPU tested (M1-class
    GPUs also lose precision in SIN/COS past ~1,650, which 2,048-token blocks,
    the first revision `13d5aa4c`, left in place); main model and MTP drafter;
    weights unchanged. `--block 2048` reproduces the first revision.
  - The output is deterministic: the model card lists the sha256 of both files.
- **When litert-community updates the E4B file:**
  1. Run `patch_rope.py --split --block 512` on the new file.
  2. Upload it to the same Hugging Face repo, with the model card's sha256
     and source revision updated.
  3. Update `ModelCatalog.e4b` (`revision`, `sizeBytes`).
  4. Run the `inference` suite (`test15_LongContextDigitFidelity`) and probe 12.
- **When Google fixes #3913** (a new LiteRT-LM release or a re-exported model):
  - Run `ONLY=AgelloDeviceTests/ProbeScenarioTests/test10_PositionBoundary scripts/device-harness.sh probes`
    against their file.
  - If FP16 copies exactly past position 2,048, the catalog can go back to
    their file.
- **Lab models for the probes:** copy them to the app's `Documents/lab` with
  `devicectl device copy to`, and delete them with
  `TEST_RUNNER_LAB_REMOVE=<file> ONLY=…/test13_RemoveLabModels scripts/device-harness.sh probes`.
  - Probe 11 needs `ishift-2048.litertlm` (`patch_rope.py … -2048 … --int`).
  - Probe 12 needs `split.litertlm` (`--split --block 512`).

### Using patches in Agello

- **Swift wrapper patches** (`swift/`) are commits on the fork's `agello`
  branch; the app vendors that branch pinned to a commit
  (`REF=<commit> ./Vendor/refresh-litert-lm.sh`, `PowerBeef/agello-litert-lm` by
  default). Current patches (as of 2026-10-15, commit `85b1a776`):
  1. `Conversation.handleToolCalls`: a failed tool call (an invented tool
     name, arguments that don't decode, a tool that throws) is answered with
     an `error` tool response instead of throwing `toolExecutionError`, which
     ended the reply. Probe 15 (`test15_FailingToolCallKeepsTheReply`)
     checks it. Worth offering upstream as an issue, with the user's go-ahead.
  2. `StreamContext` holds its conversation weakly. Held strongly, the final
     stream callback could release the last reference: `deinit` then deleted
     the native conversation on LiteRT-LM's callback thread, which waited for
     the task running that callback until the 10-minute timeout (probe 9 waited
     600 s; a thread sample shows the chain). Releasing on another queue isn't
     enough: the deletion then overlaps the next conversation, which also
     stalled v0.18.0. Probe 9 asserts every step under 60 s. Also an upstream
     issue candidate.
  Each patched file carries a modification notice (Apache 2.0, section 4),
  and `NOTICE` lists the change.
- **C++ runtime patches** reach the app only through a rebuilt
  `CLiteRTLM.xcframework` (upstream builds it with Bazel). `Package.swift`
  points at Google's checksummed release binary, so using a patched runtime
  means building and hosting our own. That's a bigger commitment: decide with
  the user first.

### The source build (`agello-next`)

The Apple-only re-engineering of LiteRT-LM builds the whole runtime from
source, Metal accelerator included, in three forks. Its docs are in the fork's
`docs/agello/` on `agello`: `AUDIT.md`, `PARITY.md` (against Google's
nightly), `TELEMETRY.md`, and `tracks/` (one note per track).

| Checkout | Repository, branch |
| --- | --- |
| `../agello-arms/next/LiteRT-LM` | `PowerBeef/agello-litert-lm`, `agello-next` (a worktree of `../LiteRT-LM`) |
| `../LiteRT` | `PowerBeef/LiteRT`, `agello-next`: the Metal delegate and buffer handler, telemetry probes |
| `../ml-drift` | `PowerBeef/ml-drift`, `agello-next`: the GPU engine, kernel names and timing |

- **Build:** `agello/build-xcframework.sh` in the worktree writes
  `dist/CLiteRTLM.xcframework` and `dist/BUILD-INFO.txt` (commits, SHA-256s).
  Its `WORKSPACE` pins LiteRT and ML Drift by commit and archive sha256.
- **Changing LiteRT or ML Drift:** uncomment the `--override_repository`
  lines in the worktree's `.bazelrc.user` to build from the local checkouts.
  After pushing, re-pin: the new commit and `shasum -a 256` of
  `https://github.com/PowerBeef/<repo>/archive/<commit>.tar.gz`. Comment the
  overrides out and rebuild: the framework should come out byte-identical.
- **Pushing `agello-next`:** from `../LiteRT-LM` (`git push origin
  agello-next`); from the worktree, Git LFS's pre-push lock check fails.
- **In Agello:** `Vendor/use-local-litert.sh` vendors the worktree's build
  (its header says how to switch back). It *copies* the framework: rerun it
  after every rebuild, and check the build id in the harness report's device
  record (`runtimeBuild`) before trusting a run. Never commit `Vendor/LiteRT-LM`
  while it points at the local build. Then run the `PLATFORM=mac` suites;
  the app ships Google's binary until the source build has had an iPhone run
  and the user decides how to host it.
- **Shipping it:** `agello/release-xcframework.sh <tag>` on the fork (a dry run
  without `--publish`; publishing needs the user's OK), then
  `REF=<commit> TAG=<tag> Vendor/use-release-litert.sh` here. `BUILD.md` on the
  fork covers the release, the third-party notices (for `NOTICE`) and the
  privacy manifest check (no new required-reason categories as of 2026-10-15).
- **Build provenance:** `litert_lm_get_build_info()` (our builds only) names
  the commits, flags and a build id; `EngineCache` keys its folders by that id,
  so switching between Google's binary and ours needs no cache juggling (the
  other build's folders are deleted at the next load).
- **Measuring:** `tools/agello-bench` on `agello` (build it against an arm
  with `LITERTLM_PACKAGE=<checkout> swift build -c release --scratch-path
  .build-<arm>`), ABAB runs, `compare.py` for changes with confidence
  intervals, `telemetry.py` for the engine's own breakdown.
- **Telemetry:** `AGELLO_TELEMETRY=<0-4>` (level), `AGELLO_TELEMETRY_OUT`
  (snapshot at exit), `AGELLO_TELEMETRY_GRAPH_DIR` (GPU graph dumps),
  `AGELLO_VERIFY_DIRECT_COPIES=1` (checks the direct Metal host copies). See
  `TELEMETRY.md`, and `agello-device-testing` for the harness side.

## 1. Check upstream

- Latest release: `gh release view --repo google-ai-edge/LiteRT-LM`. The
  current version is in `Vendor/README.md`.
- Read the release notes, and check issues the app works around, especially
  #3913 (GPU float16 digit duplication).
- Note any Swift API changes in `swift/` (Engine, Conversation, Config,
  ResponseFormat, Tool, EmbeddingEngine, ExperimentalFlags). In the fork:
  `git fetch upstream --tags && git diff v0.18.0 vX.Y.Z -- swift/`.
- After updating, rebase the fork's `agello` branch onto the new tag
  (`git rebase --onto vX.Y.Z v0.18.0 agello`), resolve the patches, push it,
  and vendor the new commit.

## 2. Refresh

```sh
REF=<agello commit> ./Vendor/refresh-litert-lm.sh
```

Never vendor Google's tag directly (`REPO=google-ai-edge/LiteRT-LM REF=…`):
it drops the patches. Then update the version and commit in `Vendor/README.md`, the README badge and the
"Vendored LiteRT-LM" section, the code map in `docs/ARCHITECTURE.md`, and
`NOTICE` if the license or copyright changed.

## 3. Build and fix

Build for the iPhone. Fix API changes only inside `LiteRTChatEngine`
(`Agello/Inference/ChatEngine.swift`) and `LiteRTEmbedder`
(`Agello/Knowledge/Embedding.swift`), the only files that import LiteRTLM.
Keep every rule in the `agello-inference-rules` skill.

## 4. Re-check the privacy manifest

`CLiteRTLM.framework` is embedded without its own privacy manifest, so the
app's `Agello/PrivacyInfo.xcprivacy` declares its required-reason APIs. After
the build, list the binary's references:

```sh
F=$(find ~/Library/Developer/Xcode/DerivedData/Agello-*/SourcePackages/artifacts/litert-lm \
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

Run these in order (see `agello-device-testing`):

1. `scripts/device-harness.sh probes`: LiteRT-LM feature probes (helper
   conversation, JSON, embeddings).
2. `inference`, then `files`.
3. `calibrate` when performance or memory may have changed. Compare with the
   README's Performance table.
4. If the release mentions #3913, follow "When Google fixes #3913" above.

Commit the refresh and the fixes separately.
